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
import * from "./BuildingInfo.mt";
import * from "./SelectionController.mt";

@Script
class RTSHUDController implements IUIButtonListener {
    private GameState state;

    private int goldLabelId;
    private int selectionNameId;
    private int selectionStatusId;
    private int selectionHealthBarId;
    private int selectionIconId;
    private int alertLabelId;

    private int buildSlot0Id;
    private int buildSlot1Id;

    private int cmdMoveId;
    private int cmdAttackMoveId;
    private int cmdStopId;
    private int cmdHoldId;
    private int cmdBuildId;

    // Command-card buttons in display order + their default (no-selection) labels.
    private int[] cmdButtons;
    private string[] defaultCmdLabels;

    // SelectionController (on the GameSystems entity) drives the selection panel.
    private int selectionOwnerId;
    private SelectionController selection;

    // Last entity id whose command card was applied, so the card is only rebuilt
    // when the selection actually changes (-2 = nothing applied yet, -1 = none).
    private int lastShownId;

    constructor() {
        this.goldLabelId = -1;
        this.selectionNameId = -1;
        this.selectionStatusId = -1;
        this.selectionHealthBarId = -1;
        this.selectionIconId = -1;
        this.alertLabelId = -1;
        this.buildSlot0Id = -1;
        this.buildSlot1Id = -1;
        this.cmdMoveId = -1;
        this.cmdAttackMoveId = -1;
        this.cmdStopId = -1;
        this.cmdHoldId = -1;
        this.cmdBuildId = -1;
        this.selectionOwnerId = -1;
        this.selection = null;
        this.lastShownId = -2;
    }

    public function onStart(): void {
        this.state = new GameState();

        this.goldLabelId = this.resolve("RTS_HUD_GoldLabel");
        this.selectionNameId = this.resolve("RTS_HUD_SelectionName");
        this.selectionStatusId = this.resolve("RTS_HUD_SelectionStatus");
        this.selectionHealthBarId = this.resolve("RTS_HUD_SelectionHealthBar");
        this.selectionIconId = this.resolve("RTS_HUD_SelectionIcon");
        this.alertLabelId = this.resolve("RTS_HUD_AlertLabel");

        this.buildSlot0Id = this.resolve("RTS_HUD_BuildSlot_0");
        this.buildSlot1Id = this.resolve("RTS_HUD_BuildSlot_1");

        this.cmdMoveId = this.resolve("RTS_HUD_CmdMove");
        this.cmdAttackMoveId = this.resolve("RTS_HUD_CmdAttackMove");
        this.cmdStopId = this.resolve("RTS_HUD_CmdStop");
        this.cmdHoldId = this.resolve("RTS_HUD_CmdHold");
        this.cmdBuildId = this.resolve("RTS_HUD_CmdBuild");

        this.cmdButtons = new int[5];
        this.cmdButtons[0] = this.cmdMoveId;
        this.cmdButtons[1] = this.cmdAttackMoveId;
        this.cmdButtons[2] = this.cmdStopId;
        this.cmdButtons[3] = this.cmdHoldId;
        this.cmdButtons[4] = this.cmdBuildId;

        this.defaultCmdLabels = new string[5];
        this.defaultCmdLabels[0] = "M";
        this.defaultCmdLabels[1] = "A";
        this.defaultCmdLabels[2] = "S";
        this.defaultCmdLabels[3] = "H";
        this.defaultCmdLabels[4] = "B";

        this.selectionOwnerId = Entity::findByName("GameSystems");

        this.seedWidgets();
    }

    public function onUpdate(float deltaTime): void {
        this.state.update(deltaTime);

        if (this.goldLabelId >= 0) {
            UI::setLabelText(this.goldLabelId, "Gold: " + parsePrimitive(this.state.gold));
        }
        if (this.alertLabelId >= 0) {
            UI::setLabelText(this.alertLabelId, this.state.alert);
        }

        if (this.buildSlot0Id >= 0) { UI::setLabelText(this.buildSlot0Id, this.state.getBuildSlot(0)); }
        if (this.buildSlot1Id >= 0) { UI::setLabelText(this.buildSlot1Id, this.state.getBuildSlot(1)); }

        // Selection context panel (VK-1348): driven by SelectionController.
        SelectionController sel = this.selectionController();
        int selId = -1;
        BuildingInfo? info = null;
        if (sel != null) {
            selId = sel.getSelectedId();
            info = sel.findInfo(selId);
        }

        if (info == null) {
            this.clearSelectionPanel();
            if (this.lastShownId != -1) {
                this.restoreDefaultCommandCard();
                this.lastShownId = -1;
            }
        } else {
            if (this.selectionNameId >= 0) { UI::setLabelText(this.selectionNameId, info.displayName); }
            if (this.selectionStatusId >= 0) { UI::setLabelText(this.selectionStatusId, this.statusFor(info)); }
            if (this.selectionHealthBarId >= 0) { UI::setProgressBarValue(this.selectionHealthBarId, info.healthFraction()); }
            if (this.selectionIconId >= 0) {
                Entity::setActive(this.selectionIconId, true);
                if (info.iconPath != "") { UI::setImageTexture(this.selectionIconId, info.iconPath); }
            }
            if (this.lastShownId != selId) {
                this.applyCommandCard(info);
                this.lastShownId = selId;
            }
        }
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
        // If a player building is selected, command buttons issue that building's
        // (stub) orders against the current selection (VK-1348). Real production
        // lands with VK-1312.
        SelectionController sel = this.selectionController();
        BuildingInfo? info = null;
        if (sel != null) { info = sel.getSelectedInfo(); }
        if (info != null && info.isPlayer()) {
            int idx = this.cmdIndexFor(buttonEntityId);
            if (idx >= 0 && idx < info.commands.length) {
                this.state.pushAlert(info.displayName + ": " + info.commands[idx], 2.0);
                return;
            }
        }

        // Default (no building selected): existing unit-command stubs.
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
        // Nothing is selected at startup -> show the empty selection panel.
        this.clearSelectionPanel();
        if (this.alertLabelId >= 0) {
            UI::setLabelText(this.alertLabelId, "");
        }
        if (this.buildSlot0Id >= 0) { UI::setLabelText(this.buildSlot0Id, this.state.getBuildSlot(0)); }
        if (this.buildSlot1Id >= 0) { UI::setLabelText(this.buildSlot1Id, this.state.getBuildSlot(1)); }
    }

    // Resolve (and cache) the SelectionController attached to GameSystems. May be
    // null until that script has loaded.
    private function selectionController(): SelectionController? {
        if (this.selection != null) {
            return this.selection;
        }
        if (this.selectionOwnerId < 0) {
            return null;
        }
        this.selection = Entity::getScript<SelectionController>(this.selectionOwnerId, "SelectionController");
        if (this.selection != null) {
            Log::info("[HUD] SelectionController resolved on GameSystems");
        }
        return this.selection;
    }

    // Empty selection panel: blank name/status, zeroed health bar, hidden portrait.
    private function clearSelectionPanel(): void {
        if (this.selectionNameId >= 0) { UI::setLabelText(this.selectionNameId, ""); }
        if (this.selectionStatusId >= 0) { UI::setLabelText(this.selectionStatusId, ""); }
        if (this.selectionHealthBarId >= 0) { UI::setProgressBarValue(this.selectionHealthBarId, 0.0); }
        if (this.selectionIconId >= 0) { Entity::setActive(this.selectionIconId, false); }
    }

    private function statusFor(BuildingInfo info): string {
        if (info.isPlayer()) {
            return info.buildingType;
        }
        return "Enemy";
    }

    // Show the selected building's command buttons (player only). Buttons beyond
    // the building's command list are hidden; enemy/neutral buildings hide all
    // command buttons (read-only info panel).
    private function applyCommandCard(BuildingInfo info): void {
        if (!info.isPlayer()) {
            for (int i = 0; i < 5; i = i + 1) {
                if (this.cmdButtons[i] >= 0) { Entity::setActive(this.cmdButtons[i], false); }
            }
            return;
        }
        int n = info.commands.length;
        for (int i = 0; i < 5; i = i + 1) {
            int bid = this.cmdButtons[i];
            if (bid >= 0) {
                if (i < n) {
                    Entity::setActive(bid, true);
                    UI::setLabelText(bid, info.commands[i]);
                } else {
                    Entity::setActive(bid, false);
                }
            }
        }
    }

    // Restore the default (no-selection) command card: all buttons visible with
    // their original letter labels (preserves the VK-1311 Build flow).
    private function restoreDefaultCommandCard(): void {
        for (int i = 0; i < 5; i = i + 1) {
            int bid = this.cmdButtons[i];
            if (bid >= 0) {
                Entity::setActive(bid, true);
                UI::setLabelText(bid, this.defaultCmdLabels[i]);
            }
        }
    }

    private function cmdIndexFor(int buttonEntityId): int {
        for (int i = 0; i < 5; i = i + 1) {
            if (this.cmdButtons[i] >= 0 && this.cmdButtons[i] == buttonEntityId) {
                return i;
            }
        }
        return -1;
    }
}
