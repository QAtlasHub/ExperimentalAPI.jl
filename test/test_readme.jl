# The README's primary example, executed.
#
# Scope: the first ```julia block only — the rest of the README uses `MyPackage` as illustration.
# An example that does not run is the first thing a reader tries and the first thing that makes
# them close the tab.

using ExperimentalAPI
using Test

function readme_first_block(path=joinpath(@__DIR__, "..", "README.md"))
    # Git checks text files out with CRLF on Windows, so every fence here would miss. Same
    # normalisation as `test_spec_table.jl`, which learned it from a red windows-latest.
    md = replace(read(path, String), "\r\n" => "\n")
    i = findfirst("```julia\n", md)
    i === nothing && error("README.md has no ```julia block")
    rest = md[(last(i) + 1):end]
    j = findfirst("```", rest)
    j === nothing && error("README.md's first ```julia block is unterminated")
    return rest[1:(first(j) - 1)]
end

@testset "the README's first example is a runnable program" begin
    src = readme_first_block()
    # The claim is that it runs as written, so it is evaluated as a whole rather than line by
    # line: `@experimental` emits a `const`, which is legal only at top level.
    @test occursin("@experimental", src)
    m = Module(:READMEExample)
    Core.eval(m, Meta.parseall(src; filename="README.md"))
    @test m.energy(0.5) ≈ 0.5 * 1.0000001
end

@testset "and it produces the output the README shows" begin
    # The README prints two things: the exit summary and `entered()`. Both are quoted verbatim
    # there, so both are checked here — a lede that runs but reports something else is no better.
    src = readme_first_block()
    m = Module(:READMEOutput)
    Core.eval(m, Meta.parseall(src; filename="README.md"))
    es = ExperimentalAPI.entered(m)
    @test [e.name for e in es] == [:energy]
    @test es[1].reason == "convergence not established below β ≈ 0.1"
    @test occursin(
        "this run entered 1 experimental definition", ExperimentalAPI.summary_text(es)
    )
    @test occursin(string(m, ".energy"), ExperimentalAPI.summary_text(es))
end

@testset "a README example that stopped running would fail this" begin
    # Control: the check is not satisfied by any block at all. `Meta.parseall` never throws, so
    # a broken example would otherwise be evaluated as an `:error` node and silently do nothing.
    broken = Module(:READMEControl)
    e = try
        Core.eval(broken, Meta.parseall("energy(0.5) = ("; filename="broken"))
        nothing
    catch err
        err
    end
    @test e !== nothing
end

# ── every julia code block in the docs ───────────────────────────────────────────────────────
#
# Scope: a lint, not an execution. Most blocks reference a `MyPackage` that does not exist, so
# they cannot be run — but the defect that shipped here was not a runtime one. A trailing `\`
# used as a line continuation PARSES (Julia reads it as left-division) and fails only when the
# macro is expanded, so neither a parse check nor a `jldoctest` would have caught it. The check
# has to be for the character.

"Every ```julia fence in `path`, as (line number, text) pairs."
function julia_blocks(path)
    out = Tuple{Int,String}[]
    inblock = false
    start = 0
    buf = String[]
    for (i, line) in enumerate(eachline(path))
        l = rstrip(line, ['\r'])
        if inblock && startswith(strip(l), "```")
            push!(out, (start, join(buf, "\n")))
            inblock = false
            empty!(buf)
        elseif inblock
            push!(buf, l)
        elseif strip(l) in ("```julia", "```jldoctest")
            inblock = true
            start = i
        end
    end
    return out
end

const _DOC_SOURCES = vcat(
    [joinpath(@__DIR__, "..", "README.md")],
    sort(readdir(joinpath(@__DIR__, "..", "docs", "src"); join=true)),
    sort(readdir(joinpath(@__DIR__, "..", "src"); join=true)),
)

@testset "no code block uses a trailing backslash as a line continuation" begin
    # Julia has no line continuation. `@experimental "…" \` + a definition on the next line
    # reaches the macro as `\(reason, def)` and dies with "nothing to mark"; the name-list form
    # dies in `adjoint`. Both shipped, in eleven places, and survived a review round.
    offenders = String[]
    for path in _DOC_SOURCES
        endswith(path, ".md") || endswith(path, ".jl") || continue
        for (start, block) in julia_blocks(path)
            for (k, line) in enumerate(split(block, "\n"))
                endswith(rstrip(line), "\\") &&
                    push!(offenders, "$(basename(path)):$(start + k)")
            end
        end
    end
    @test offenders == String[]
end

@testset "…and the check can see one" begin
    # Control: the scanner only looks inside fences, so it has to be shown to fire on a real one.
    path = joinpath(mktempdir(), "sample.md")
    write(
        path,
        join(
            [
                "prose ending in a backslash \\",   # outside a fence: not a finding
                "```julia",
                "@experimental \"why\" \\",
                "f(x) = x",
                "```",
            ],
            "\n",
        ),
    )
    blocks = julia_blocks(path)
    @test length(blocks) == 1
    lines = split(blocks[1][2], "\n")
    @test count(l -> endswith(rstrip(l), "\\"), lines) == 1
end

# ── the documentation pages ──────────────────────────────────────────────────────────────────
#
# Scope: `docs/src` gets the same treatment the README does. Twenty julia blocks were shipped
# unexecuted, and two of them did not run — including the front page's, which is the defect the
# registry review named for the README and which was fixed there and not here.

const _DOCS = joinpath(@__DIR__, "..", "docs", "src")

"Every fenced julia block under `docs/src`, as (page, index, text). Any fence width."
function docs_blocks()
    out = Tuple{String,Int,String}[]
    for f in sort(readdir(_DOCS; join=true))
        endswith(f, ".md") || continue
        for (i, m) in enumerate(eachmatch(r"`{3,}julia\r?\n(.*?)`{3,}"s, read(f, String)))
            push!(out, (basename(f), i, m.captures[1]))
        end
    end
    return out
end

# A block is illustrative if it stands in for a package the reader supplies, and a transcript if
# it shows a REPL session — `pkg>` as much as `julia>`, which is why the install block is here.
# Names the documentation asks the reader to supply. Adding one is a deliberate act: a block that
# needs a new placeholder fails here first, naming the identifier, rather than being skipped.
const _PLACEHOLDERS = [
    "MyPackage",
    "MyPkg",
    "Archeion",
    "…",
    "simulate",
    "publish",
    "compute",
    "sweep",
    "model",
]

_is_illustrative(b) = any(p -> occursin(p, b), _PLACEHOLDERS)
_is_transcript(b) = occursin("julia>", b) || occursin("pkg>", b)

@testset "every macro the documentation teaches exists" begin
    blocks = docs_blocks()
    @test !isempty(blocks)
    @test "index.md" in [p for (p, _, _) in blocks]
    foreign = Set([
        Symbol("@info"), Symbol("@test"), Symbol("@testset"), Symbol("@deprecate")
    ])
    named = Set{Symbol}()
    for (_, _, b) in blocks, m in eachmatch(r"@[a-zA-Z_][a-zA-Z0-9_]*", b)
        push!(named, Symbol(m.match))
    end
    @test Symbol("@experimental") in named       # non-vacuity, anchored to content
    missing_macros = sort!([
        m for m in collect(named) if m ∉ foreign && !isdefined(ExperimentalAPI, m)
    ])
    @test missing_macros == Symbol[]
end

@testset "every self-contained documentation example runs" begin
    # Not "the page parses": `index.md` parsed perfectly and raised `UndefVarError: Model` on the
    # first line, because the example named a type the reader was supposed to have.
    failures = String[]
    for (page, i, b) in docs_blocks()
        (_is_illustrative(b) || _is_transcript(b)) && continue
        m = Module(Symbol("DocsBlock_", replace(page, "." => "_"), "_", i))
        try
            Core.eval(m, :(using ExperimentalAPI))
            Core.eval(m, Meta.parseall(b; filename=page))
        catch e
            err = e isa LoadError ? e.error : e
            push!(failures, "$page[$i]: " * first(sprint(showerror, err), 60))
        end
    end
    @test failures == String[]
end

@testset "…and something is actually being run" begin
    # Control: the loop above skips illustrative and transcript blocks, so it could quietly skip
    # everything. At least the front page and one `declaring.md` block have to survive the filter.
    runnable = [
        (p, i) for (p, i, b) in docs_blocks() if !_is_illustrative(b) && !_is_transcript(b)
    ]
    @test length(runnable) >= 5
    # The front page's example is absent from that list because it is an `@example` block —
    # Documenter runs it during the docs build, which is the stronger guard. Assert that, so
    # turning it back into an inert ```julia fence is caught here.
    @test occursin("```@example", read(joinpath(_DOCS, "index.md"), String))
end
