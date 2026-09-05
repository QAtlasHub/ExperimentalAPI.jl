```@meta
CurrentModule = ExperimentalAPI
```

# Checking

This is the part the rest of the package exists for.

## The audit

[`audit`](@ref) takes the public surface — `names(m)`, which since Julia 1.11 is exactly
"exported or `public`" — and sorts every name into one bucket:

| bucket | meaning |
|---|---|
| `documented` | has a docstring |
| `declared` | has an [`@experimental`](@ref) mark — an *additional* account, never a substitute |
| `foreign` | public here, but bound in another package — not this module's to account for |
| `undocumented` | **no docstring, marked or not** — the finding [`test_surface`](@ref) asserts empty |
| `unaccounted` | neither account at all — a subset of `undocumented`, and the worst case |
| `dangling` | marked, but not public — the module contradicting itself |

A mark says the shape is unsettled. That is never a reason to say nothing about what the name
does, so a marked name with no prose is a finding exactly as an unmarked one is.

```julia
julia> ExperimentalAPI.audit(Archeion)
Public surface of Archeion — 36 names
  documented      33
  experimental     0
  undocumented     3   ← no docstring
     FTPSTransport, pull_file, push_dir
```

The list is never truncated. A coverage report that elides its tail reads as if the tail were
empty.

## As a test

```julia
using MyPackage, ExperimentalAPI, Test

ExperimentalAPI.test_surface(MyPackage)
```

[`test_surface`](@ref) lives in a package extension, so it appears once `Test` is loaded and
`ExperimentalAPI` never becomes a run-time dependency on `Test` for your users.

It emits one `@testset` per finding, so a failing CI log names the symbol in its header rather
than printing a set difference somebody has to diff by eye:

```
public surface of MyPackage: Test Failed
  pull_file is documented or @experimental
  push_dir is documented or @experimental
```

It also fails on `dangling` marks, and it returns the [`Audit`](@ref) on the normal return path
whether it passed or not — so a caller that wants the numbers does not have to run the check
twice:

```julia
a = ExperimentalAPI.test_surface(MyPackage)
@info "surface" total = length(a.surface) experimental = length(a.declared)
```

`outputlevel = 1` additionally prints the audit. Nothing else depends on it.

## What it cannot see

Stated here rather than in a footnote, because a check whose blind spots go unstated reads as if
it had none:

- **Signatures.** A public name whose arguments, keywords or return type change under it is
  invisible. Marking that name experimental is the *only* way to give notice, and the audit
  cannot tell you that you should have.
- **Prose quality.** A docstring reading `TODO` counts as documented. [`isdocumented`](@ref)
  asks whether prose exists, never whether it is any good.
- **Methods added to another package's function** are not in `names(m)` and never will be —
  which is why the audit has a second half. [`contributed_methods`](@ref) finds them,
  [`unaccounted_methods`](@ref) reports the ones with neither a docstring nor a mark, and
  [`test_surface`](@ref) asserts on them. For a package whose surface *is* such methods —
  `fetch(model, quantity)` with 570 of them — a clean name audit reports nothing while having
  looked at none of them.
- **Names public only inside an extension**, which is a separate module — audit it separately, or
  avoid the blind spot the way this package does: declare the function and its docstring in the
  parent (`function test_surface end` in `src/ExperimentalAPI.jl`) and let the extension add only
  the method. The name is then on the parent's surface and `audit` sees it.
- **Whether a name appears in your guide, README or documentation site.** Docstring presence and
  documentation-page presence are different sets, and this checks only the first. Documenter's
  `checkdocs = :public` and a `@autodocs` block cover part of the second.

## Combining with Documenter

The two checks are complementary and neither subsumes the other:

```julia
makedocs(; modules = [MyPackage], checkdocs = :public)   # every public name has a docstring
```

Documenter's `checkdocs = :public` fails a build when a public name has no docstring, and
[`test_surface`](@ref) requires the same thing — the two agree, and running both is not a
contradiction. What `test_surface` adds is `foreign` (a re-exported name whose prose is somebody
else's job) and `dangling` (a mark on a name that was never made public), neither of which
Documenter has a notion of.

Run both. Neither is a looser version of the other, and
[`aqua_compatible_names`](@ref) computes the difference between them so a project running both can
see exactly which names it would have to argue about. Empty means the two agree.

## The method-level half

```julia
julia> ExperimentalAPI.audit(Downstream).contributed_methods
4-element Vector{Method}:
 fetch_value(::Ising, ::Energy) …
 ⋮

julia> ExperimentalAPI.unaccounted_methods(Downstream)      # neither a docstring nor a mark
2-element Vector{Method}:
 ⋮
```

Docstrings are keyed by signature, so [`isdocumented`](@ref)`(::Method)` is a real question and
not the same one as [`isdocumented`](@ref)`(m, :name)`. Only the module that *wrote* the method is
asked: the generic's own docstring upstream has the key `Tuple{Any, Any}`, and letting it count
would make one docstring account for all 570 methods anybody ever contributed.

[`test_surface`](@ref) asserts on these with `require_methods = :foreign` by default — methods on
another *package's* generic, not on Base's. `Base.show(io, ::Audit)` implements a protocol whose
documentation is Base's, and a default that reported every `show`, `==` and `getindex` method as a
finding is a default that gets switched off wholesale. [`extends_base`](@ref) is the rule, stated
as "who owns the generic" rather than as a list of interface functions — a list is not closed
under the ones Julia adds next. `require_methods = :all` widens it.

## How well is any of it exercised?

The mark records where it was written, and `--code-coverage` records a count per line. Joining the
two answers the worst case a marked definition can be in:

```julia
julia> ExperimentalAPI.unverified(MyPackage)          # marked AND never executed by the suite
1-element Vector{ExperimentalAPI.Mark}:
 ExperimentalAPI.Mark(MyPackage.never_called, "shipped without ever being called")

julia> ExperimentalAPI.coverage(MyPackage, :half_exercised)
0.6
```

[`coverage`](@ref) answers `missing`, never `0.0`, when the run has no coverage data: a run
without `--code-coverage` has nothing to say, and reporting zero would flag every marked
definition in every ordinary run. The counters are flushed from the running process rather than
read from the files Julia writes at exit, because a test that has to wait for the process to end
cannot assert anything.

[`stale_marks`](@ref) is the check that keeps the join honest: an edit above a definition moves
the code and not the record, and every downstream reader of `mk.line` then describes the wrong
lines silently.
