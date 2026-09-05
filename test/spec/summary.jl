# Generates the coverage table for `test/spec/README.md` and the pull request that ships it.
#
# The measure is DISTINCT BEHAVIOURS — one per leaf `@testset` — not assertions, which move
# without any implementation progress when they sit inside a loop over the fixture's marks.
#
# Run it:  julia --project=test test/spec/summary.jl

module SpecSummary

const SPEC_DIR = @__DIR__

# One line per spec file. A file with no entry here is an error, not a missing row.
const CONCERNS = Dict(
    "test_spec_declare.jl" => "what can carry a mark: function, method, struct, const, module, macro, extension",
    "test_spec_forms.jl" => "the definition forms a real package hits on its second afternoon",
    "test_spec_foreign.jl" => "marking a method on somebody else's generic — the `QAtlas.fetch` case",
    "test_spec_propagate.jl" => "a caller that never names a marked thing still depends on it",
    "test_spec_docstring.jl" => "a mark and a docstring are different accounts and must coexist",
    "test_spec_verify.jl" => "how well is a marked thing exercised by the tests",
    "test_spec_profile.jl" => "what a real run went through, how often, and how much of it",
    "test_spec_dispatch.jl" => "one call site, several methods, only some marked — the branch",
    "test_spec_lifecycle.jl" => "the mark's EXIT, and an entry point that is a module rather than a function",
    "test_spec_integration.jl" => "where the mark has to surface: docs, Aqua, releases, provenance, CI",
)

"""
    spec_files() -> Vector{String}

Every spec file on disk, read from the directory rather than from a list, so a file cannot be
added and left out of the table.
"""
function spec_files()
    return sort(
        filter(f -> startswith(f, "test_spec_") && endswith(f, ".jl"), readdir(SPEC_DIR))
    )
end

function _ismacrocall(x, name::Symbol)
    return x isa Expr && x.head === :macrocall && !isempty(x.args) && x.args[1] === name
end

function _walk(f, x)
    f(x)
    x isa Expr && !_isdefinition(x) && for a in x.args
        _walk(f, a)
    end
    return nothing
end

# A `@testset` written inside a helper function is machinery, not a claim: the gate probes in
# `test_spec_integration.jl` run `test_surface` under a test set that records instead of
# propagating, and counting those as behaviours reported five claims that nobody wrote.
function _isdefinition(x::Expr)
    x.head === :function && return true
    return x.head === :(=) && x.args[1] isa Expr && x.args[1].head in (:call, :where, :(::))
end

_count(pred, x) = (n=0; _walk(y -> (pred(y) && (n += 1)), x); n)

"""
    Counts

What one spec file contains. `operating` and `specified` partition `behaviours`: a leaf testset
either runs at least one assertion against the package today, or it is entirely `@test_broken` —
a claim written down and not yet checked against anything.

The whole directory is `operating` now, and the split earns its place going the other way: it is
the ratchet. A behaviour added as `@test_broken`, or one demoted back to it, moves the number that
`test/test_spec_table.jl` pins, and the suite says so.
"""
struct Counts
    behaviours::Int
    operating::Int
    specified::Int
    broken_assertions::Int
end

function counts(path::AbstractString)
    ex = Meta.parseall(read(path, String); filename=path)
    sets = Expr[]
    _walk(x -> (_ismacrocall(x, Symbol("@testset")) && push!(sets, x)), ex)
    behaviours = operating = 0
    for ts in sets
        body = ts.args[2:end]
        # A leaf has no testset inside it. A loop-generated `@testset "$T"` is one leaf, not one
        # per iteration: a behaviour is something someone wrote.
        sum(b -> _count(y -> _ismacrocall(y, Symbol("@testset")), b), body) == 0 || continue
        behaviours += 1
        live = sum(
            b -> _count(
                y ->
                    _ismacrocall(y, Symbol("@test")) ||
                    _ismacrocall(y, Symbol("@test_throws")),
                b,
            ),
            body,
        )
        live > 0 && (operating += 1)
    end
    broken = _count(y -> _ismacrocall(y, Symbol("@test_broken")), ex)
    return Counts(behaviours, operating, behaviours - operating, broken)
end

const _HEAD = "| file | behaviours | operating today | specified only | concern |"
const _RULE = "|---|---|---|---|---|"

"""
    table() -> String

The markdown table, generated. `test/test_spec_table.jl` pins `README.md` against it, so the two
cannot come apart the way the hand-written one did.
"""
function table()
    rows = String[_HEAD, _RULE]
    tot = Counts(0, 0, 0, 0)
    for f in spec_files()
        haskey(CONCERNS, f) || error(
            "test/spec/$f has no entry in SpecSummary.CONCERNS — add one line describing what " *
            "it covers. Reading the directory rather than a list is what makes this an error " *
            "instead of a silently missing row.",
        )
        c = counts(joinpath(SPEC_DIR, f))
        push!(
            rows,
            "| `$f` | $(c.behaviours) | $(c.operating) | $(c.specified) | $(CONCERNS[f]) |",
        )
        tot = Counts(
            tot.behaviours + c.behaviours,
            tot.operating + c.operating,
            tot.specified + c.specified,
            tot.broken_assertions + c.broken_assertions,
        )
    end
    push!(
        rows,
        "| **$(length(spec_files())) files** | **$(tot.behaviours)** | " *
        "**$(tot.operating)** | **$(tot.specified)** | |",
    )
    return join(rows, "\n")
end

function total()
    return foldl(
        (a, b) -> Counts(
            a.behaviours + b.behaviours,
            a.operating + b.operating,
            a.specified + b.specified,
            a.broken_assertions + b.broken_assertions,
        ),
        (counts(joinpath(SPEC_DIR, f)) for f in spec_files());
        init=Counts(0, 0, 0, 0),
    )
end

end # module SpecSummary

if abspath(PROGRAM_FILE) == @__FILE__
    println(SpecSummary.table())
    t = SpecSummary.total()
    println()
    println(
        "$(t.behaviours) behaviours: $(t.operating) operating today, $(t.specified) " *
        "specified only ($(t.broken_assertions) `@test_broken` assertions).",
    )
end
