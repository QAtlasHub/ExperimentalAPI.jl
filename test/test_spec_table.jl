# The table in `test/spec/README.md` is generated, and this is what keeps it that way.
#
# The first version of that table was written by hand, and it drifted inside the very change that
# argues prose drifts and tests do not: two spec files landed after it was typed, so it said
# "nine files" when there were eleven and every count in it was wrong. Generating it is only half
# a fix — a generator nobody runs drifts exactly as fast. This is the other half.

using Test

include("spec/summary.jl")

const _SPEC_README = joinpath(@__DIR__, "spec", "README.md")
const _BEGIN = "<!-- BEGIN GENERATED: julia --project=test test/spec/summary.jl -->"
const _END = "<!-- END GENERATED -->"

# Git checks the README out with CRLF on Windows, so the comparison below is between line
# endings unless they are normalised — measured, as a red `julia 1.12 — windows-latest`.
_lf(s::AbstractString) = replace(s, "\r\n" => "\n")

@testset "the spec table is generated, not typed" begin
    md = _lf(read(_SPEC_README, String))
    @test occursin(_BEGIN, md)
    @test occursin(_END, md)
    block = strip(split(split(md, _BEGIN)[2], _END)[1])
    # The failure message has to say what to do, because "a table is out of date" is not a
    # defect anybody can act on without being told where the table comes from.
    if block != _lf(SpecSummary.table())
        @info "test/spec/README.md is stale — regenerate with `julia --project=test test/spec/summary.jl`"
    end
    @test block == _lf(SpecSummary.table())
end

@testset "no spec file is missing from the table" begin
    # `spec_files()` reads the directory, and `table()` errors on a file with no entry, so this
    # asserts the directory is non-empty and the generator ran over all of it. Without the first
    # assertion a `readdir` that returned nothing would satisfy the second vacuously.
    files = SpecSummary.spec_files()
    @test length(files) >= 10
    @test Set(files) == Set(keys(SpecSummary.CONCERNS))
end

@testset "no spec file is missing from runtests.jl" begin
    # The other silent-omission surface: a spec file can exist, be listed in the table, and never
    # run, because `runtests.jl` includes them by name. Then it contributes to the published
    # count while asserting nothing.
    driver = read(joinpath(@__DIR__, "runtests.jl"), String)
    missing_from_driver = filter(
        f -> !occursin("spec/$f", driver), SpecSummary.spec_files()
    )
    @test isempty(missing_from_driver)
end

@testset "the count is behaviours, and a loop cannot inflate it" begin
    # The property that makes the published measure worth publishing: `test_spec_declare.jl`
    # runs 91 assertions from 36 assertion lines because several sit inside
    # `for mk in experimental(Declared)`. Adding a fixture mark adds passing assertions and no
    # coverage. A leaf `@testset` is something a person wrote.
    #
    # Pinned against a synthetic file rather than a real one, so that editing a spec file does
    # not silently change what this asserts.
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
