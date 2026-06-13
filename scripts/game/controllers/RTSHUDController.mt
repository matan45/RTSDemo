// RTSHUDController - Drives the RTS skirmish HUD shell (VK-1324).
//
// Looks up the HUD widget entities by name on startup, then each frame pushes
// stubbed GameState values into the runtime UI components. Implements
// IUIButtonListener so the command buttons route through the selected
// building's command card (the buttons are hidden while nothing is selected).
// Initializes the minimap render target so the top-down camera entity feeds
// the minimap UIImage.

import * from "../../lib/engine/Entity.mt";
import * from "../../lib/engine/UI.mt";
import * from "../../lib/engine/Log.mt";
import * from "../../lib/engine/RenderTexture.mt";
import * from "../../lib/engine/RenderTextureUpdateMode.mt";
import * from "../../lib/engine/IUIButtonListener.mt";
import * from "../data/GameState.mt";
import * from "../data/BuildingInfo.mt";
import * from "./SelectionController.mt";

@Script
class RTSHUDController implements IUIButtonListener {
    private GameState state;

    private int goldLabelId;
    private int powerLabelId;
    private int selectionNameId;
    private int selectionStatusId;
    private int selectionHealthBarId;
    private int selectionIconId;
    private int alertLabelId;

    private int buildSlot0Id;
    private int buildSlot1Id;

    // Command-card buttons + their fallback command names, in display order.
    private int[] cmdButtons;
    private string[] cmdNames;

    // Command-card font size (VK-1352): word labels (Train/Rally/Cancel)
    // shrink to WORD_CMD_FONT_SIZE so they fit the button.
    private static final float WORD_CMD_FONT_SIZE = 18.0;
    // Extra spacing between letters of word labels so they read clearly (VK-1352).
    private static final float WORD_CMD_LETTER_SPACING = 6.0;

    // SelectionController (on the GameSystems entity) drives the selection panel.
    private int selectionOwnerId;
    private SelectionController selection;

    // Last entity id whose command card was applied, so the card is only rebuilt
    // when the selection actually changes (-2 = nothing applied yet, -1 = none).
    private int lastShownId;

    // Tracks the power label's warning tint so the color command is only
    // re-issued when the net-power sign actually flips.
    private bool lastPowerNegative;

    constructor() {
        this.goldLabelId = -1;
        this.powerLabelId = -1;
        this.selectionNameId = -1;
        this.selectionStatusId = -1;
        this.selectionHealthBarId = -1;
        this.selectionIconId = -1;
        this.alertLabelId = -1;
        this.buildSlot0Id = -1;
        this.buildSlot1Id = -1;
        this.selectionOwnerId = -1;
        this.selection = null;
        this.lastShownId = -2;
        this.lastPowerNegative = false;
    }

    public function onStart(): void {
        this.state = new GameState();

        this.goldLabelId = this.resolve("RTS_HUD_GoldLabel");
        this.powerLabelId = this.resolve("RTS_HUD_PowerLabel");
        this.selectionNameId = this.resolve("RTS_HUD_SelectionName");
        this.selectionStatusId = this.resolve("RTS_HUD_SelectionStatus");
        this.selectionHealthBarId = this.resolve("RTS_HUD_SelectionHealthBar");
        this.selectionIconId = this.resolve("RTS_HUD_SelectionIcon");
        this.alertLabelId = this.resolve("RTS_HUD_AlertLabel");

        this.buildSlot0Id = this.resolve("RTS_HUD_BuildSlot_0");
        this.buildSlot1Id = this.resolve("RTS_HUD_BuildSlot_1");

        this.cmdButtons = new int[5];
        this.cmdButtons[0] = this.resolve("RTS_HUD_CmdMove");
        this.cmdButtons[1] = this.resolve("RTS_HUD_CmdAttackMove");
        this.cmdButtons[2] = this.resolve("RTS_HUD_CmdStop");
        this.cmdButtons[3] = this.resolve("RTS_HUD_CmdHold");
        this.cmdButtons[4] = this.resolve("RTS_HUD_CmdBuild");

        this.cmdNames = new string[5];
        this.cmdNames[0] = "Move";
        this.cmdNames[1] = "Attack-Move";
        this.cmdNames[2] = "Stop";
        this.cmdNames[3] = "Hold";
        this.cmdNames[4] = "Build";

        this.selectionOwnerId = Entity::findByName("GameSystems");

        this.seedWidgets();
        this.skinHud();
        // Command card stays hidden until a player building is selected.
        this.hideCommandCard();
    }

    public function onUpdate(float deltaTime): void {
        this.state.update(deltaTime);

        if (this.goldLabelId >= 0) {
            UI::setLabelText(this.goldLabelId, "Gold: " + parsePrimitive(this.state.gold));
        }
        this.updatePowerLabel();
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
                this.hideCommandCard();
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

    // Refund gold (sell) / harvester deposits, via BuildingCommandController.
    public function addGold(int amount): void {
        this.state.gold = this.state.gold + amount;
    }

    // Surface a command-card action message through the existing alert ticker
    // (BuildingCommandController has no GameState of its own).
    public function pushAlertMessage(string message, float seconds): void {
        this.state.pushAlert(message, seconds);
    }

    public function getPower(): int {
        return this.state.power;
    }

    // Apply a building's power delta (+ from power plants, - from consumers).
    public function addPower(int delta): void {
        this.state.power = this.state.power + delta;
    }

    @Override
    public function onButtonClicked(int buttonEntityId, string entityName): void {
        // Command-card execution lives in BuildingCommandController (a separate
        // IUIButtonListener on GameSystems): Sell / Upgrade / Rally / Train /
        // Track. This controller only renders the card (applyCommandCard) and
        // owns the resource labels, so when a player building is selected the
        // click is left for that controller to act on.
        SelectionController sel = this.selectionController();
        BuildingInfo? info = null;
        if (sel != null) { info = sel.getSelectedInfo(); }
        if (info != null && info.isPlayer()) {
            int idx = this.cmdIndexFor(buttonEntityId);
            if (idx >= 0 && idx < info.commands.length) {
                return;
            }
        }

        // Fallback unit-command stubs. Unreachable while the command card is
        // hidden with no selection; kept as a safety net until real unit
        // commands land (VK-1302).
        int fallbackIdx = this.cmdIndexFor(buttonEntityId);
        if (fallbackIdx >= 0) {
            this.state.onCommand(this.cmdNames[fallbackIdx]);
        }
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

    // Apply the imported HUD skin textures to the non-interactive panel/strip
    // entities at runtime (VK-1348/1352 setImageTexture). Each target keeps its
    // authored 9-patch border/imageType; we only swap the texture and force a
    // white tint so the dark authored colorTint doesn't darken the new skin.
    //
    // Buttons (command card + build-queue slots) are NOT skinned here: they use
    // the UIButton component's per-state textures (Normal/Hover/Pressed),
    // authored in the editor, which the UI interaction system swaps per state in
    // play mode. Driving their UIImage texture from script would just fight that.
    private function skinHud(): void {
        string hud = "assets/ui/hud/";

        // Background panels + strips (plain UIImage): texture + white tint.
        this.skinImage("RTS_HUD_CommandBar", hud + "hud_panel_wide.vfImage");
        this.skinImage("RTS_HUD_AlertStrip", hud + "hud_panel_wide.vfImage");
        this.skinImage("RTS_HUD_CommandGrid", hud + "hud_panel_medium.vfImage");
        this.skinImage("RTS_HUD_SelectionPanel", hud + "hud_panel_medium.vfImage");
        this.skinImage("RTS_HUD_BuildQueue", hud + "hud_panel_tall.vfImage");
        this.skinImage("RTS_HUD_ResourceStrip", hud + "hud_resource_bar.vfImage");
        this.skinImage("RTS_HUD_MinimapPanel", hud + "hud_minimap_frame.vfImage");
        this.skinImage("RTS_HUD_BottomAccent", hud + "hud_separator.vfImage");
    }

    // Resolve an entity by name and point its UIImage at a texture with a white
    // tint (so the texture renders at full brightness).
    private function skinImage(string name, string path): void {
        int id = Entity::findByName(name);
        if (id >= 0) {
            UI::setImageTexture(id, path);
            UI::setImageColor(id, 1.0, 1.0, 1.0, 1.0);
        }
    }

    // Push net power into its HUD label; tint red while in deficit (display
    // only -- low power has no gameplay effect yet).
    private function updatePowerLabel(): void {
        if (this.powerLabelId < 0) {
            return;
        }
        UI::setLabelText(this.powerLabelId, "Power: " + parsePrimitive(this.state.power));
        bool negative = this.state.power < 0;
        if (negative != this.lastPowerNegative) {
            if (negative) {
                UI::setLabelColor(this.powerLabelId, 1.0, 0.35, 0.3, 1.0);
            } else {
                UI::setLabelColor(this.powerLabelId, 0.88, 0.86, 0.76, 1.0);
            }
            this.lastPowerNegative = negative;
        }
    }

    private function seedWidgets(): void {
        if (this.goldLabelId >= 0) {
            UI::setLabelText(this.goldLabelId, "Gold: " + parsePrimitive(this.state.gold));
        }
        this.updatePowerLabel();
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
                    // Word labels (Train/Rally/Cancel) overflow at the authored
                    // letter size, so shrink them and left-align while shown
                    // (VK-1352).
                    UI::setLabelFontSize(bid, WORD_CMD_FONT_SIZE);
                    UI::setLabelAlignment(bid, UI::LABEL_ALIGN_LEFT, UI::LABEL_VALIGN_MIDDLE);
                    UI::setLabelSpacing(bid, 1.0, WORD_CMD_LETTER_SPACING);
                } else {
                    Entity::setActive(bid, false);
                }
            }
        }
    }

    // Hide the command card while nothing is selected. The VK-1311 Build flow
    // stays reachable through the build-queue slots (RTS_HUD_BuildSlot_0..3).
    private function hideCommandCard(): void {
        for (int i = 0; i < 5; i = i + 1) {
            int bid = this.cmdButtons[i];
            if (bid >= 0) {
                Entity::setActive(bid, false);
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
