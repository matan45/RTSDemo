// GameState - Stub data source for the RTS HUD (VK-1324).
//
// Holds placeholder resources, fake unit selection, fake build queue, and
// an alert ticker. Real systems (VK-1302 selection, VK-1309 resources,
// VK-1311 buildings) replace the internals later without changing this API.

class GameState {
    public int gold;
    private float goldAccumulator;
    private float goldPerSecond;

    public string selectedName;
    public float health;
    public float maxHealth;
    public string status;

    public int buildQueueSize;
    public string[] buildQueue;

    public string alert;
    private float alertExpiry;
    private float now;

    private float statusTimer;
    private int statusIndex;

    constructor() {
        this.gold = 100;
        this.goldAccumulator = 0.0;
        this.goldPerSecond = 5.0;

        this.selectedName = "Engineer A";
        this.health = 80.0;
        this.maxHealth = 100.0;
        this.status = "Idle";

        this.buildQueueSize = 3;
        this.buildQueue = new string[4];
        this.buildQueue[0] = "Barracks";
        this.buildQueue[1] = "Tank";
        this.buildQueue[2] = "Tank";
        this.buildQueue[3] = "";

        this.alert = "";
        this.alertExpiry = 0.0;
        this.now = 0.0;

        this.statusTimer = 0.0;
        this.statusIndex = 0;
    }

    public function update(float deltaTime): void {
        this.now = this.now + deltaTime;

        this.goldAccumulator = this.goldAccumulator + this.goldPerSecond * deltaTime;
        while (this.goldAccumulator >= 1.0) {
            this.gold = this.gold + 1;
            this.goldAccumulator = this.goldAccumulator - 1.0;
        }

        this.statusTimer = this.statusTimer + deltaTime;
        if (this.statusTimer >= 3.0) {
            this.statusTimer = 0.0;
            this.statusIndex = (this.statusIndex + 1) % 3;
            if (this.statusIndex == 0) { this.status = "Idle"; }
            if (this.statusIndex == 1) { this.status = "Moving"; }
            if (this.statusIndex == 2) { this.status = "Working"; }
        }

        if (this.alert != "" && this.now >= this.alertExpiry) {
            this.alert = "";
        }
    }

    public function pushAlert(string message, float seconds): void {
        this.alert = message;
        this.alertExpiry = this.now + seconds;
    }

    public function onCommand(string cmd): void {
        this.pushAlert(cmd + " command issued", 2.0);
    }

    public function getBuildSlot(int index): string {
        if (index < 0) { return ""; }
        if (index >= this.buildQueueSize) { return ""; }
        return this.buildQueue[index];
    }

    public function healthFraction(): float {
        if (this.maxHealth <= 0.0) { return 0.0; }
        return this.health / this.maxHealth;
    }
}
