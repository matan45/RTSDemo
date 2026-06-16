# mType language rules (for review)

Reference for the mType (`.mt`) language. The authoritative sources are the language docs at
`C:\matan\mType\website\docs\language\*.md` and the error registry at
`C:\matan\mType\mType\diagnostics\ErrorCodeRegistry.hpp`. Use the `MT-Exxxx` codes below to
name what the compiler would actually reject.

## Type system & declarations

- **Primitives (lowercase)**: `int`, `float`, `bool`, `string` — raw values.
- **Wrapper classes (capitalized)**: `Int`, `Float`, `Bool`, `String` — boxed; required as
  generic type arguments. `ArrayList<int>` is wrong → use `ArrayList<Int>` (**MT-E0007**).
- **Explicit typing only — no `var`/inference.** Every local and field is declared with a type:
  `float gridSize = 4.0;`, `HashMap<Int, BuildingInfo?> registry;`.
- **Nullable types** are marked `T?`. A `T?` must be narrowed before use:
  ```
  RTSHUDController? hud = this.hud();
  if (hud == null) { return; }   // or: if (hud != null) { ... }
  int gold = hud.getGold();      // safe only after the guard
  ```
  Safe navigation is `?.`; the result of a `?.` chain is itself nullable.
  Note: `continue` does **not** narrow nullability — use an explicit `if`.
- **Arrays** `T[]` are fixed-size (`new int[5]`); growable sequences use `ArrayList<T>`.

## Classes, interfaces, annotations

- A class: `class Name { fields; constructor(...) { } function method(): RetType { } }`.
  The constructor is always named `constructor` (never the class name).
- **Modifiers**: access `public`/`private`/`protected`; `final` (write-once / non-overridable),
  `abstract` (cannot instantiate — **MT-E4002**), `static` (access via `ClassName::member`).
- **`value class`** — copy/struct semantics: no mutable state, cannot `extends`, should provide a
  default constructor (the codebase relies on a no-arg form for these).
- **Interfaces** are pure contracts (no method bodies, no defaults). An implementing class must
  define **every** method or it fails resolution (missing/abstract method → **MT-E4001**).
- **Annotations**: `@Override` (checked; omitting it on a real override warns **MT-W2002**),
  `@Script` (marks a controller class), `@Throw(exceptions = [...])`. Annotation arguments must be
  compile-time constants — no method calls or `new`.
- **Generics**: `class Box<T>`, bounded as `<T extends Comparable<T>>`. Casts are **invariant**:
  `Container<Dog>` is not a `Container<Animal>` even if `Dog extends Animal` (**MT-E2002**).

## Imports

- Forms: wildcard `import * from "path.mt"`, selective `import { A, B } from "..."`, aliased
  `import { Int as MyInt } from "..."`. (RTSDemo uses wildcard exclusively — see rts-conventions.)
- **No re-exports** — a symbol must be imported directly; transitive imports do not bridge it
  (imported symbol not found → **MT-E7002**).
- **Circular imports are rejected** with a chain trace (**MT-E7001**).

## MT-Exxxx error catalog (review-relevant subset)

| Range | Category | Codes worth citing |
|-------|----------|--------------------|
| **E0xxx** | Parse / syntax | E0001 unexpected token · E0002 missing semicolon · E0003 duplicate declaration · E0004 duplicate method signature (no overloading) · E0006 invalid assignment target · E0007 primitive in generic argument |
| **E1xxx** | Name resolution | E1001 undeclared identifier · E1002 undefined function · E1003 undeclared type · E1004 undefined method · E1005 undeclared field |
| **E2xxx** | Type system | E2001 type mismatch · E2002 conversion failed (incl. invariant generic cast) · E2003 type resolution failed (missing generic args) · E2004 ambiguous overload · E2005 no matching overload · E2007 generic/`await`-context error |
| **E3xxx** | Access / visibility | E3001 access violation (private from outside; also `.` used for a static) · E3002 cannot modify `final` |
| **E4xxx** | Inheritance / classes | E4001 inheritance error (missing abstract impl, extends `final`) · E4002 cannot instantiate abstract class |
| **E5xxx** | Runtime | E5001 null pointer · E5002 array creation/bounds · E5003 uncaught exception · E5006 division by zero |
| **E7xxx** | Imports | E7001 circular dependency · E7002 imported symbol not found |
| **W2xxx** | Warnings | W2001 unused variable · W2002 missing `@Override` |

## Common pitfalls

- Mixing `.` and `::` — static access is `ClassName::method()` / `ClassName::FIELD`; instance is
  `obj.method()`. Wrong accessor → **MT-E2001/E3001**.
- Missing `break` in a `switch` case (falls through). `match (x) { case T v -> {} default -> {} }`
  is the typed alternative and needs no `break`.
- Primitives in generics (use wrapper types — see above).
- Concatenating a number/bool to a string without `parsePrimitive(...)` (type error / silent loss):
  `"Gold: " + parsePrimitive(gold)`, never `"Gold: " + gold`.
- Nested classes/interfaces are rejected at parse time.

## Authoritative references

- Language docs: `C:\matan\mType\website\docs\language\` — `classes.md`, `generics.md`,
  `imports.md`, `interfaces.md`, `annotations.md`, `arrays.md`, `pattern-matching.md`,
  `control-flow.md`, `primitives.md`, `async-await.md`, `lambdas.md`.
- Error registry (source of truth for codes): `C:\matan\mType\mType\diagnostics\ErrorCodeRegistry.hpp`.
- Known limitations: `C:\matan\mType\docs\limitations.md`.
