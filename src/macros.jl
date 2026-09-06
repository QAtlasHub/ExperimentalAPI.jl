# The expression-level spelling of the observing layer.
#
# `record(() -> f(x))` is the function form and it is what everything here is built on. The macro
# earns its place by knowing two things a closure cannot: the source text of the expression, and
# the line it was written on. A report that says which call went through unvalidated code, and
# where that call is, is a different thing from a list of names.

"""
    @entered expr

Evaluate `expr`, print which marked definitions it went through, and return its value.

The question [`entered`](@ref) answers about a whole process, asked about one call:

```julia
julia> ExperimentalAPI.@entered sweep(model; βs = 0.05:0.05:2.0)
┌ @entered sweep(model; βs = 0.05:0.05:2.0)   at sweep.jl:42
│   MyPkg.energy       ×10000 — convergence not established below β ≈ 0.1
│   MyPkg.correlator   ×  500 — edge cases at zero separation untested
└ 15 of 17 observable marked definitions were not entered
0.42713…
```

The value of `expr` comes back, so this drops into existing code the way `@time` does. The last
line is the one that makes a clean answer mean something:

```julia
julia> ExperimentalAPI.@entered publish(result)
┌ @entered publish(result)   at sweep.jl:57
└ entered nothing marked — 17 observable marked definitions were loaded
```

"Entered nothing" and "nothing is marked anywhere" are different states, and a report that could
not tell them apart would be worth nothing on a package that has no marks yet.

# What it is, exactly

`record(() -> expr; paths = false, timing = false)`, plus the report. It asks *which* and *how
often* — the cheap question, and the one that needs neither a backtrace nor a sampler. Call
[`record`](@ref) directly for call paths, for `inclusive`/`exclusive` time (never both — see the
measurement in its docstring), and for the [`Record`](@ref) as data. This returns the value of
`expr`, not the record.

!!! note "Why the route is not printed"
    A call path is captured as a list of frame names, and Base's higher-order functions are in it:
    `sum(f, xs)` over a generator reports `driver → sum → mapreduce → mapfoldl → mapfoldl_impl →
    foldl_impl → _foldl_impl → MappingRF → inner → energy`. The three names the reader wrote are
    in there, and so are seven they did not. Printing that would be worse than printing nothing,
    and separating the two needs `paths` to carry which module each frame came from — a change to
    what [`Hit`](@ref)`.paths` means, not a change to this macro.

!!! note "If `expr` throws"
    The exception propagates and nothing is printed. `record(f; rethrow = false)` is the form
    that hands back what a *failed* run went through, which is usually the run you want it for.

See also [`entered`](@ref) for the whole-process question, [`record`](@ref) for the full
instrument, and [`reach`](@ref) for the same question asked without running anything.
"""
macro entered(ex)
    src = __source__
    return quote
        local box = Base.RefValue{Any}()
        local rec = $(record)(() -> (box[] = $(esc(ex))); paths=false, timing=false)
        $(_report_entered)(stdout, rec, $(QuoteNode(ex)), $(QuoteNode(src)))
        box[]
    end
end

# The report. Written here rather than as a `show` method on `Record`, because what it says —
# which call, at which line — is the macro's knowledge and not the record's.
function _report_entered(io::IO, rec::Record, ex, src::LineNumberNode)
    total = length(probes())
    where = src.file === nothing ? "" : "   at $(basename(String(src.file))):$(src.line)"
    head = "@entered $(_short_expr(ex))"
    if isempty(rec)
        println(io, "┌ ", head, where)
        n = total
        println(
            io,
            "└ entered nothing marked — ",
            n,
            " observable marked definition",
            n == 1 ? "" : "s",
            n == 0 ? " are loaded" : " were loaded",
        )
        return nothing
    end
    println(io, "┌ ", head, where)
    width = maximum(length(string(h.mod, ".", h.name)) for h in rec)
    counts = maximum(length(string(h.count)) for h in rec)
    for h in rec
        println(
            io,
            "│   ",
            rpad(string(h.mod, ".", h.name), width),
            "  ×",
            lpad(string(h.count), counts),
            " — ",
            h.reason,
        )
    end
    rest = max(0, total - length(rec))
    return println(
        io,
        "└ ",
        rest,
        " of ",
        total,
        " observable marked definition",
        total == 1 ? "" : "s",
        " ",
        rest == 1 ? "was" : "were",
        " not entered",
    )
end

# The expression as the author wrote it, near enough. Line numbers are stripped and a long
# expression is cut, because the header is a label and not a transcript.
function _short_expr(ex)
    s = try
        string(Base.remove_linenums!(deepcopy(ex)))
    catch
        string(ex)
    end
    s = replace(s, r"\s*\n\s*" => " ")
    return length(s) > 64 ? first(s, 61) * "..." : s
end
