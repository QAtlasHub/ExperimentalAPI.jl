# The case matrix

These files are the specification. They are written before the implementation, so most of them
are `@test_broken`.

`@test_broken` was chosen deliberately over comments or a TODO list:

  * an expression that throws (because the function does not exist yet) registers as **Broken**,
    not as an error, so the suite stays green while the spec is incomplete;
  * an expression that starts **passing** registers as `Error: Unexpected Pass`, which fails the
    suite until someone promotes it to `@test`.

So the spec cannot silently rot in either direction: it neither blocks work that has not been
done, nor lets finished work go unnoticed.

One caveat, measured rather than assumed: an expression whose value is not a `Bool` — an
`@eval module … end`, whose value is a `Module` — reports `Error: Expression evaluated to
non-Boolean` instead of `Unexpected Pass`. Both fail the suite loudly, so nothing rots either
way, but every `@eval module` block in this directory now ends in a `Bool` and checks *what* got
marked, so the message is the expected one and the assertion has content beyond "it parsed".

## Overlap with `test/test_*.jl`

`test_spec_declare.jl` re-covers definition forms that `test/test_mark.jl` already pins, and
`test_spec_docstring.jl` re-covers part of `test/test_audit.jl`'s bucket contract, through
separate fixtures. That is deliberate while the spec is the design document — but two fixtures
pinning one contract have to be kept in sync by hand, so the older files should be folded in or
retired once the spec stops moving.

Anything already implemented is a plain `@test`.

## What is covered

The measure is **distinct behaviours** — one per leaf `@testset` — not assertions. An assertion
count moves without any implementation progress: `test_spec_declare.jl` has 36 assertion lines
but 91 runtime assertions, because several run inside `for mk in experimental(Declared)`, so a
thirteenth fixture mark would buy four more passing assertions and cover nothing new. A leaf
testset is one claim, and adding one means writing one.

*operating today* is the column that matters when reading a claim about this directory: a leaf
that is entirely `@test_broken` is a claim written down, not a check being run.

<!-- BEGIN GENERATED: julia --project=test test/spec/summary.jl -->
| file | behaviours | operating today | specified only | concern |
|---|---|---|---|---|
| `test_spec_declare.jl` | 11 | 7 | 4 | what can carry a mark: function, method, struct, const, module, macro, extension |
| `test_spec_dispatch.jl` | 14 | 4 | 10 | one call site, several methods, only some marked — the branch |
| `test_spec_docstring.jl` | 9 | 6 | 3 | a mark and a docstring are different accounts and must coexist |
| `test_spec_foreign.jl` | 14 | 5 | 9 | marking a method on somebody else's generic — the `QAtlas.fetch` case |
| `test_spec_forms.jl` | 26 | 15 | 11 | the definition forms a real package hits on its second afternoon |
| `test_spec_integration.jl` | 17 | 1 | 16 | where the mark has to surface: docs, Aqua, releases, provenance, CI |
| `test_spec_lifecycle.jl` | 15 | 7 | 8 | the mark's EXIT, and an entry point that is a module rather than a function |
| `test_spec_profile.jl` | 40 | 12 | 28 | what a real run went through, how often, and how much of it |
| `test_spec_propagate.jl` | 20 | 2 | 18 | a caller that never names a marked thing still depends on it |
| `test_spec_verify.jl` | 8 | 2 | 6 | how well is a marked thing exercised by the tests |
| **10 files** | **174** | **61** | **113** | |
<!-- END GENERATED -->

The table is generated and pinned by `test/test_spec_table.jl`, which fails if it goes stale —
the hand-written version drifted inside the change that introduced it.

## Two layers, and why the split is where it is

The goal is a tool that says **where** experimental code was used, and a user who learns they
used it **without opting in**. Those are different jobs with different budgets, and the boundary
between them was measured rather than chosen. 10M calls of a realistic numeric body, Julia
1.12.2, minimum of 7–9 trials:

| emitted into the body | 1 thread | 8 threads | counts correctly? |
|---|---|---|---|
| nothing | 1.00× | 1.00× | — |
| set-once flag, read-mostly | 1.03× | **0.985×** | yes |
| counter, plain shared `Ref` | 1.03× | 3.76× | **no** |
| counter, global atomic | 1.17× | 4.87× | yes |
| counter, per-thread atomic | 1.12× | 2.79× | yes |
| `@warn`, guarded so it fires once | 5.65× | — | yes |
| `@warn maxlog=1` | 59.57× | — | yes |

Two results decided it. The plain counter is not merely slow in parallel — it recorded
95,406,048 of 160,000,000 calls, **losing 40% to races**, so it is wrong as well as expensive.
And a flag written once and only read afterwards never dirties the cache line again, which is
why it is free at eight threads while every counting scheme is not.

So **presence is detected by default and costs nothing; counts, call sites and paths are
opt-in.** The `@warn` rows are why the default notice is a summary at process exit rather than a
warning at first entry: the cost is the logging call sitting in the body, not the warning being
printed, and guarding it so that it fires once does not recover it.

### One requirement was withdrawn

This directory used to require that `@experimental` **never wrap the call**, and
`test_spec_profile.jl` pinned it structurally. That is gone: presence cannot be detected without
emitting something into the body. What replaced it is narrower and measured — the emitted
statement must be read-mostly, must add exactly one statement, and must not bring the logging
machinery with it. The last of those is checked today, with a macro that *does* log as the
positive control.

## Negative controls

Each group has a negative control **specified**; most are not yet operating, because the control
is `@test_broken` alongside the claim it controls. They are listed here as design, not as
evidence:

| group | the control | operating? |
|---|---|---|
| propagate   | `top_good` is *exactly as deep* as `top_bad` and must come back `:clean` | no |
| profile     | `cold` is marked and never called, and must be **absent**, not reported with count zero | no |
| verify      | the fixture is exercised only *partly*, so a checker that always reports 100% cannot pass | no |
| integration | a settled name must get **no** docs note | no |
| dispatch    | `which()` really does throw for the branching signatures the file rests on | **yes** |
| forms       | the misuse refusals name the missing half, rather than one generic message | **yes** |
| lifecycle   | deleting a settled name is still breaking, so `isbreaking` cannot answer `false` always | **yes** |

"no" means the assertion about the *implementation* does not run, because the implementation is
not there. It does not mean the row is unchecked: the fixture premise each control rests on is
pinned live where it could be got wrong — `test_spec_verify.jl:38` asserts the fixture really is
only partly exercised, and `test_spec_dispatch.jl:93` asserts the specificity relation the whole
file assumes. A control resting on a false premise is the failure mode those guard.

The one that matters most is not in the table because it is a rule rather than a fixture:
`:unknown` must never be reported as `:clean`. Two fixtures (`Holder.f::Function`, `TABLE[i](x)`)
really can reach the marked function while being statically invisible. Answering "no experimental
dependency" there is not a weaker claim, it is a false one.

## What the spec already found

Two defects, both live in the shipped code, both of the kind the spec was written to catch —
a mark that silently records the wrong thing rather than refusing:

1. `@experimental "…" (c::C)(x) = c.k * x` marks **`:c`**, the argument name. Not the type, not
   a function — a local that is not a binding anywhere. It produces **two** wrong signals, not
   one: the audit reports `:c` as *dangling* (declared, no such binding) **and** `:C` as
   *unaccounted* (public, never declared), so it tells the author to go declare the very thing
   that line declares. Both halves have to move together; `test_spec_forms.jl` pins each.
2. A mark inside a function body is refused by *Julia*, not by this package:
   `syntax: unsupported const declaration on local variable`. Half fixed — the expansion now
   carries the caller's `LineNumberNode`, so the message names the line the author wrote instead
   of `ExperimentalAPI/src/mark.jl`, which read as a bug in the package. The message still never
   says `@experimental`, and may not be able to: `const` in local scope fails during lowering,
   before any emitted code runs, and the one alternative that avoids `const` (`global`) fails
   *silently* in local scope, which is worse.
