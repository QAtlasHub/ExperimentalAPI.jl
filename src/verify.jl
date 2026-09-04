# How well a marked definition is exercised by the tests.
#
# No new machinery: the mark already carries the file and line its definition starts at, and
# `--code-coverage` already writes a count per line. Joining the two answers the worst case a
# marked definition can be in — unvalidated code that its own suite never runs — and it answers it
# without anyone writing another list.
#
# Coverage counts are flushed from the running process rather than read from the `.cov` files
# Julia writes at exit, because a test that has to wait for the process to end cannot assert
# anything.

"""
    Verification

How much of one marked definition the current run exercised.

| field | |
|---|---|
| `mark` | the declaration |
| `covered`, `total` | executable lines run, and executable lines in the definition |
| `fraction` | `covered / total`, `0.0` for a definition that was never compiled, or `missing` |

`missing` is not zero. A run without `--code-coverage` has nothing to say about coverage, and
reporting `0.0` there would flag every marked definition in every ordinary run.

`total == 0` with `fraction == 0.0` is the strongest form of unverified: coverage was on, the mark
attached to a definition with a body, and that definition produced **no counters at all**. Julia
instruments a line when it generates code for it, so a method nothing ever called leaves no trace
in the coverage data — an absence that reads identically to "not executable" unless you also know
there was code there to execute.
"""
struct Verification
    mark::Mark
    covered::Int
    total::Int
    fraction::Union{Float64,Missing}
end

function Base.show(io::IO, v::Verification)
    f = if v.fraction === missing
        "unmeasured"
    else
        string(round(100 * v.fraction; digits=1), "%")
    end
    return print(io, "Verification(", v.mark.mod, ".", v.mark.name, ", ", f, ")")
end

"""
    coverage_enabled() -> Bool

Whether this process was started with `--code-coverage`.

The question [`coverage`](@ref) has to ask before reporting a number: without it there are no
counts at all, and the honest answer is `missing`.
"""
coverage_enabled() = Base.JLOptions().code_coverage != 0

"""
    coverage(m::Module, name::Symbol) -> Union{Float64,Missing}

The fraction of `name`'s definition that this run executed, or `missing` if coverage is off.

Partial coverage comes back partial: a definition whose error branch is never taken is not
verified, and reporting it as `1.0` would be the false pass this whole package exists to remove.
"""
function coverage(m::Module, name::Symbol)
    mk = mark(m, name)
    mk === nothing && return missing
    v = _verify(mk, _coverage_data())
    return v.fraction
end

"""
    verification(m::Module) -> Vector{Verification}

One [`Verification`](@ref) per mark in `m`, sorted by name.

Data, not a printout — the same convention [`audit`](@ref) follows. Flushes the process's coverage
counters once and joins them against every mark, so asking about twenty marks costs what asking
about one does.
"""
function verification(m::Module)
    data = _coverage_data()
    return [_verify(mk, data) for mk in experimental(m)]
end

"""
    unverified(m::Module) -> Vector{Mark}

The marks whose definitions this run never executed at all.

The worst case, and the one worth a separate verb: code that is both unvalidated and untested.
Empty when the run has no coverage data — a run that measured nothing found nothing, and saying
otherwise would report every mark in the package on every ordinary test run.
"""
function unverified(m::Module)
    return [v.mark for v in verification(m) if v.fraction !== missing && v.fraction == 0.0]
end

"""
    stale_marks(m::Module) -> Vector{Mark}

The marks whose recorded line no longer holds a `@experimental` declaration.

A mark records where it was written. An edit above it moves the code and not the record, and every
join keyed on that line — coverage here, and anything downstream reading `mk.file`/`mk.line` —
then describes the wrong lines silently. Re-loading the module fixes it, which is why this reports
rather than repairs: a stale mark means the module on disk and the module in memory differ.
"""
function stale_marks(m::Module)
    out = Mark[]
    for mk in experimental(m)
        lines = _source_lines(String(mk.file))
        lines === nothing && continue
        if mk.line < 1 ||
            mk.line > length(lines) ||
            !occursin("@experimental", lines[mk.line])
            push!(out, mk)
        end
    end
    return out
end

function _verify(mk::Mark, data)
    span = _definition_span(mk)
    (span === nothing || data === nothing) && return Verification(mk, 0, 0, missing)
    counts = get(data, _realpath(String(mk.file)), Dict{Int,Int}())
    covered = 0
    total = 0
    for ln in span[1]:span[2]
        c = get(counts, ln, nothing)
        c === nothing && continue
        total += 1
        c > 0 && (covered += 1)
    end
    total > 0 && return Verification(mk, covered, total, covered / total)
    # No counters anywhere in the span. For a mark that attached to a definition with a body that
    # is a fact, not a gap: the body had lines to instrument and Julia instruments a line when it
    # generates code for it, so their absence says nothing ever called it. A mark on a `struct`, a
    # `const` or a name list has no body, and for those there is genuinely nothing to measure.
    return Verification(mk, 0, 0, mk.sig === nothing ? missing : 0.0)
end

# The line range one declaration occupies: from the `@experimental` line to just before the next
# statement BESIDE it. Read from the source rather than from the method, because a mark may cover
# a `struct` or a name list, which have no method to ask.
#
# "Beside it" is the whole difficulty. The next `LineNumberNode` above the declaration is usually
# the first line of its own body, so a span computed that way is one line long and reports every
# multi-line definition as fully covered by its own signature.
function _definition_span(mk::Mark)
    lines = _source_lines(String(mk.file))
    lines === nothing && return nothing
    tree = _parsed(String(mk.file))
    tree === nothing && return nothing
    return _find_span(tree, mk.line, length(lines))
end

# The statements in one container, each with the line it starts on and the line before its next
# sibling starts. A container's own last statement runs to the container's end.
function _sibling_spans(x, outer_end::Int)
    entries = Tuple{Int,Any}[]
    cur = 0
    for a in x.args
        if a isa LineNumberNode
            cur = a.line
        elseif a !== nothing
            push!(entries, (cur, a))
        end
    end
    out = Tuple{Int,Int,Any}[]
    for (i, (ln, st)) in enumerate(entries)
        stop = i < length(entries) ? max(ln, entries[i + 1][1] - 1) : outer_end
        push!(out, (ln, stop, st))
    end
    return out
end

function _find_span(x, line::Int, outer_end::Int)
    (x isa Expr) || return nothing
    for (a, b, st) in _sibling_spans(x, outer_end)
        a == line && return (a, b)
        (a <= line <= b) || continue
        for body in _containers(st)
            r = _find_span(body, line, b)
            r === nothing || return r
        end
    end
    return nothing
end

# Where a statement can hold further statements of its own: a module's block, a bare block, and
# the body of anything else that carries one.
function _containers(st)
    st isa Expr || return ()
    st.head === :module && return (st.args[3],)
    (st.head === :block || st.head === :toplevel) && return (st,)
    return Tuple(a for a in st.args if a isa Expr && a.head in (:block, :toplevel))
end

const _SOURCE_CACHE = Dict{String,Union{Vector{String},Nothing}}()
const _PARSE_CACHE = Dict{String,Any}()

function _source_lines(path::AbstractString)
    return get!(_SOURCE_CACHE, String(path)) do
        isfile(path) || return nothing
        return readlines(path)
    end
end

function _parsed(path::AbstractString)
    return get!(_PARSE_CACHE, String(path)) do
        isfile(path) || return nothing
        return try
            Meta.parseall(read(path, String); filename=path)
        catch
            nothing
        end
    end
end

_realpath(p::AbstractString) =
    try
        realpath(p)
    catch
        String(p)
    end

"""
    flush_coverage() -> Union{Dict,Nothing}

Write this process's coverage counters out and read them back, or `nothing` if coverage is off.

Julia writes them at exit, which is too late for a test to assert on. The same C entry point the
exit hook uses is called here instead, into a temporary file that is read and removed.
"""
function flush_coverage()
    coverage_enabled() || return nothing
    path = tempname() * ".info"
    try
        ccall(:jl_write_coverage_data, Cvoid, (Cstring,), path)
        isfile(path) || return nothing
        return _parse_lcov(path)
    catch
        return nothing
    finally
        isfile(path) && rm(path; force=true)
    end
end

# Re-flushed on every call rather than cached: a test asks about coverage after running the code
# it wants covered, and a cached answer from before that would report zero.
_coverage_data() = flush_coverage()

function _parse_lcov(path::AbstractString)
    out = Dict{String,Dict{Int,Int}}()
    file = ""
    for line in eachline(path)
        if startswith(line, "SF:")
            file = _realpath(line[4:end])
            get!(out, file, Dict{Int,Int}())
        elseif startswith(line, "DA:")
            parts = split(line[4:end], ',')
            length(parts) == 2 || continue
            ln = tryparse(Int, parts[1])
            n = tryparse(Int, parts[2])
            (ln === nothing || n === nothing) && continue
            out[file][ln] = n
        end
    end
    return out
end
