# Multiplayer Networking (mType)

VertexForge has **no built-in replication/netcode** — there are no `Net::`
engine natives. Multiplayer is built in mType on the **standard-library net
stack** (`lib/net/`): `TcpSocket`, `Http`, `HttpResponse`, `JsonApi`, all
async via `Promise<T>`. You own the authority model, serialization, and
reconciliation. The patterns below are engine-agnostic design adapted to mType +
the entity/script model.

> Reference: the `chat-room` example (`C:\matan\mType\examples\chat-room`) shows
> the async `TcpSocket` client/server pattern these snippets build on.

## Async socket basics

```mtype
import * from "net/TcpSocket.mt";

public async function connect(): Promise<void> {
    TcpSocket socket = new TcpSocket();
    await socket.connectAsync("127.0.0.1", 7777);
    await socket.sendAsync("HELLO");
    string reply = await socket.receiveAsync(1024);
    socket.close();
}
```

Drive networking off coroutines/async, not the render `onUpdate` — `await` yields
to the VM event loop without stalling the frame.

## Server-authoritative model

The server is the single source of truth. Clients send **intent** (inputs), the
server simulates and validates, then broadcasts authoritative state. Never trust
client-reported positions/health.

```mtype
// Per-connected-player state held on the server
public class NetPlayer {
    public int    playerId;
    public Vec3f  position;
    public float  health;
    public int    lastInputSeq;

    public constructor(int id) {
        this.playerId = id;
        this.position = Vec3f::zero();
        this.health = 100.0;
        this.lastInputSeq = 0;
    }

    // Validate before applying — reject teleport/speed hacks
    public function tryMove(Vec3f delta, float deltaTime, float maxSpeed): bool {
        if (delta.length() > maxSpeed * deltaTime * 1.1) { return false; }
        this.position = this.position.add(delta);
        return true;
    }
}
```

## Serialization

Use `JsonApi` for readable/debuggable messages; pack a compact binary protocol
over `TcpSocket` only once the shape is stable. Tag every input with a sequence
number so the server can dedupe/order and the client can reconcile.

```mtype
// intent message: {"seq":N,"mx":..,"mz":..,"fire":bool}
```

## Client-side prediction + reconciliation

1. Client applies its own input **immediately** (prediction) and keeps an input
   history keyed by `seq`.
2. Server replies with the authoritative state and the last-processed `seq`.
3. Client snaps to the authoritative state, then **re-applies** unacknowledged
   inputs (`seq > lastProcessed`) to stay responsive.

```mtype
@Script
public class PredictedMover {
    private ArrayList<InputCmd> pending;   // unacked inputs
    private int selfId;

    public function onStart(): void {
        this.selfId = Entity::self();
        this.pending = new ArrayList<InputCmd>();
    }

    public function applyLocal(InputCmd cmd): void {
        this.pending.add(cmd);
        Entity::setPosition(this.selfId, this.integrate(cmd));   // predict now
    }

    public function reconcile(Vec3f serverPos, int ackSeq): void {
        Entity::setPosition(this.selfId, serverPos);             // snap to truth
        // drop acked, replay the rest
        ArrayList<InputCmd> replay = new ArrayList<InputCmd>();
        for (InputCmd c in this.pending) { if (c.seq > ackSeq) { replay.add(c); } }
        this.pending = replay;
        for (InputCmd c in this.pending) {
            Entity::setPosition(this.selfId, this.integrate(c));
        }
    }

    private function integrate(InputCmd cmd): Vec3f { return Entity::getPosition(this.selfId); }
}
```

## Interpolation for remote entities

Don't snap remote players to each received snapshot — **buffer** snapshots and
render ~100 ms in the past, interpolating between the two bracketing states
(`Vec3f.lerp`). This hides jitter and packet timing variance.

```mtype
Vec3f shown = prev.position.lerp(next.position, t);   // t in [0,1] across the interval
Entity::setPosition(remoteId, shown);
```

## Lag compensation (server-side hit validation)

For hitscan/projectiles, the server rewinds other players to the shooter's
view-time (their snapshot timestamp) before testing the hit, so well-aimed shots
on a laggy client still register.

1. Server keeps a short ring buffer of each player's recent positions+timestamps.
2. On a fire intent, rewind candidates to `now - clientRtt/2 - interpDelay`.
3. Run the hit test (`Physics::raycast` against the rewound positions / a
   server-side check), apply damage, then restore.

## Send-rate / bandwidth

- Tick the network at a fixed rate (e.g. 20–30 Hz), decoupled from render FPS.
- Send **deltas**, not full state; only fields that changed.
- Use **area-of-interest** culling — a client only needs entities near it.
- Batch many small updates into one packet per tick.

## Checklist

- [ ] Server validates every state-changing input (movement speed, fire rate, cooldowns).
- [ ] Inputs carry monotonically increasing `seq`; server reports last-processed.
- [ ] Client predicts locally and reconciles on authoritative updates.
- [ ] Remote entities are interpolated from a snapshot buffer, not snapped.
- [ ] Hit validation is lag-compensated server-side.
- [ ] Network tick rate is fixed and independent of frame rate.
- [ ] Run latency/jitter/packet-loss tests before shipping.
