// AutoMatchResult - the summary AutomatedMatchController writes to tools/out/last_result.json
// at the end of a harness run (VK-1298 slice 2).
//
// Plain public fields only: Json::writeToFile serializes an instance by reflection,
// so anything that is not a primitive/string would need its own shape. The log
// protocol (ASSERT/STAT/MATCH lines in logs/Runtime.log) is the authoritative record;
// this file is the one-glance digest tools/run_automatch.ps1 picks up.

public class AutoMatchResult {
    public string scenario;
    public string result;       // WIN | LOSE | TIMEOUT | ABORT | SOAK
    public int passes;
    public int fails;
    public float seconds;
    public int deaths;
    public int waves;
    public int heartbeatTicks;

    public constructor() {
        this.scenario = "";
        this.result = "";
        this.passes = 0;
        this.fails = 0;
        this.seconds = 0.0;
        this.deaths = 0;
        this.waves = 0;
        this.heartbeatTicks = 0;
    }
}
