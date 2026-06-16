# mType Language Reference

mType is the statically-typed, class-based scripting language for the VertexForge
engine. Source files use the `.mt` extension and compile to `.mtc` bytecode
(JIT-enabled by default). Game scripts are authored in mType; the engine exposes
its systems through native static wrapper classes.

> Language source & docs: `C:\matan\mType` (examples in `mType/examples`,
> stdlib mirrored in `mType/tests/testFiles/lib`). Engine wrappers used by games
> live in `VertexForge/assets/scripts/lib/engine`.

## Declarations — always typed (no `var`)

```mtype
int    count   = 0;
float  speed   = 5.0;
bool   active  = true;
string name    = "Player";

int[]    ids   = new int[10];        // fixed-size array
Vec3f[]  path  = new Vec3f[5];

ArrayList<string> names = new ArrayList<string>();
HashMap<string, int> scores = new HashMap<string, int>();
```

There is **no `var`**. Every local, field, parameter, and return is explicitly
typed. This is a hard project convention as well as a language rule.

## Types

**Primitives:** `int` (32-bit), `float` (32-bit), `bool`, `string` (immutable).

**Nullable:** suffix `?` — `string?`, `int?`, `Vec3f?`. Narrow before use:
```mtype
string? maybe = lookup();
if (maybe != null) { print(maybe); }   // safe here
```

**Arrays:** `int[]`, `Vec3f[]`; jagged multi-dim `int[][]`. Fixed size once
allocated (`new int[10]`). Sub-arrays of a jagged array are views — you index
them, you don't reassign whole rows.

**Generics:** `ArrayList<T>`, `HashMap<K,V>`, `Promise<T>`. Invariant —
`ArrayList<Dog>` is not an `ArrayList<Animal>`.

**Value classes:** stack-allocated, pass-by-value (the math types are value
classes):
```mtype
public value class Point {
    public float x;
    public float y;
    public constructor(float x, float y) { this.x = x; this.y = y; }
}
```

**Boxing:** put primitives in object collections via wrappers (`Int`, `Float`,
`Bool`, `String`): `ArrayList<Int> n = new ArrayList<Int>(); n.add(new Int(42));`

## Control flow

```mtype
if (a) { ... } else if (b) { ... } else { ... }
int r = cond ? x : y;                       // ternary

for (int i = 0; i < n; i = i + 1) { ... }   // classic
for (string s in names) { ... }             // for-each (concrete element type!)
while (cond) { ... }

break;     // exit loop
continue;  // next iteration
```

`switch` on `string`/`int` is supported by the language, but the real engine AI
scripts favor `if/else` chains for state dispatch — match the surrounding code.

## Classes, methods, inheritance

```mtype
public class Foo {
    private float value;

    public constructor() { this.value = 0.0; }
    public constructor(float v) { this.value = v; }     // overloads allowed

    public function set(float v): void { this.value = v; }
    public function get(): float { return this.value; }

    public static function make(): Foo { return new Foo(); }
}

abstract class Animal {
    public abstract function sound(): string;
    public function kind(): string { return "animal"; }
}

class Dog extends Animal {
    @Override
    public function sound(): string { return "woof"; }
}

interface Drawable { function draw(): void; }
class Circle implements Drawable {
    public function draw(): void { }
}
```

Modifiers: `public`, `abstract`, `final`, `value`. Methods declare a return type
after `:`. Static methods are called with `::`, instance methods with `.`.

## Async / await (coroutines)

```mtype
import * from "engine/Coroutine.mt";

public async function routine(): Promise<void> {
    await Coroutine::waitForSeconds(2.0);
    await Coroutine::waitForFrames(60);
    await Coroutine::waitForNextFrame();
}
```

## Imports

```mtype
import * from "engine/Entity.mt";
import { Vec3f } from "math/Vec3f.mt";
```

Engine wrappers are imported from the `engine/` and `math/` script roots.

## Annotations

- `@Script` — marks a class as an engine-attachable game script.
- `@Override` — overrides a base/interface method.
- User annotations support `@Retention` / `@Target`.

## High-impact gotchas

- **No `var`** — declare every type explicitly.
- **Number → string:** wrap with `parsePrimitive(...)` before `+`:
  `Log::info("t=" + parsePrimitive(totalTime));`
- **Continue/break do NOT narrow nullables.** `if (x == null) { continue; }`
  leaves `x` still nullable afterward — only `return` narrows. Use `x?.m()` or
  `if (x != null) { ... }` (MYT-381).
- **For-each loses type over `Object`/nested generics** — iterate with the
  concrete element type (`for (string s in list)`), not `for (Object o in ...)`.
- **Generics invariant on cast.**
- **`Stream.sorted()` is a stub** — use `sortedWith(Comparator<T>)`.
- **Static vs instance call sites:** `Entity::self()` (native, `::`) vs
  `pos.normalize()` (object method, `.`).
