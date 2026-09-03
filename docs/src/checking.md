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
julia> audit(Archeion)
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
- **Methods added to another package's function.** They are not in `names(m)` and never will be.
- **Names public only inside an extension**, which is a separate module — audit it separately.
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

Run both. Neither is a looser version of the other.
