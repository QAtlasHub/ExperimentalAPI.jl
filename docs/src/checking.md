# Checking

This is the part the rest of the package exists for.

## The audit

[`audit`](@ref) takes the public surface — `names(m)`, which since Julia 1.11 is exactly
"exported or `public`" — and sorts every name into one bucket:

| bucket | meaning |
|---|---|
| `documented` | has a docstring |
| `declared` | has an [`@experimental`](@ref) mark (may also be documented) |
| `foreign` | public here, but bound in another package — not this module's to account for |
| `unaccounted` | **neither documented nor declared** — the finding |
| `dangling` | marked, but not public — the module contradicting itself |

```julia
julia> audit(Archeion)
Public surface of Archeion — 36 names
  documented      33
  experimental     0
  unaccounted      3   ← neither documented nor @experimental
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

Documenter's `checkdocs = :public` fails a build when a public name has no docstring — but it has
no notion of "declared unfinished instead", so a package that wants that third option needs both:
`checkdocs` for the names that must be documented, `test_surface` for the rule that lets a mark
stand in for a docstring.

If you would rather run only one, run `test_surface`: it accepts everything `checkdocs = :public`
accepts, plus marks.
