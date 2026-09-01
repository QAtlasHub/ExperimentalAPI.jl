# Reading a module's marks back out. Everything here is read-only and allocation-cheap: these
# are the functions a release script, a docs build or a test calls, and none of them should be
# able to create a registry as a side effect of asking a question.

"""
    experimental(m::Module) -> Vector{Mark}

Every name in `m` declared [`@experimental`](@ref), sorted by name.

This is the query the marker exists to make possible — a tool asks the module, rather than a
human reading docstrings. A module with no marks answers with an empty vector; it never errors
for not having opted in.

```julia
for mk in experimental(MyPackage)
    println(mk.name, " — ", mk.reason)
end
```

The result is a fresh vector; mutating it does not change the module. Note that a mark does not
imply the name is public — see [`audit`](@ref)'s `dangling`.
"""
function experimental(m::Module)
    isdefined(m, MARKS_BINDING) || return Mark[]
    return sort(copy(_registry_of(m)); by=x -> x.name)
end

"""
    mark(m::Module, name::Symbol) -> Union{Mark,Nothing}

The [`Mark`](@ref) on `name` in `m`, or `nothing` if it carries none.

This is how the reason gets to whoever needs it — an error message, a docs page, a release
checklist:

```julia
mk = mark(MyPackage, :render_report)
mk === nothing || @warn "not settled" mk.reason mk.tracking
```
"""
function mark(m::Module, name::Symbol)
    isdefined(m, MARKS_BINDING) || return nothing
    reg = _registry_of(m)
    i = findfirst(x -> x.name === name, reg)
    return i === nothing ? nothing : reg[i]
end

"""
    isexperimental(m::Module, name::Symbol) -> Bool

Whether `name` in `m` is declared [`@experimental`](@ref).

The one-bit form of [`mark`](@ref), for a caller that only needs the verdict — for instance the
mechanical statement that changing this name is not breaking. Does not consult docstrings and
does not consult visibility: it answers only whether a mark exists.
"""
isexperimental(m::Module, name::Symbol) = mark(m, name) !== nothing
