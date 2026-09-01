```@meta
CurrentModule = ExperimentalAPI
```

# Release decisions

The payoff for marking anything at all: *"changing an experimental name is not breaking"* stops
being an argument in a pull request and becomes a function call.

## Snapshot, then compare

At release time, write down what the package promises and commit it:

```julia
ExperimentalAPI.write_snapshot("api.toml", MyPackage)
```

```toml
module = "MyPackage"
version = "0.4.2"
stable = ["adapt", "measure"]

[experimental.render_report]
reason = "reads Test's internal result tree"
tracking = "https://github.com/org/MyPackage.jl/issues/12"
```

On the next release, compare:

```julia
d = compare(read_snapshot("api.toml"), MyPackage)
isbreaking(d) && error("breaking: $(d.removed_stable) removed, $(d.demoted) demoted")
```

## What counts as breaking

| move | breaking? | |
|---|---|---|
| `removed_stable` | **yes** | a settled name is gone |
| `demoted` | **yes** | a settled name is now called experimental |
| `removed_experimental` | no | this is what marking a name buys |
| `promoted` | no | experimental → settled; the direction all of this is for |
| `added_stable`, `added_experimental` | no | |

Removing a name you had declared experimental lands in `removed_experimental` and does not make
the release breaking. That is the whole contract, and it is worth being precise about *why* it is
legitimate: the notice was given **in the source, at the definition, before the removal**, in a
form a downstream author's own test suite could have read. It is not a retroactive excuse.

`demoted` is the mirror image and is counted as breaking for the same reason. Taking a name you
shipped as settled and calling it experimental afterwards does not un-promise it; it changes what
callers were told after they believed it.

## Names, not signatures

!!! warning
    [`compare`](@ref) reads name sets. A name present in both snapshots whose arguments, keyword
    arguments or return type changed **is** a breaking change, and this cannot see it. Read the
    diff as a floor on breakage, never as a clearance.

This is not a defect to be fixed later by making the snapshot signature-aware — or at least, not
only that. Signature stability is a strictly harder question (a method table is not a set of
names, and "compatible" is not a set operation), and a tool that answered it approximately would
be worse than one that declines: a green light nobody should have trusted.

Which is also why the snapshot layer of this package is itself declared
[`@experimental`](@ref). The file format above is a guess, and making it signature-aware would
change it.
