// QueueItem - one entry in a building's unit production queue.
//
// Replaces the four parallel arrays (queueBuilding / queueType / queueRemaining
// / queueTotal) BuildingCommandController used for the FIFO production queue. A
// regular (reference) class so the head's remaining time can be decremented in
// place, and a pop is a single-array reference shift instead of four in lockstep.

class QueueItem {
    public int buildingId;
    public string unitType;
    public float remaining; // seconds left until the unit spawns
    public float total;     // original build time (for the progress bar)

    constructor(int buildingId, string unitType, float total) {
        this.buildingId = buildingId;
        this.unitType = unitType;
        this.remaining = total;
        this.total = total;
    }

    constructor() {
        this.buildingId = -1;
        this.unitType = "";
        this.remaining = 0.0;
        this.total = 0.0;
    }
}
