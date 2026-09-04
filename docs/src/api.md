```@meta
CurrentModule = ExperimentalAPI
```

# API — declaring

The mark itself, and reading marks back out. The rest of the surface is on
[API — observing and analysing](@ref) and [API — checking and releasing](@ref); the split is by
source file, listed explicitly, so a new file with no page is a build failure rather than a
silently missing section.

```@autodocs
Modules = [ExperimentalAPI]
Pages = ["mark.jl", "query.jl"]
```

## Declared unfinished

Generated from the package's own marks at build time by this package's own Documenter extension,
so it cannot go stale — and it is the same call any consumer would make:

```@experimental
ExperimentalAPI
```

A docstring says what a name does. That block says whether it is finished. Nothing on this page is
undocumented — the names above are documented **and** declared, which is the normal state for
something that works but whose shape is still being argued about.
