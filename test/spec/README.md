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

Anything already implemented is a plain `@test`. The ratio of `@test` to `@test_broken` in this
directory is the honest progress measure.

| file | concern |
|---|---|
| `test_spec_declare.jl`     | what can carry a mark: function, method, struct, const, module, macro, extension |
| `test_spec_forms.jl`       | the definition forms a real package hits on its second afternoon |
| `test_spec_foreign.jl`     | marking a method on somebody else's generic — the `QAtlas.fetch` case |
| `test_spec_propagate.jl`   | a caller that never names a marked thing still depends on it |
| `test_spec_docstring.jl`   | a mark and a docstring are different accounts and must coexist |
| `test_spec_verify.jl`      | how well is a marked thing exercised by the tests |
| `test_spec_profile.jl`     | what a real run went through, how often, and how much of it |
| `test_spec_dispatch.jl`    | one call site, several methods, only some marked — the branch |
| `test_spec_lifecycle.jl`   | the mark's EXIT, and an entry point that is a module rather than a function |
| `test_spec_integration.jl` | where the mark has to surface: docs, Aqua, releases, provenance, CI |

## What the spec already found

Two defects, both live in the shipped code, both of the kind the spec was written to catch —
a mark that silently records the wrong thing rather than refusing:

1. `@experimental "…" (c::C)(x) = c.k * x` marks **`:c`**, the argument name. Not the type, not
   a function — a local that is not a binding anywhere, so the mark is silently meaningless.
2. A mark inside a function body is refused by *Julia*, not by this package:
   `syntax: unsupported const declaration on local variable`. The message never mentions
   `@experimental` and points at a line the author did not write.
