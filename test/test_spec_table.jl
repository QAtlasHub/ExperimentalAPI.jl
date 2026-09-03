# The table in `test/spec/README.md` is generated; this is what keeps it that way.
#
# Scope: generating it is only half a fix — a generator nobody runs drifts exactly as fast.

using Test

include("spec/summary.jl")

const _SPEC_README = joinpath(@__DIR__, "spec", "README.md")
const _BEGIN = "<!-- BEGIN GENERATED: julia --project=test test/spec/summary.jl -->"
const _END = "<!-- END GENERATED -->"

# Git checks the README out with CRLF on Windows, so without this the comparison below is
# between line endings.
_lf(s::AbstractString) = replace(s, "\r\n" => "\n")

@testset "the spec table is generated, not typed" begin
    md = _lf(read(_SPEC_README, String))
    @test occursin(_BEGIN, md)
    @test occursin(_END, md)
    block = strip(split(split(md, _BEGIN)[2], _END)[1])
    # "a table is out of date" is not actionable without saying where the table comes from.
    if block != _lf(SpecSummary.table())
        @info "test/spec/README.md is stale — regenerate with `julia --project=test test/spec/summary.jl`"
    end
    @test block == _lf(SpecSummary.table())
end

@testset "no spec file is missing from the table" begin
    # The non-emptiness assertion is not redundant: a `readdir` returning nothing satisfies the
    # set equality vacuously.
    files = SpecSummary.spec_files()
    @test length(files) >= 10
    @test Set(files) == Set(keys(SpecSummary.CONCERNS))
end

@testset "no spec file is missing from runtests.jl" begin
    # `runtests.jl` includes spec files by name, so one can be listed in the table, never run,
    # and still contribute to the published count.
    driver = read(joinpath(@__DIR__, "runtests.jl"), String)
    missing_from_driver = filter(
        f -> !occursin("spec/$f", driver), SpecSummary.spec_files()
    )
    @test isempty(missing_from_driver)
end

@testset "the count is behaviours, and a loop cannot inflate it" begin
    # The property that makes the measure worth publishing: a loop cannot inflate it. Pinned
    # against a synthetic file so that editing a spec file does not change what this asserts.
    path = joinpath(mktempdir(), "test_spec_synthetic.jl")
    write(
        path,
        join(
            [
                "@testset \"outer\" begin",             # not a leaf: contains a testset
                "    for i in 1:100",
                "        @testset \"inner \$i\" begin", # one leaf, whatever the loop bound
                "            @test i == i",
                "        end",
                "    end",
                "end",
                "@testset \"specified only\" begin",    # a leaf with no operating assertion
                "    for k in 1:50",
                "        @test_broken notyet(k)",
                "    end",
                "end",
            ],
            "\n",
        ),
    )
    c = SpecSummary.counts(path)
    @test c.behaviours == 2          # not 3, and not 100
    @test c.operating == 1
    @test c.specified == 1
    @test c.broken_assertions == 1   # one written line, not fifty executions
end
