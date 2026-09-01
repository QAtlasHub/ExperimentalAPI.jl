# ExperimentalAPI.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://qatlashub.github.io/ExperimentalAPI.jl/stable/)
[![codecov](https://codecov.io/gh/QAtlasHub/ExperimentalAPI.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/QAtlasHub/ExperimentalAPI.jl)
[![Julia](https://img.shields.io/badge/julia-v1.11+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`public` says who may call a name. Nothing says whether the name is finished.

So "this will change" lives in a docstring sentence, and no tool reads it. ExperimentalAPI puts
that claim at the definition site, in a form a tool can query — and then turns it into a check
your CI runs:

**every public name is either documented or declared unfinished, and there is no third option.**

```julia
using ExperimentalAPI

@experimental "reads Test's internal result tree; not dogfooded in CI yet" \
function render_test_report(records)
    # ...
end
```

```julia
julia> ExperimentalAPI.audit(MyPackage)
Public surface of MyPackage — 46 names
  documented      45
  experimental     1
  unaccounted      0
```

The mark costs nothing at run time: `@experimental` emits your definition unchanged plus one
`push!` at load time. Calls are not wrapped.

## The check is the point

A marker nobody compares against anything is a claim. Put this in `runtests.jl` and it becomes a
contract:

```julia
using MyPackage, ExperimentalAPI, Test

ExperimentalAPI.test_surface(MyPackage)
```

It fails, naming the symbol, when a public name has neither a docstring nor a mark — and also
when a mark points at a name that was never made public, which is the module contradicting
itself.

Adopting it on a package that already has a backlog:

```julia
ExperimentalAPI.test_surface(MyPackage; skip = [:legacy_one, :legacy_two])
```

**A stale `skip` entry fails.** A name that has since been documented, declared, or deleted is
reported, so the list can only shrink.

## Install

```julia
pkg> add ExperimentalAPI
```

It is loaded by the package being marked, so it is a normal dependency — but it pulls in nothing
beyond `TOML`, and `Test` only through a package extension.

```toml
[deps]
ExperimentalAPI = "fd2d14cb-3a46-42a9-afd8-e8499236f05e"
```

## Declaring

Attached to a definition, or as a list of names defined elsewhere:

```julia
# the definition site
@experimental "signature will be wrapped once the write-back refactor settles" \
function ingest(config; doc, kwargs...)
    # ...
end

# names an included file defines
@experimental "reads Test's internal result tree; not dogfooded in CI" \
    render_test_report dump_test_report load_test_dump

# with the issue where the shape is being decided
@experimental("export format is a guess until someone consumes it",
    since = v"0.4.0", tracking = "https://github.com/org/Pkg.jl/issues/12",
    registry_entry(x) = x)
```

A docstring and a mark are not exclusive — a name can be documented *and* declared unfinished,
and the two accounts answer different questions.

## Querying

```julia
experimental(MyPackage)              # Vector{Mark}, sorted — the reason travels with the name
isexperimental(MyPackage, :foo)      # the one-bit form
stable(MyPackage)                    # the complement: what you cannot change quietly
audit(MyPackage)                     # the check, as data
```

## Release decisions

Write the covenant down at each release, and compare the next one against it:

```julia
write_snapshot("api.toml", MyPackage)          # at release time, committed
```

```julia
d = compare(read_snapshot("api.toml"), MyPackage)
isbreaking(d) && error("breaking: $(d.removed_stable) removed, $(d.demoted) demoted")
```

Removing a name you declared experimental lands in `removed_experimental` and is **not**
breaking. That is the whole contract: the mark was the notice, given in the source, at the
definition, before the removal. Demoting a settled name to experimental **is** breaking — a
promise withdrawn is a change to what callers were told.

> **Names, not signatures.** `compare` reads name sets. A name present in both snapshots whose
> arguments changed is a breaking change it cannot see. Read the diff as a floor on breakage,
> never as a clearance.

## What this is not

| axis | already solved by | this package |
|---|---|---|
| who may call a name | `export`, `public` (1.11) | orthogonal — a name can be public and unfinished |
| a name on its way out | `@deprecate` | opposite direction |
| type stability | DispatchDoctor | unrelated |
| generating documentation | Documenter | only ever checks whether prose exists |
| run-time behaviour | — | calls are untouched |

## What the audit cannot see

Stated up front rather than in a footnote, because a check whose blind spots are undocumented
reads as if it had none:

- **Signatures.** A public name whose arguments change under it is invisible.
- **Prose quality.** A docstring reading `TODO` counts as documented.
- **Methods on other packages' functions.** They are not in `names(m)`.
- **Names public only inside an extension**, which is a separate module.
- **Whether a name appears in your guide, README or docs site.** Docstring presence is not
  documentation-page presence, and those two gaps are usually different sets.

## Measured

Run against five packages that had never heard of it, September 2026 — the audit is only worth
having if a clean package comes back clean and a gap comes back named:

| package | public names | documented | foreign | unaccounted |
|---|---|---|---|---|
| Pinax | 46 | 45 | — | `Theme` |
| Archeion | 36 | 33 | — | `FTPSTransport`, `pull_file`, `push_dir` |
| TestShards | 3 | 3 | — | — |
| DataVault | 33 | 32 | `DataKey` | — |
| ParamIO | 13 | 13 | — | — |

`DataKey` is re-exported from a dependency, which is why it is not DataVault's to account for.

None of these had a single mark; the whole column came from docstrings. That is the expected
starting point — the marks are what the four remaining names get *instead of* a docstring, if
their authors decide they are not settled.

## License

MIT
