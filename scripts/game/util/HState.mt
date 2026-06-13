// HState - harvester state-machine constants (refinery <-> nearest GoldNode).
//
// mType has no enum keyword, so this is a static-final int group (the same
// idiom as RTSFog's fog states). Replaces the bare 0/1/2/3 literals that the
// harvester loop in BuildingCommandController used.

public class HState {
    public static final int TO_MINE = 0; // walking out to the gold node
    public static final int MINING = 1;  // dwelling at the node
    public static final int TO_HOME = 2; // walking back to the refinery
    public static final int DEPOSIT = 3; // depositing gold, then loop

    public constructor() {
    }
}
