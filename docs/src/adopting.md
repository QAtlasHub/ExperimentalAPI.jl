```@meta
CurrentModule = ExperimentalAPI
```

# Adopting it

The interesting case is not a new package. It is a package that already has thirty public names
and no idea which of them anybody meant.

## Start by looking

```julia
julia> using MyPackage, ExperimentalAPI

julia> audit(MyPackage)
```

Two numbers matter. `undocumented` is the backlog. `dangling` should be zero on day one, because
there are no marks yet.

## Turn the test on with the backlog listed

```julia
ExperimentalAPI.test_surface(MyPackage; skip = [:legacy_one, :legacy_two, :legacy_three])
```

Green from the first commit, and the list is the honest statement of what is not covered — in the
test file, where the next person to touch the package will see it.

## The list can only shrink

**A stale `skip` entry fails the test.** An entry that has since been documented, declared, or
deleted is reported by name:

```
public surface of MyPackage: Test Failed
  skip entry legacy_two is still needed
```

This is the part that makes an allowlist worth having. Without it, the usual outcome is a list
that silently stops describing anything: names get documented, names get deleted, and a green
suite comes to mean less every release while looking exactly the same. Failing on a stale entry
means the only way the list changes is deliberately, and only downwards.

## Then, for each name, one decision

For every name in the list, **write the docstring** — that part is not optional, and it is what
deletes the `skip` entry. Then ask a second question: is the shape settled?

- **settled** → nothing more to do;
- **not settled** → say so, with the reason, *in addition* to the docstring:

```julia
@experimental(
    "reads Test's internal result tree; not dogfooded in CI",
    render_test_report,
    dump_test_report,
    load_test_dump,
)
```

The mark is not a substitute for the prose and never was: the docstring says what the name does,
which is owed either way. What the mark adds is the thing a docstring cannot carry — a machine
can read it, so a run that goes through the name says so, and dropping the name later is not a
breaking change.

## What "declare it" is worth later

Once the marks exist, three things follow that did not before:

- a user of your package can ask it, in code, which parts are not settled;
- your release process can say mechanically that removing one of them is not breaking
  ([Release decisions](@ref));
- the reasons are in one place, so "what still needs deciding here" is a query rather than an
  archaeology exercise.

## A note on where this ends

The goal is not zero experimental names. A package with none is either finished or lying. The
goal is zero **undocumented** names — every public name described, whether or not its shape has
settled.
