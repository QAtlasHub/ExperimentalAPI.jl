# The case matrix

These files are the specification. They were written before the implementation, so most of them
started as `@test_broken`; the implementation caught up and every one of them is a live assertion
now. What the register was for has not gone away — it inverted:

  * an expression that throws (because the function does not exist yet) registers as **Broken**,
    not as an error, so the suite stays green while a spec is incomplete;
  * an expression that starts **passing** registers as `Error: Unexpected Pass`, which fails the
    suite until someone promotes it to `@test`.

So the spec cannot silently rot in either direction: it neither blocks work that has not been
done, nor lets finished work go unnoticed. With the count now at zero, the same mechanism is a
**ratchet** — a behaviour demoted back to `@test_broken` moves the number `test/test_spec_table.jl`
pins, and the suite says so.

One caveat, measured rather than assumed: an expression whose value is not a `Bool` — an
`@eval module … end`, whose value is a `Module` — reports `Error: Expression evaluated to
non-Boolean` instead of `Unexpected Pass`. Both fail the suite loudly, so nothing rots either
way, but every `@eval module` block in this directory ends in a `Bool` and checks *what* got
marked, so the message is the expected one and the assertion has content beyond "it parsed".

## Overlap with `test/test_*.jl`

`test_spec_declare.jl` re-covers definition forms that `test/test_mark.jl` already pins, and
`test_spec_docstring.jl` re-covers part of `test/test_audit.jl`'s bucket contract, through
separate fixtures. That was deliberate while the spec was the design document — but two fixtures
pinning one contract have to be kept in sync by hand, so the older files should be folded in or
retired now that the spec has stopped moving.

Anything already implemented is a plain `@test`.

## What is covered

The measure is **distinct behaviours** — one per leaf `@testset` — not assertions. An assertion
count moves without any implementation progress: several run inside `for mk in experimental(…)`,
so a thirteenth fixture mark would buy four more passing assertions and cover nothing new. A leaf
testset is one claim, and adding one means writing one. A `@testset` inside a helper function is
machinery rather than a claim and is not counted — that is what the gate probes in
`test_spec_integration.jl` are.

*operating today* is the column that matters when reading a claim about this directory: a leaf
that is entirely `@test_broken` is a claim written down, not a check being run.

<!-- BEGIN GENERATED: julia --project=test test/spec/summary.jl -->
| file | behaviours | operating today | specified only | concern |
|---|---|---|---|---|
| `test_spec_declare.jl` | 12 | 12 | 0 | what can carry a mark: function, method, struct, const, module, macro, extension |
| `test_spec_dispatch.jl` | 15 | 15 | 0 | one call site, several methods, only some marked — the branch |
| `test_spec_docstring.jl` | 9 | 9 | 0 | a mark and a docstring are different accounts and must coexist |
| `test_spec_foreign.jl` | 13 | 13 | 0 | marking a method on somebody else's generic — the `QAtlas.fetch` case |
| `test_spec_forms.jl` | 24 | 24 | 0 | the definition forms a real package hits on its second afternoon |
| `test_spec_integration.jl` | 18 | 18 | 0 | where the mark has to surface: docs, Aqua, releases, provenance, CI |
| `test_spec_lifecycle.jl` | 15 | 15 | 0 | the mark's EXIT, and an entry point that is a module rather than a function |
| `test_spec_profile.jl` | 41 | 41 | 0 | what a real run went through, how often, and how much of it |
| `test_spec_propagate.jl` | 20 | 20 | 0 | a caller that never names a marked thing still depends on it |
| `test_spec_verify.jl` | 9 | 9 | 0 | how well is a marked thing exercised by the tests |
| **10 files** | **176** | **176** | **0** | |
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

### How `record` counts without a counter in the body

The emitted statement never changed. `record` opens a block by clearing every probe's flag, so
the short-circuit fails and the *write* side runs on every call — and the write side is a
function call, not an inlined store, so it can do the counting. Nothing in a marked body is
different inside a recording; what differs is which branch of the same one statement is taken.

Two consequences worth having written down. Counts are **exact** and survive inlining, which is
what ruled the sampling route out — a marked definition small enough to be worth marking is small
enough to be inlined, and a sampler has no frame left to attribute to. And the probe statement
carries the declaration's own `LineNumberNode`, which is load bearing rather than cosmetic: the
write side is a cold branch that the optimiser is free to sink, and without a location of its own
it inherits whichever statement happens to be next — so `record`'s call paths came back reporting
`iterate` and `+` where `energy` and `inner` belonged.

### One requirement was withdrawn

This directory used to require that `@experimental` **never wrap the call**, and
`test_spec_profile.jl` pinned it structurally. That is gone: presence cannot be detected without
emitting something into the body. What replaced it is narrower and measured — the emitted
statement must be read-mostly, must add exactly one statement, and must not bring the logging
machinery with it. The last of those is checked today, with a macro that *does* log as the
positive control.

### A second requirement was withdrawn, and this one could not be met

`test_spec_forms.jl` required that a mark written inside a function body be refused with a message
naming `@experimental`. It cannot be, and the three routes are exhausted:

  * `const` in local scope fails during **lowering**, before any emitted code runs, so no check of
    ours can intercept it — and Julia's message does not name the variable either. Measured on
    1.12.2: the message is byte-identical for `__EXPERIMENTAL_API_MARKS__` and for a binding whose
    name is the whole explanatory sentence, so there is no smuggling the word in.
  * `global`, the one expansion that avoids `const`, fails **silently** in local scope — worse
    than a loud message in the wrong vocabulary.
  * creating the registry through `Core.eval` removes the error altogether, which turns a refusal
    into a mark quietly registered when the enclosing function is first called.

What is kept, and asserted, is the part that was in this package's hands: the blame lands on the
line the author wrote, and never inside this package.

## Negative controls

Each group has a negative control, and all of them now run:

| group | the control |
|---|---|
| propagate   | `top_good` is *exactly as deep* as `top_bad` and comes back `:clean` |
| profile     | `cold` is marked and never called, and is **absent**, not reported with count zero |
| verify      | the fixture is exercised only *partly*, so a checker that always reports 100% cannot pass |
| integration | a settled name gets **no** docs note, and a settled-but-hot function is not attributed |
| dispatch    | `which()` really does throw for the branching signatures the file rests on |
| forms       | the misuse refusals name the missing half, rather than one generic message |
| lifecycle   | deleting a settled name is still breaking, so `isbreaking` cannot answer `false` always |
| foreign     | one dependent's mark does not make the upstream generic experimental for anybody |

The one that matters most is not in the table because it is a rule rather than a fixture:
`:unknown` must never be reported as `:clean`. Two fixtures (`Holder.f::Function`, `TABLE[i](x)`)
really can reach the marked function while being statically invisible. Answering "no experimental
dependency" there is not a weaker claim, it is a false one.

## What the spec found

Defects the spec was written to catch, all of them a mark silently recording the wrong thing
rather than refusing:

1. `@experimental "…" (c::C)(x) = c.k * x` marked **`:c`**, the argument name. Not the type, not
   a function — a local that is not a binding anywhere. It produced **two** wrong signals: the
   audit reported `:c` as *dangling* (declared, no such binding) **and** `:C` as *unaccounted*
   (public, never declared), so it told the author to go and declare the very thing that line
   declares. Both halves move together, and `test_spec_forms.jl` pins each.
2. `since = "0.4.0"` and a non-string reason were refused **by accident** — the field's own
   conversion failed, with a `MethodError` naming neither the keyword nor `@experimental`. A
   refusal the author cannot act on is barely better than none.
3. A name-keyed mark over-claimed: `@experimental "…" energy(::Numerical) = …` made
   `energy(::Exact)` experimental too, so a call site that can only reach the exact method was
   reported as depending on unvalidated code. The mark now records the signature it attached to,
   and `stable` keeps a name in the covenant until *every* method behind it is marked.
4. The spec's own `invoke` case named an entry signature no method of the fixture matches
   (`Tuple{Numerical}` against `via_invoke(x::Int)`), and its `@eval`-in-a-loop fixture
   interpolated `$n` at the wrong level. Both were invisible while the assertions were Broken.
