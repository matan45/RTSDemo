// DragState - unit box-select drag state-machine constants.
//
// mType has no enum keyword, so this is a static-final int group. Replaces the
// bare 0/1/2 literals UnitSelectionController used for its drag state.

public class DragState {
    public static final int IDLE = 0;     // nothing happening
    public static final int MAYBE = 1;    // button down, under the drag threshold
    public static final int DRAGGING = 2; // box visible

    public constructor() {
    }
}
