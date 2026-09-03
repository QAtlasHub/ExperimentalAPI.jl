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
