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
