# The expression-level spelling of the observing layer, built on `record(() -> f(x))`. The macro
# earns its place by knowing two things a closure cannot: the source text of the expression and
# the line it was written on.

@experimental """
the report is a text format with no schema, and it has already changed twice in its first week — \
the hit lines gained a sort order and column alignment, the footer a singular verb. Anything that \
parses this output is parsing a guess
""" @entered

"""
    @entered expr
    @entered io expr

Evaluate `expr`, print which marked definitions it went through, and return its value.

The question [`entered`](@ref) answers about a whole process, asked about one call:

```julia
julia> ExperimentalAPI.@entered sweep(model; βs = 0.05:0.05:2.0)
┌ @entered sweep(model; βs = 0.05:0.05:2.0)   at sweep.jl:42
│   MyPkg.correlator  ×  500 — edge cases at zero separation untested
│   MyPkg.energy      ×10000 — convergence not established below β ≈ 0.1
└ 15 of 17 observable marked definitions were not entered
0.42713…
```

Sorted by name, not by count — `correlator` before `energy` — because a report whose order moves
with the measurement cannot be diffed between two runs.

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

`record(() -> expr; paths = false, timing = false)`, plus the report, returning the record's
`value`. It asks *which* and *how often* — the cheap question, and the one that needs neither a backtrace nor a sampler. Call
[`record`](@ref) directly for call paths, for `inclusive`/`exclusive` time (never both — see the
measurement in its docstring), and for the [`Record`](@ref) as data. This returns the value of
`expr`, not the record.

!!! note "Why the route is not printed"
    A call path is captured as a list of frame names, and Base's higher-order functions are in it.
    Measured on 1.12.2 for `driver(x, n) = sum(inner(x) for _ in 1:n)`, the captured path is

        driver → sum → #sum#278 → sum → #sum#277 → mapreduce → #mapreduce#274 → mapfoldl →
        #mapfoldl#270 → mapfoldl_impl → foldl_impl → _foldl_impl → MappingRF → #driver##0 →
        inner → energy

    — three names the reader wrote and **thirteen** they did not, including keyword-dispatch
    wrappers and a generator closure. Printing that would be worse than printing nothing, and
    separating the two needs `paths` to carry which module each frame came from — a change to what
    [`Hit`](@ref)`.paths` means, not a change to this macro.

!!! note "If `expr` throws"
    The exception propagates and nothing is printed. `record(f; rethrow = false)` is the form
    that hands back what a *failed* run went through, which is usually the run you want it for.

!!! warning "`return` inside `expr` returns from `expr`, not from your function"
    This is the one place the `@time` comparison breaks, and it breaks because `@time` splices the
    expression where you wrote it while this has to run it inside a closure — `record` takes a
    function. So `return` exits the expression and becomes the macro's value:

    ```julia
    f(x) = (ExperimentalAPI.@entered (x > 5 && return :early); :normal)
    f(10)   # :normal — `@time` in the same place would give :early
    ```

    `return @entered …` is unaffected, because there the expression's value *is* what the function
    returns. An assignment has the same shape: `@entered y = f(x)` binds `y` inside the closure,
    so at global scope no `y` appears afterwards. Write `y = @entered f(x)` instead — which is
    what the value coming back is for.

The report goes to `stdout` unless an `io` is named first — `@entered log sweep(model)` puts it in
a file, `@entered devnull f(x)` throws it away and leaves only the value. The default is looked up
when the block runs rather than when the macro expands, so `redirect_stdout` still catches it.

See also [`entered`](@ref) for the whole-process question, [`record`](@ref) for the full
instrument, and [`reach`](@ref) for the same question asked without running anything.
"""
macro entered(ex)
    return _entered_expr(:stdout, ex, __source__)
end

macro entered(io, ex)
    return _entered_expr(esc(io), ex, __source__)
end

# One body for both arities. `io` arrives already escaped when the caller named one, and as the
# bare symbol `stdout` when they did not — resolved in this module at run time, so the destination
# is not frozen at macroexpansion and `redirect_stdout` still reaches it.
function _entered_expr(io, ex, src::LineNumberNode)
    return quote
        local rec = $(record)(() -> $(esc(ex)); paths=false, timing=false)
        $(_report_entered)($io, rec, $(QuoteNode(ex)), $(QuoteNode(src)))
        rec.value
    end
end

# The report. Written here rather than as a `show` method on `Record`, because what it says —
# which call, at which line — is the macro's knowledge and not the record's.
function _report_entered(io::IO, rec::Record, ex, src::LineNumberNode)
    total = length(probes())
    plural = total == 1 ? "" : "s"
    at = src.file === nothing ? "" : "   at $(basename(String(src.file))):$(src.line)"
    println(io, "┌ @entered ", _short_expr(ex), at)
    if isempty(rec)
        # The verb agrees with the SAME count as the noun. Keyed on `total == 0` it read
        # "1 observable marked definition were loaded" for a package with exactly one mark —
        # which is every package on the day it adopts this.
        println(
            io,
            "└ entered nothing marked — ",
            total,
            " observable marked definition",
            plural,
            total == 1 ? " was loaded" : " were loaded",
        )
        return nothing
    end
    labels = [string(h.mod, ".", h.name) for h in rec]
    counts = [string(h.count) for h in rec]
    namewidth = maximum(length, labels)
    countwidth = maximum(length, counts)
    for (h, label, count) in zip(rec, labels, counts)
        println(
            io,
            "│   ",
            rpad(label, namewidth),
            "  ×",
            lpad(count, countwidth),
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
        plural,
        " ",
        rest == 1 ? "was" : "were",
        " not entered",
    )
end

# The expression as the author wrote it, near enough. Line numbers are stripped and a long
# expression is cut, because the header is a label and not a transcript.
function _short_expr(ex)
    s = try
        string(_strip_linenums(deepcopy(ex)))
    catch e
        # Same shape and the same reason as `_summarise`'s: a label is never worth failing over.
        # An interrupt is the caller's, though, and is not this function's to swallow.
        e isa InterruptException && rethrow()
        string(ex)
    end
    s = replace(s, r"\s*\n\s*" => " ")
    return length(s) > 64 ? first(s, 61) * "..." : s
end

# `Base.remove_linenums!` leaves the `LineNumberNode` that is a `:macrocall`'s mandatory second
# argument, so `@entered @somemacro f(x)` printed a raw `#= file:line =#` in the header — and the
# 64-character cut then spent its budget on the file path rather than on the call. `nothing` is
# the placeholder Julia itself accepts in that slot.
function _strip_linenums(ex)
    ex isa Expr || return ex
    Base.remove_linenums!(ex)
    for (i, a) in enumerate(ex.args)
        if ex.head === :macrocall && i == 2 && a isa LineNumberNode
            ex.args[i] = nothing
        else
            ex.args[i] = _strip_linenums(a)
        end
    end
    return ex
end
