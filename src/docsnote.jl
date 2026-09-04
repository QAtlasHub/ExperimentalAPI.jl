# Getting the mark to the reader of the rendered documentation, without the author typing it
# twice. Typed twice the two drift, and the machine-readable one loses.

"""
    docstring_note(m::Module, name::Symbol) -> Union{String,Nothing}
    docstring_note(mk::Mark) -> String

The admonition a docs build should render above `name`'s docstring, or `nothing` if the name is
settled.

Markdown, in Documenter's `!!! warning` form, carrying the reason, the version it has been
unsettled since, and the tracking link — the three things a reader needs and the author has
already written once:

```julia
julia> println(docstring_note(MyPkg, :provisional))
!!! warning "Experimental"
    the r,s branch has no reference value

    Unsettled since v0.2.0. Tracking: <https://example.invalid/issues/9>.
```

`nothing` for a settled name is the point: a renderer that annotates everything says nothing.
The Documenter extension turns this into an `@experimental` block; nothing stops a project
splicing it in itself.
"""
function docstring_note(mk::Mark)
    io = IOBuffer()
    println(io, "!!! warning \"Experimental\"")
    println(io, "    ", mk.reason)
    tail = String[]
    mk.since === nothing || push!(tail, "Unsettled since v$(mk.since).")
    mk.tracking === nothing || push!(tail, "Tracking: <$(mk.tracking)>.")
    mk.sig === nothing || push!(tail, "Applies to `$(_signature_key(mk))`.")
    if !isempty(tail)
        println(io)
        println(io, "    ", join(tail, " "))
    end
    return String(take!(io))
end

function docstring_note(m::Module, name::Symbol)
    mk = mark(m, name)
    return mk === nothing ? nothing : docstring_note(mk)
end

"""
    marks_markdown(m::Module) -> String

Every mark in `m` as one markdown block, for a docs page that wants the list in one place.

Sorted by name, with the reason, the version and the tracking link. A module with no marks renders
a sentence saying so rather than nothing, because "this page is empty" and "this build failed to
find anything" look identical otherwise.

Deliberately **heading-free**. A docs builder registers heading anchors in an earlier pass than
the one that expands a block like this, so a heading spliced in here arrives after the pass that
was supposed to see it — Documenter's HTML writer asserts on exactly that.
"""
function marks_markdown(m::Module)
    ms = experimental(m)
    isempty(ms) && return "`$(nameof(m))` declares no experimental names.\n"
    io = IOBuffer()
    for mk in ms
        println(io, "**`", mk.name, "`** — ", mk.reason)
        println(io)
        bits = String[]
        mk.since === nothing || push!(bits, "since v$(mk.since)")
        mk.tracking === nothing || push!(bits, "tracking: <$(mk.tracking)>")
        if mk.sig === nothing
            push!(bits, "covers every method of the name")
        else
            push!(bits, "signature: `$(_signature_key(mk))`")
        end
        if mk.until === nothing
            push!(bits, "**no exit condition recorded**")
        else
            push!(
            bits,
            ready_to_promote(mk) ? "**exit condition met**" : "exit condition not yet met",
        )
        end
        println(io, "*", join(bits, " · "), "*")
        println(io)
    end
    return String(take!(io))
end
