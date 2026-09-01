```@meta
CurrentModule = ExperimentalAPI
```

# API

```@autodocs
Modules = [ExperimentalAPI]
```

## Declared unfinished

Generated from the package's own marks at build time, so it cannot go stale — and it is the
same call any consumer would make:

```@example marks
using ExperimentalAPI
# `experimental` is `public`, not exported, so it is qualified — which is the visibility
# convention this package leans on rather than duplicates.
for mk in ExperimentalAPI.experimental(ExperimentalAPI)
    println(mk.name, "\n    ", mk.reason, "\n")
end
```

A docstring says what a name does. This says whether it is finished. Nothing on this page is
undocumented — the names above are documented **and** declared, which is the normal state for
something that works but whose shape is still being argued about.
