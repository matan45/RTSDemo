// RTSHUDController - Drives the RTS skirmish HUD shell (VK-1324).
//
// Looks up the HUD widget entities by name on startup, then each frame pushes
// stubbed GameState values into the runtime UI components. Implements
// IUIButtonListener so the command buttons (Move / A-Move / Stop / Hold /
// Build) route through GameState.onCommand. Initializes the minimap render
// target so the top-down camera entity feeds the minimap UIImage.

import * from "../lib/engine/Entity.mt";
import * from "../lib/engine/UI.mt";
import * from "../lib/engine/Log.mt";
import * from "../lib/engine/RenderTexture.mt";
import * from "../lib/engine/RenderTextureUpdateMode.mt";
import * from "../lib/engine/IUIButtonListener.mt";
import * from "./GameState.mt";

@Script
class RTSHUDController implements IUIButtonListener {
    private GameState state;

    private int goldLabelId;
    private int selectionNameId;
    private int selectionStatusId;
    private int selectionHealthBarId;
    private int alertLabelId;

    private int buildSlot0Id;
    private int buildSlot1Id;

    private int cmdMoveId;
    private int cmdAttackMoveId;
    private int cmdStopId;
    private int cmdHoldId;
    private int cmdBuildId;

    constructor() {
        this.goldLabelId = -1;
        this.selectionNameId = -1;
        this.selectionStatusId = -1;
        this.selectionHealthBarId = -1;
        this.alertLabelId = -1;
        this.buildSlot0Id = -1;
        this.buildSlot1Id = -1;
        this.cmdMoveId = -1;
        this.cmdAttackMoveId = -1;
        this.cmdStopId = -1;
        this.cmdHoldId = -1;
        this.cmdBuildId = -1;
    }

    public function onStart(): void {
        this.state = new GameState();

        this.goldLabelId = this.resolve("RTS_HUD_GoldLabel");
        this.selectionNameId = this.resolve("RTS_HUD_SelectionName");
        this.selectionStatusId = this.resolve("RTS_HUD_SelectionStatus");
        this.selectionHealthBarId = this.resolve("RTS_HUD_SelectionHealthBar");
        this.alertLabelId = this.resolve("RTS_HUD_AlertLabel");

        this.buildSlot0Id = this.resolve("RTS_HUD_BuildSlot_0");
        this.buildSlot1Id = this.resolve("RTS_HUD_BuildSlot_1");

        this.cmdMoveId = this.resolve("RTS_HUD_CmdMove");
        this.cmdAttackMoveId = this.resolve("RTS_HUD_CmdAttackMove");
        this.cmdStopId = this.resolve("RTS_HUD_CmdStop");
        this.cmdHoldId = this.resolve("RTS_HUD_CmdHold");
        this.cmdBuildId = this.resolve("RTS_HUD_CmdBuild");

        this.seedWidgets();
    }

    public function onUpdate(float deltaTime): void {
        this.state.update(deltaTime);

        if (this.goldLabelId >= 0) {
            UI::setLabelText(this.goldLabelId, "Gold: " + parsePrimitive(this.state.gold));
        }
        if (this.selectionNameId >= 0) {
            UI::setLabelText(this.selectionNameId, this.state.selectedName);
        }
        if (this.selectionStatusId >= 0) {
            UI::setLabelText(this.selectionStatusId, this.state.status);
        }
        if (this.selectionHealthBarId >= 0) {
            UI::setProgressBarValue(this.selectionHealthBarId, this.state.healthFraction());
        }
        if (this.alertLabelId >= 0) {
            UI::setLabelText(this.alertLabelId, this.state.alert);
        }

        if (this.buildSlot0Id >= 0) { UI::setLabelText(this.buildSlot0Id, this.state.getBuildSlot(0)); }
        if (this.buildSlot1Id >= 0) { UI::setLabelText(this.buildSlot1Id, this.state.getBuildSlot(1)); }
    }

    public function onDestroy(): void {
    }

    // Resource accessors used by BuildingPlacementController (VK-1311) via
    // Entity::getScript, so gold stays a single source of truth in GameState.
    public function getGold(): int {
        return this.state.gold;
    }

    public function trySpendGold(int amount): bool {
        if (this.state.gold < amount) {
            return false;
        }
        this.state.gold = this.state.gold - amount;
        return true;
    }

    @Override
    public function onButtonClicked(int buttonEntityId, string entityName): void {
        if (buttonEntityId == this.cmdMoveId)       { this.state.onCommand("Move"); return; }
        if (buttonEntityId == this.cmdAttackMoveId) { this.state.onCommand("Attack-Move"); return; }
        if (buttonEntityId == this.cmdStopId)       { this.state.onCommand("Stop"); return; }
        if (buttonEntityId == this.cmdHoldId)       { this.state.onCommand("Hold"); return; }
        if (buttonEntityId == this.cmdBuildId)      { this.state.onCommand("Build"); return; }
    }

    @Override
    public function onButtonPressed(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonReleased(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverEnter(int buttonEntityId, string entityName): void { }

    @Override
    public function onButtonHoverExit(int buttonEntityId, string entityName): void { }

    private function resolve(string name): int {
        int id = Entity::findByName(name);
        if (id < 0) {
            Log::warn("[RTSHUDController] HUD entity not found: " + name);
        }
        return id;
    }

    private function seedWidgets(): void {
        if (this.goldLabelId >= 0) {
            UI::setLabelText(this.goldLabelId, "Gold: " + parsePrimitive(this.state.gold));
        }
        if (this.selectionNameId >= 0) {
            UI::setLabelText(this.selectionNameId, this.state.selectedName);
        }
        if (this.selectionStatusId >= 0) {
            UI::setLabelText(this.selectionStatusId, this.state.status);
        }
        if (this.selectionHealthBarId >= 0) {
            UI::setProgressBarValue(this.selectionHealthBarId, this.state.healthFraction());
        }
        if (this.alertLabelId >= 0) {
            UI::setLabelText(this.alertLabelId, "");
        }
        if (this.buildSlot0Id >= 0) { UI::setLabelText(this.buildSlot0Id, this.state.getBuildSlot(0)); }
        if (this.buildSlot1Id >= 0) { UI::setLabelText(this.buildSlot1Id, this.state.getBuildSlot(1)); }
    }
}
