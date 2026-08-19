// MatchController - the skirmish's win/lose condition and restart (VK-1298 slice 1).
//
// With DeathController making things actually die, the match can finally end:
//
//   WIN  - no living enemy command structure is left. Enemy bases are the entities
//          ai/EnemyBases.mt names "EnemyBuilding" and puts on team 1; they are the
//          only enemy structures in the skirmish.
//   LOSE - the player had a Command Center and no longer has a living one. The
//          "had one" latch matters: at t=0 the player has built nothing, so a
//          naive "no CC alive" test would declare a loss on the first frame.
//
// The player's Command Center is identified through SelectionController's building
// registry (BuildingInfo.buildingType == "CommandCenter"), which
// BuildingPlacementController fills on every placement -- the plugin Team/Health
// components alone cannot tell a Command Center from a Barracks.
//
// TIME IS NOT STOPPED ON A RESULT, deliberately. Time::freeze / setScale(0) halts
// the engine's whole Scripts task, which would also stop THIS controller -- so the
// restart key would never be read again. The match simply stops spawning waves
// (EnemyCommander polls isOver()) and shows a banner.
//
// RESTART is R, and it is only accepted once the match is over. R is already bound
// to "rotate the placement ghost" in BuildingPlacementController; gating on the
// result keeps the two from fighting, because placement is over by then.
//
// Attach this @Script to the GameSystems entity alongside the other controllers.

import * from "../../lib/engine/oop/Behaviour.mt";
import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/Input.mt";
import * from "../../lib/engine/Key.mt";
import * from "../../lib/engine/Scene.mt";
import * from "../../lib/engine/PluginComponent.mt";
import * from "../../lib/engine/Log.mt";
import * from "./SelectionController.mt";
import * from "./RTSHUDController.mt";
import * from "../data/BuildingInfo.mt";
import * from "../util/Combat.mt";
import * from "../util/Config.mt";
import * from "../util/InputEdge.mt";

@Script
class MatchController extends Behaviour {
    // 0 = still playing, 1 = player won, 2 = player lost.
    public static final int RESULT_RUNNING = 0;
    public static final int RESULT_WIN = 1;
    public static final int RESULT_LOSE = 2;

    private int result;

    // Seconds since the match started, logged with the result so a smoke run can
    // tell a 30-second stomp from a 9-minute grind.
    private float matchTime;

    // Evaluation is cheap but not free (two findAll scans), and a win/lose does not
    // need frame precision -- 0.5 s is imperceptible and 120x cheaper than per-frame.
    private float checkInterval;
    private float checkAccum;

    // Nothing is evaluated for the first graceSeconds. The scene starts with no
    // player buildings and the enemy bases are spawned from
    // BuildingCommandController.onStart, so an immediate check would race the
    // bootstrap and could declare a win before the bases exist.
    private float graceSeconds;

    // Latch: the player owned a living Command Center at some point. Without it,
    // "no CC alive" is true from the first frame and every match starts as a loss.
    private bool hadCommandCenter;

    private SelectionController? selection;
    private RTSHUDController? hud;

    private InputEdge restartEdge;

    // Scene reloaded on restart. Matches RTSDemo.vfproj's startupScene.
    private string scenePath;

    public constructor() : super() {
        this.result = 0;
        this.matchTime = 0.0;
        this.checkInterval = 0.5;
        this.checkAccum = 0.0;
        this.graceSeconds = 3.0;
        this.hadCommandCenter = false;
        this.selection = null;
        this.hud = null;
        this.scenePath = "scenes/Skirmish_01.vfScene";
    }

    public function onStart(): void {
        this.restartEdge = new InputEdge();

        // SelectionController shares this GameSystems entity; the HUD controller
        // lives on its own RTS_HUD_Controller entity (same lookup
        // BuildingCommandController uses).
        this.selection = this.gameObject().getScript<SelectionController>("SelectionController");
        int hudId = Entity::findByName("RTS_HUD_Controller");
        if (hudId >= 0) {
            this.hud = Entity::getScript<RTSHUDController>(hudId, "RTSHUDController");
        } else {
            Log::warn("[Match] RTS_HUD_Controller not found; no result banner.");
        }

        Log::info("[Match] ready.");
    }

    public function onUpdate(float deltaTime): void {
        this.matchTime = this.matchTime + deltaTime;

        if (this.result != RESULT_RUNNING) {
            this.handleRestart();
            return;
        }

        if (this.matchTime < this.graceSeconds) {
            return;
        }

        this.checkAccum = this.checkAccum + deltaTime;
        if (this.checkAccum < this.checkInterval) {
            return;
        }
        this.checkAccum = 0.0;
        this.evaluate();
    }

    public function onDestroy(): void {
    }

    // ---- public API ----

    // True once the match has been decided. EnemyCommander stops sending waves on
    // this; Slice 2's automated harness ends its run on it.
    public function isOver(): bool {
        return this.result != RESULT_RUNNING;
    }

    // RESULT_RUNNING / RESULT_WIN / RESULT_LOSE.
    public function getResult(): int {
        return this.result;
    }

    public function getMatchTime(): float {
        return this.matchTime;
    }

    // ---- evaluation ----

    private function evaluate(): void {
        if (this.aliveEnemyBases() == 0) {
            this.finish(RESULT_WIN);
            return;
        }

        int playerCCs = this.alivePlayerCommandCenters();
        if (playerCCs > 0) {
            this.hadCommandCenter = true;
        } else if (this.hadCommandCenter) {
            this.finish(RESULT_LOSE);
        }
    }

    // Living enemy command structures. EnemyBases names every base it spawns
    // "EnemyBuilding" and puts it on team 1, so name + team + health is an exact
    // test with no extra registry.
    private function aliveEnemyBases(): int {
        int n = 0;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id)) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") == Config::TEAM_PLAYER) {
                continue;
            }
            if (Entity::getName(id) != "EnemyBuilding") {
                continue;
            }
            if (Combat::isAlive(id)) {
                n = n + 1;
            }
        }
        return n;
    }

    // Living player Command Centers. The building TYPE only exists in
    // SelectionController's registry (BuildingPlacementController registers a
    // BuildingInfo per placement), so the scan goes through it rather than through
    // the plugin components, which cannot distinguish building types.
    private function alivePlayerCommandCenters(): int {
        SelectionController? sel = this.selection;
        if (sel == null) {
            return 0;
        }

        int n = 0;
        int[] ids = PluginComponent::findAll("Team");
        for (int i = 0; i < ids.length; i = i + 1) {
            int id = ids[i];
            if (!Entity::isValid(id)) {
                continue;
            }
            if (PluginComponent::getInt(id, "Team", "teamId") != Config::TEAM_PLAYER) {
                continue;
            }
            if (!Combat::isAlive(id)) {
                continue;
            }
            BuildingInfo? info = sel.findInfo(id);
            if (info != null && info.buildingType == "CommandCenter") {
                n = n + 1;
            }
        }
        return n;
    }

    private function finish(int outcome): void {
        this.result = outcome;

        string label = "DEFEAT";
        string tag = "LOSE";
        if (outcome == RESULT_WIN) {
            label = "VICTORY";
            tag = "WIN";
        }

        // 999 s so the banner outlives the alert ticker's normal timeout and stays
        // up until the player restarts.
        RTSHUDController? h = this.hud;
        if (h != null) {
            h.pushAlertMessage(label + " -- press R to restart", 999.0);
        }
        Log::info("MATCH,RESULT," + tag + ",t=" + parsePrimitive(this.matchTime));
    }

    // ---- restart ----

    // Reloading the scene is a full teardown + rebuild; every controller's onStart
    // runs again, so a second "[BuildingCommand] ready." in the log is the marker
    // that the restart actually took.
    private function handleRestart(): void {
        this.restartEdge.step(Input::isKeyDown(Key::R));
        if (!this.restartEdge.wasPressed) {
            return;
        }
        Log::info("MATCH,RESTART");
        Scene::load(this.scenePath);
    }
}
