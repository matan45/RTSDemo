// InputEdge - one-button edge detector.
//
// Input exposes button/key STATE (down or not), not edges. Every controller
// previously kept a `prev<Button>Down` bool and derived pressed/released by
// hand. This wraps that bookkeeping: call step(now) exactly once per frame for
// the button, then read wasPressed / wasReleased.
//
// A single step() (rather than separate pressed()/released() that each advance
// the previous state) is deliberate -- some call sites need both edges of the
// same button in one frame (e.g. UnitSelectionController's drag).
//
// Regular (reference) class: instances are held as fields and mutated in place,
// one per tracked button per controller (no shared state, so each controller
// keeps its own independent input timing).

class InputEdge {
    private bool prev;
    public bool wasPressed;
    public bool wasReleased;

    public constructor() {
        this.prev = false;
        this.wasPressed = false;
        this.wasReleased = false;
    }

    public function step(bool now): void {
        this.wasPressed = !this.prev && now;
        this.wasReleased = this.prev && !now;
        this.prev = now;
    }
}
