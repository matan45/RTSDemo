// AutomatedMatchController - plays the skirmish by itself and reports the outcome
// (VK-1298 slice 2: the game as a repeatable engine test).
//
// Why it exists: the RTS demo is the engine's integration test, but until now the only
// way to run it was a human in the editor. This controller drives the SAME public
// controller APIs the HUD uses (placeAt / queueUnit / orderMove / orderAttack), checks
// invariants as it goes, and ends the process with a pass/fail exit code -- so
// tools/run_automatch.ps1 can launch Runtime.exe, wait, and turn the log into a verdict
// without anyone watching. Every engine seam the match exercises (navmesh crowds,
// production, plugin Health/Team, death/despawn, waves, RTT minimap, stats, coroutines,
// App::quit) gets proven or caught on every run.
//
// GATE. Inert unless <project>/config.json says {"autoMatch": true} (HarnessConfig,
// which reads the engine config natives). Nothing is logged while inert, so the
// controller can stay attached to GameSystems in the shipped scene.
//
// LOG PROTOCOL (every line via Log::, which the engine prefixes with "[Script] ";
// tools/run_automatch.ps1 parses exactly these shapes):
//   PHASE,<name>,<t>
//   ASSERT,<name>,PASS|FAIL,<detail>            (FAIL goes through Log::error)
//   STAT,<t>,<fps>,<cpuMs>,<gpuMs>,<drawCalls>,<pUnits>,<eUnits>,<pBuildings>,<eBuildings>,<gold>
//   COROUTINE,tick,<n>                          (the heartbeat probe below)
//   MATCH,END,<WIN|LOSE|TIMEOUT|ABORT|SOAK>,<t>  then App::quit(0 if no FAIL, else 1)
// DEATH,... and WAVE,... lines come from DeathController / EnemyCommander.
//
// SCENARIOS (config "autoMatchScenario"):
//   assault  BOOT -> BUILD (CC, Power, Barracks, Refinery) -> TRAIN (6 soldiers)
//            -> STAGE (group-move to a forward point) -> ASSAULT (attack the nearest
//            enemy base, auto-acquire handles the guards) -> END on win/lose/timeout
//   defend   BOOT -> BUILD -> TRAIN -> DEFEND (hold until the match ends, 5 waves
//            arrived, or timeout) -> END
//   soak     BOOT -> BUILD -> TRAIN -> SOAK (idle, collecting STAT rows, until
//            timeout) -> END
//
// TIME IS NEVER FROZEN here: Time::freeze halts the whole Scripts task, this
// controller included.
//
// The heartbeat coroutine is deliberately self-contained (one method, one launch
// line, one field): it is the first coroutine in the project, so if the toolchain
// rejects it, deleting those three pieces removes the probe without touching the
// match logic.
//
// Attach this @Script to GameSystems LAST, so the controllers it drives are created
// before it starts.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Navmesh.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Stats.mt";
import * from "../../lib/engine/Coroutine.mt";
import * from "../../lib/engine/App.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/core/json/Json.mt";
import * from "../../lib/core/primitives/Int.mt";
import * from "../../lib/core/exceptions/Exception.mt";
import * from "../../lib/math/Vec3f.mt";
import * from "./BuildingPlacementController.mt";
import * from "./BuildingCommandController.mt";
import * from "./DeathController.mt";
import * from "./MatchController.mt";
import * from "./RTSHUDController.mt";
import * from "../util/Combat.mt";
import * from "../util/HarnessConfig.mt";
import * from "../data/AutoMatchResult.mt";

@Script
class AutomatedMatchController extends Behaviour {
    // ---- phases ----
    public static final int PHASE_IDLE = 0;
    public static final int PHASE_BOOT = 1;
    public static final int PHASE_BUILD = 2;
    public static final int PHASE_TRAIN = 3;
    public static final int PHASE_STAGE = 4;
    public static final int PHASE_ASSAULT = 5;
    public static final int PHASE_DEFEND = 6;
    public static final int PHASE_SOAK = 7;
    public static final int PHASE_DONE = 8;

    // Build-slot indices (BuildingPlacementController.buildings order:
    // 0 Barracks, 1 Command Center, 2 Refinery, 3 Power Plant, 4 Factory).
    public static final int SLOT_BARRACKS = 0;
    public static final int SLOT_COMMAND = 1;
    public static final int SLOT_REFINERY = 2;
    public static final int SLOT_POWER = 3;

    // Team ids (mirrors util/Config.mt TEAM_PLAYER; EnemyBases/EnemyGuards use 1).
    public static final int TEAM_PLAYER = 0;
    public static final int TEAM_ENEMY = 1;

    // ---- scenario constants ----
    // Player base south of the origin; the enemy posts sit at (+-48, 48), ~90 units
    // away, so the staging point is a forward position still outside their aggro.
    private float ccX;
    private float ccZ;
    private float powerX;
    private float powerZ;
    private float barracksX;
    private float barracksZ;
    private float refineryX;
    private float refineryZ;
    private float stageX;
    private float stageZ;
    private int soldiersToTrain;
    // Expected gold after BUILD: 1000 - CC 50 - Power 60 - Barracks 75 - Refinery 40.
    private int goldAfterBuild;
    // ...and after TRAIN: 6 soldiers * 25.
    private int goldAfterTrain;
    private float bootTimeoutSec;
    private float trainTimeoutSec;
    private float stageTimeoutSec;
    private int defendWaves;

    // ---- config ----
    private bool enabled;
    private string scenario;
    private float timeoutSec;

    // ---- run state ----
    private int phase;
    private float t;            // seconds since the harness started (onStart)
    private float phaseStart;   // t at the last phase change
    private float statAccum;
    private int passes;
    private int fails;
    private bool ended;

    // ---- peers ----
    private RTSHUDController? hud;
    private BuildingPlacementController? placement;
    private BuildingCommandController? command;
    private DeathController? deaths;
    private MatchController? matchCtl;

    // ---- per-phase scratch ----
    private int buildStep;
    private int commandCenterId;
    private int powerId;
    private int barracksId;
    private int refineryId;
    private bool trainQueued;
    private int groupId;
    private int[] soldierIds;
    private int[] guardIds;
    private bool assaultOrdered;

    // ---- heartbeat probe ----
    private bool running;
    private int heartbeatTicks;

    public constructor() : super() {
        this.ccX = 0.0;
        this.ccZ = -36.0;
        this.powerX = -14.0;
        this.powerZ = -36.0;
        this.barracksX = 14.0;
        this.barracksZ = -36.0;
        this.refineryX = 0.0;
        this.refineryZ = -48.0;
        this.stageX = 36.0;
        this.stageZ = 26.0;
        this.soldiersToTrain = 6;
        this.goldAfterBuild = 775;
        this.goldAfterTrain = 625;
        this.bootTimeoutSec = 6.0;
        this.trainTimeoutSec = 40.0;
        this.stageTimeoutSec = 60.0;
        this.defendWaves = 5;

        this.enabled = false;
        this.scenario = "assault";
        this.timeoutSec = 300.0;

        this.phase = 0;
        this.t = 0.0;
        this.phaseStart = 0.0;
        this.statAccum = 0.0;
        this.passes = 0;
        this.fails = 0;
        this.ended = false;

        this.hud = null;
        this.placement = null;
        this.command = null;
        this.deaths = null;
        this.matchCtl = null;

        this.buildStep = 0;
        this.commandCenterId = -1;
        this.powerId = -1;
        this.barracksId = -1;
        this.refineryId = -1;
        this.trainQueued = false;
        this.groupId = -1;
        this.assaultOrdered = false;

        this.running = false;
        this.heartbeatTicks = 0;
    }

    public function onStart(): void {
        this.soldierIds = new int[0];
        this.guardIds = new int[0];

        this.enabled = HarnessConfig::autoMatchEnabled();
        if (!this.enabled) {
            return;
        }
        this.scenario = HarnessConfig::scenario();
        this.timeoutSec = HarnessConfig::timeoutSec();

        Log::info("[AutoMatch] enabled; scenario=" + this.scenario
            + " timeoutSec=" + parsePrimitive(this.timeoutSec));

        this.running = true;
        // Fire-and-forget: the promise is driven by the engine's coroutine scheduler.
        // Guarded so a scheduler problem can only cost the probe, never the match.
        try {
            Promise<Int> hb = this.heartbeat();
        } catch (Exception e) {
            Log::warn("[AutoMatch] heartbeat coroutine could not start: " + e.getMessage());
        }

        this.enterPhase(PHASE_BOOT, "BOOT");
    }

    public function onUpdate(float deltaTime): void {
        if (!this.enabled || this.phase == PHASE_DONE) {
            return;
        }
        this.t = this.t + deltaTime;

        if (this.phase != PHASE_BOOT) {
            this.statAccum = this.statAccum + deltaTime;
            if (this.statAccum >= 1.0) {
                this.statAccum = 0.0;
                this.emitStat();
            }
        }

        if (this.phase == PHASE_BOOT) {
            this.tickBoot();
        } else if (this.phase == PHASE_BUILD) {
            this.tickBuild();
        } else if (this.phase == PHASE_TRAIN) {
            this.tickTrain();
        } else if (this.phase == PHASE_STAGE) {
            this.tickStage();
        } else if (this.phase == PHASE_ASSAULT) {
            this.tickAssault();
        } else if (this.phase == PHASE_DEFEND) {
            this.tickDefend();
        } else if (this.phase == PHASE_SOAK) {
            this.tickSoak();
        }
    }

    public function onDestroy(): void {
        this.running = false;
    }

    // ---- public API ----

    public function isRunning(): bool {
        return this.enabled && this.phase != PHASE_DONE;
    }

    // ---- heartbeat probe (first coroutine in the project; see header) ----

    public function async heartbeat(): Promise<Int> {
        while (this.running) {
            await Coroutine::waitForSeconds(1.0);
            this.heartbeatTicks = this.heartbeatTicks + 1;
            Log::info("COROUTINE,tick," + parsePrimitive(this.heartbeatTicks));
        }
        return new Int(this.heartbeatTicks);
    }

    // ---- phases ----

    // Resolve every peer the scenario needs. They are created in the same script pass
    // as this controller (all on GameSystems, this one last), but BuildingCommandController
    // spawns the enemy bases/guards from ITS onStart, so wait a moment before acting.
    private function tickBoot(): void {
        if (this.hud == null) {
            int hudId = Entity::findByName("RTS_HUD_Controller");
            if (hudId >= 0) {
                this.hud = Entity::getScript<RTSHUDController>(hudId, "RTSHUDController");
            }
        }
        if (this.placement == null) {
            this.placement = this.gameObject().getScript<BuildingPlacementController>("BuildingPlacementController");
        }
        if (this.command == null) {
            this.command = this.gameObject().getScript<BuildingCommandController>("BuildingCommandController");
        }
        if (this.deaths == null) {
            this.deaths = this.gameObject().getScript<DeathController>("DeathController");
        }
        if (this.matchCtl == null) {
            this.matchCtl = this.gameObject().getScript<MatchController>("MatchController");
        }

        bool allResolved = this.hud != null && this.placement != null && this.command != null
            && this.deaths != null && this.matchCtl != null;

        // Settle for one second even when everything resolved on the first frame.
        if (allResolved && this.sincePhase() >= 1.0) {
            this.assertTrue("controllers_resolved", true, "all peers resolved");
            this.enterPhase(PHASE_BUILD, "BUILD");
            return;
        }
        if (this.sincePhase() >= this.bootTimeoutSec) {
            this.assertTrue("controllers_resolved", false, "missing=" + this.missingPeers());
            this.finishRun("ABORT");
        }
    }

    // One placement per frame so each one's log lines stay attributable.
    private function tickBuild(): void {
        BuildingPlacementController? place = this.placement;
        RTSHUDController? h = this.hud;
        if (place == null || h == null) {
            this.finishRun("ABORT");
            return;
        }

        if (this.buildStep == 0) {
            this.commandCenterId = place.placeAt(SLOT_COMMAND, new Vec3f(this.ccX, 0.0, this.ccZ), 0);
            this.assertTrue("place_CommandCenter", this.commandCenterId >= 0, "id=" + parsePrimitive(this.commandCenterId));
        } else if (this.buildStep == 1) {
            this.powerId = place.placeAt(SLOT_POWER, new Vec3f(this.powerX, 0.0, this.powerZ), 0);
            this.assertTrue("place_Power", this.powerId >= 0, "id=" + parsePrimitive(this.powerId));
        } else if (this.buildStep == 2) {
            this.barracksId = place.placeAt(SLOT_BARRACKS, new Vec3f(this.barracksX, 0.0, this.barracksZ), 0);
            this.assertTrue("place_Barracks", this.barracksId >= 0, "id=" + parsePrimitive(this.barracksId));
        } else if (this.buildStep == 3) {
            this.refineryId = place.placeAt(SLOT_REFINERY, new Vec3f(this.refineryX, 0.0, this.refineryZ), 0);
            this.assertTrue("place_Refinery", this.refineryId >= 0, "id=" + parsePrimitive(this.refineryId));
        } else {
            int gold = h.getGold();
            this.assertTrue("gold_after_build", gold == this.goldAfterBuild,
                "gold=" + parsePrimitive(gold) + " expected=" + parsePrimitive(this.goldAfterBuild));
            this.enterPhase(PHASE_TRAIN, "TRAIN");
            return;
        }
        this.buildStep = this.buildStep + 1;
    }

    // Queue the soldiers once (the per-building queue holds 8), then wait for them to
    // walk out of the barracks.
    private function tickTrain(): void {
        BuildingCommandController? cmd = this.command;
        RTSHUDController? h = this.hud;
        if (cmd == null || h == null) {
            this.finishRun("ABORT");
            return;
        }

        if (!this.trainQueued) {
            this.trainQueued = true;
            if (this.barracksId < 0) {
                this.assertTrue("soldiers_queued", false, "no barracks");
                this.afterTrain();
                return;
            }
            int queued = 0;
            for (int i = 0; i < this.soldiersToTrain; i = i + 1) {
                if (cmd.queueUnit(this.barracksId, "Soldier")) {
                    queued = queued + 1;
                }
            }
            this.assertTrue("soldiers_queued", queued == this.soldiersToTrain,
                "queued=" + parsePrimitive(queued) + " expected=" + parsePrimitive(this.soldiersToTrain));
            return;
        }

        int count = this.countPlayerSoldiers();
        if (count >= this.soldiersToTrain) {
            this.assertTrue("soldiers_spawned", true, "count=" + parsePrimitive(count));
            int gold = h.getGold();
            this.assertTrue("gold_after_train", gold == this.goldAfterTrain,
                "gold=" + parsePrimitive(gold) + " expected=" + parsePrimitive(this.goldAfterTrain));
            this.afterTrain();
            return;
        }
        if (this.sincePhase() >= this.trainTimeoutSec) {
            this.assertTrue("soldiers_spawned", false,
                "count=" + parsePrimitive(count) + " after " + parsePrimitive(this.trainTimeoutSec) + "s");
            this.afterTrain();
        }
    }

    private function afterTrain(): void {
        if (this.scenario == "defend") {
            this.enterPhase(PHASE_DEFEND, "DEFEND");
        } else if (this.scenario == "soak") {
            this.enterPhase(PHASE_SOAK, "SOAK");
        } else {
            this.enterPhase(PHASE_STAGE, "STAGE");
        }
    }

    // Group-move the army to the staging point and wait for the crowd to arrive.
    private function tickStage(): void {
        BuildingCommandController? cmd = this.command;
        if (cmd == null) {
            this.finishRun("ABORT");
            return;
        }

        if (this.groupId < 0 && this.soldierIds.length == 0) {
            this.soldierIds = this.collectPlayerSoldiers();
            if (this.soldierIds.length == 0) {
                this.assertTrue("staged", false, "no soldiers to stage");
                this.enterPhase(PHASE_ASSAULT, "ASSAULT");
                return;
            }
            this.groupId = cmd.orderMove(this.soldierIds, new Vec3f(this.stageX, 0.0, this.stageZ));
            if (this.groupId < 0) {
                this.assertTrue("staged", false, "orderMove returned -1");
                this.enterPhase(PHASE_ASSAULT, "ASSAULT");
            }
            return;
        }

        if (Navmesh::isGroupArrived(this.groupId)) {
            this.assertTrue("staged", true,
                "group=" + parsePrimitive(this.groupId) + " t=" + parsePrimitive(this.sincePhase()));
            this.enterPhase(PHASE_ASSAULT, "ASSAULT");
            return;
        }
        if (this.sincePhase() >= this.stageTimeoutSec) {
            this.assertTrue("staged", false,
                "group=" + parsePrimitive(this.groupId) + " not arrived after "
                + parsePrimitive(this.stageTimeoutSec) + "s");
            this.enterPhase(PHASE_ASSAULT, "ASSAULT");
        }
    }

    // Attack the nearest enemy base; auto-acquire (slice 1) deals with its guards.
    // Ends when MatchController decides, or when the run budget is spent.
    private function tickAssault(): void {
        BuildingCommandController? cmd = this.command;
        MatchController? m = this.matchCtl;
        if (cmd == null || m == null) {
            this.finishRun("ABORT");
            return;
        }

        if (!this.assaultOrdered) {
            this.assaultOrdered = true;
            this.guardIds = this.collectEnemyUnits();
            int[] army = this.collectPlayerSoldiers();
            int target = this.nearestEnemyBase(this.stageX, this.stageZ);
            if (army.length == 0 || target < 0) {
                this.assertTrue("assault_ordered", false,
                    "army=" + parsePrimitive(army.length) + " target=" + parsePrimitive(target));
            } else {
                cmd.orderAttack(army, target);
                this.assertTrue("assault_ordered", true,
                    "army=" + parsePrimitive(army.length) + " target=" + parsePrimitive(target));
            }
            return;
        }

        if (m.isOver()) {
            this.finishCombat(m);
            return;
        }
        if (this.t >= this.timeoutSec) {
            this.assertTrue("assault_timeout", false, "match still running at t=" + parsePrimitive(this.t));
            this.finishCombat(m);
        }
    }

    // Hold the base and let the enemy come.
    private function tickDefend(): void {
        MatchController? m = this.matchCtl;
        if (m == null) {
            this.finishRun("ABORT");
            return;
        }
        if (m.isOver() || this.waveNumber() >= this.defendWaves) {
            this.finishCombat(m);
            return;
        }
        if (this.t >= this.timeoutSec) {
            this.assertTrue("defend_timeout", false,
                "waves=" + parsePrimitive(this.waveNumber()) + " at t=" + parsePrimitive(this.t));
            this.finishCombat(m);
        }
    }

    // Do nothing but collect STAT rows until the budget runs out.
    private function tickSoak(): void {
        MatchController? m = this.matchCtl;
        if (m != null && m.isOver()) {
            // A result during a soak is still a clean end (the enemy may have won).
            this.finishCombat(m);
            return;
        }
        if (this.t >= this.timeoutSec) {
            this.assertTrue("soak_completed", true, "t=" + parsePrimitive(this.t));
            this.finishRun("SOAK");
        }
    }

    // Shared tail of the combat scenarios: did the enemy actually fight back, did
    // anything die, how did the match end.
    private function finishCombat(MatchController m): void {
        int waves = this.waveNumber();
        this.assertTrue("wave_arrived", waves >= 1, "waves=" + parsePrimitive(waves));

        int guardsDown = 0;
        for (int i = 0; i < this.guardIds.length; i = i + 1) {
            int gid = this.guardIds[i];
            if (!Entity::isValid(gid) || !Combat::isAlive(gid)) {
                guardsDown = guardsDown + 1;
            }
        }
        if (this.scenario == "assault") {
            this.assertTrue("enemy_guard_died", guardsDown > 0,
                "down=" + parsePrimitive(guardsDown) + "/" + parsePrimitive(this.guardIds.length));
        }

        string tag = "TIMEOUT";
        if (m.getResult() == MatchController::RESULT_WIN) {
            tag = "WIN";
        } else if (m.getResult() == MatchController::RESULT_LOSE) {
            tag = "LOSE";
        }
        this.assertTrue("match_over", m.isOver(), "result=" + tag);
        this.finishRun(tag);
    }

    // ---- end of run ----

    private function finishRun(string tag): void {
        if (this.ended) {
            return;
        }
        this.ended = true;
        this.running = false;
        this.phase = PHASE_DONE;

        Log::info("MATCH,END," + tag + "," + parsePrimitive(this.t));

        // Request the quit FIRST: it only sets a flag (the host closes/stops after this
        // frame), so even if the digest below throws, the process still ends with the
        // right exit code instead of idling until the wrapper's timeout.
        int code = 0;
        if (this.fails > 0) {
            code = 1;
        }
        App::quit(code);

        this.writeResult(tag);
    }

    // Best-effort digest next to the wrapper's artifacts; a failure here must never
    // affect the verdict, which lives in the log + exit code.
    private function writeResult(string tag): void {
        try {
            AutoMatchResult r = new AutoMatchResult();
            r.scenario = this.scenario;
            r.result = tag;
            r.passes = this.passes;
            r.fails = this.fails;
            r.seconds = this.t;
            r.heartbeatTicks = this.heartbeatTicks;
            r.waves = this.waveNumber();
            DeathController? d = this.deaths;
            if (d != null) {
                r.deaths = d.getDeathCount();
            }
            Json::writeToFile("tools/out/last_result.json", r);
        } catch (Exception e) {
            Log::warn("[AutoMatch] could not write tools/out/last_result.json: " + e.getMessage());
        }
    }

    // ---- helpers ----

    private function enterPhase(int p, string name): void {
        this.phase = p;
        this.phaseStart = this.t;
        Log::info("PHASE," + name + "," + parsePrimitive(this.t));
    }

    private function sincePhase(): float {
        return this.t - this.phaseStart;
    }

    private function assertTrue(string name, bool ok, string detail): void {
        if (ok) {
            this.passes = this.passes + 1;
            Log::info("ASSERT," + name + ",PASS," + detail);
        } else {
            this.fails = this.fails + 1;
            Log::error("ASSERT," + name + ",FAIL," + detail);
        }
    }

    private function missingPeers(): string {
        string s = "";
        if (this.hud == null) { s = s + "hud "; }
        if (this.placement == null) { s = s + "placement "; }
        if (this.command == null) { s = s + "command "; }
        if (this.deaths == null) { s = s + "deaths "; }
        if (this.matchCtl == null) { s = s + "match "; }
        return s;
    }

    private function waveNumber(): int {
        BuildingCommandController? cmd = this.command;
        if (cmd == null) {
            return 0;
        }
        return cmd.getWaveNumber();
    }

    private function emitStat(): void {
        int gold = -1;
        RTSHUDController? h = this.hud;
        if (h != null) {
            gold = h.getGold();
        }
        int pUnits = 0;
        int eUnits = 0;
        int pBuildings = 0;
        int eBuildings = 0;
        int[] ids = PluginComponent::findAll("Health");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Combat::isAlive(id) || !PluginComponent::has(id, "Team")) {
                continue;
            }
            int team = PluginComponent::getInt(id, "Team", "teamId");
            if (team == TEAM_PLAYER) {
                if (PluginComponent::has(id, "Selectable")) {
                    pUnits = pUnits + 1;
                } else {
                    pBuildings = pBuildings + 1;
                }
            } else {
                if (Entity::getName(id) == "EnemyBuilding") {
                    eBuildings = eBuildings + 1;
                } else {
                    eUnits = eUnits + 1;
                }
            }
        }
        Log::info("STAT," + parsePrimitive(this.t)
            + "," + parsePrimitive(Stats::getFps())
            + "," + parsePrimitive(Stats::getCpuMs())
            + "," + parsePrimitive(Stats::getGpuMs())
            + "," + parsePrimitive(Stats::getDrawCalls())
            + "," + parsePrimitive(pUnits)
            + "," + parsePrimitive(eUnits)
            + "," + parsePrimitive(pBuildings)
            + "," + parsePrimitive(eBuildings)
            + "," + parsePrimitive(gold));
    }

    // Living player units: Team 0 + Health + Selectable (units get Selectable at spawn,
    // buildings do not).
    private function countPlayerSoldiers(): int {
        return this.collectPlayerSoldiers().length;
    }

    private function collectPlayerSoldiers(): int[] {
        int[] ids = PluginComponent::findAll("Selectable");
        int[] scratch = new int[ids.length];
        int n = 0;
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Combat::isAlive(id) || !PluginComponent::has(id, "Team")) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") != TEAM_PLAYER) {
                continue;
            }
            scratch[n] = id;
            n = n + 1;
        }
        int[] out = new int[n];
        for (int j = 0; j < n; j = j + 1) {
            out[j] = scratch[j];
        }
        return out;
    }

    // Living enemy units (team 1, Health, not a base).
    private function collectEnemyUnits(): int[] {
        int[] ids = PluginComponent::findAll("Health");
        int[] scratch = new int[ids.length];
        int n = 0;
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Combat::isAlive(id) || !PluginComponent::has(id, "Team")) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") == TEAM_PLAYER) {
                continue;
            }
            if (Entity::getName(id) == "EnemyBuilding") {
                continue;
            }
            scratch[n] = id;
            n = n + 1;
        }
        int[] out = new int[n];
        for (int j = 0; j < n; j = j + 1) {
            out[j] = scratch[j];
        }
        return out;
    }

    private function nearestEnemyBase(float fromX, float fromZ): int {
        int best = -1;
        float bestD2 = 0.0;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id) || !Combat::isAlive(id)) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") == TEAM_PLAYER) {
                continue;
            }
            if (Entity::getName(id) != "EnemyBuilding") {
                continue;
            }
            Vec3f p = Entity::getPosition(id);
            float dx = p.x - fromX;
            float dz = p.z - fromZ;
            float d2 = dx * dx + dz * dz;
            if (best < 0 || d2 < bestD2) {
                best = id;
                bestD2 = d2;
            }
        }
        return best;
    }
}
