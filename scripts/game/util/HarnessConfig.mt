// HarnessConfig - the automated-match switches, read from the project's config.json
// (VK-1298 slice 2).
//
// The engine's persistent key/value store is exposed to scripts through
// lib/engine/Config.mt, whose class is named `Config` -- and so is this game's own
// util/Config.mt. The editor compiles every script of the project into ONE bundle
// (ProjectBuilder emits `import *` for every source file), so both classes would
// land in the same namespace and the build would reject the duplicate. Importing the
// engine wrapper anywhere in game/ is therefore off the table. Calling the engine
// natives directly -- exactly what the wrapper itself does -- needs no import and
// no engine change.
//
// Keys (written by tools/run_automatch.ps1 into <project>/config.json):
//   autoMatch            bool    master switch; false/missing = AutomatedMatchController is inert
//   autoMatchScenario    string  "assault" (default) | "defend" | "soak"
//   autoMatchTimeoutSec  float   whole-run budget before the harness gives up (default 300)
//
// The engine resolves config.json next to the open .vfproj (ConfigService). Editor
// Play and Runtime.exe read the same file, so the harness can be driven in either.

public class HarnessConfig {
    public constructor() {
    }

    public static function autoMatchEnabled(): bool {
        return _native_config_getBool("autoMatch", false);
    }

    public static function scenario(): string {
        return _native_config_getString("autoMatchScenario", "assault");
    }

    public static function timeoutSec(): float {
        return _native_config_getFloat("autoMatchTimeoutSec", 300.0);
    }
}
