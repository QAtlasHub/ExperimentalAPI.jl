# The measurement that could kill the design.
#
# Every other test in this suite marks a module defined in the running session, where any storage
# scheme works. The state a consumer is actually in is different: the marks are written while the
# consumer's package is being PRECOMPILED, in a process that then exits, and the query happens in
# a later process that only ever sees the cache image. A registry living in ExperimentalAPI's own
# state passes every other file here and returns an empty vector in that setting.
#
# So this runs a real package through a real precompile, in a scratch depot, in a subprocess, and
# asks the loaded module what it is carrying. Twice: once compiling from source, once reading the
# cache the first run wrote. Only the second run is evidence.

using Test: @test, @testset

const FIXTURE = joinpath(@__DIR__, "fixtures", "MarkedPkg")

const PROBE = """
using MarkedPkg, ExperimentalAPI
marks = ExperimentalAPI.experimental(MarkedPkg)
println("NAMES=", join(sort(string.(getfield.(marks, :name))), ","))
println("REASON=", ExperimentalAPI.mark(MarkedPkg, :unsettled).reason)
println("SINCE=", ExperimentalAPI.mark(MarkedPkg, :unsettled).since)
println("TRACKING=", ExperimentalAPI.mark(MarkedPkg, :unsettled).tracking)
println("UNACCOUNTED=", join(sort(string.(ExperimentalAPI.audit(MarkedPkg).unaccounted)), ","))
println("STABLE=", join(sort(string.(ExperimentalAPI.stable(MarkedPkg))), ","))
println("CACHED=", Base.isprecompiled(Base.PkgId(MarkedPkg)))
"""

function parse_probe(out)
    return Dict(
        String(split(l, "="; limit=2)[1]) => String(split(l, "="; limit=2)[2]) for
        l in split(strip(out), "\n") if occursin("=", l)
    )
end

# `--depwarn=error` is load-bearing: writing a mark emits a `const` and then reads it back, and
# Julia 1.12 deprecates doing that within one world age. A regression there would precompile
# today and stop working on the next Julia, which is exactly the class of failure that has to be
# caught here rather than in a consumer.
function run_probe(env, depots)
    cmd = `$(Base.julia_cmd()) --startup-file=no --depwarn=error --project=$env -e $PROBE`
    return parse_probe(read(subprocess_env(cmd, depots), String))
end

# `Pkg.test` exports a JULIA_LOAD_PATH pointing at ITS temporary environment and omitting
# `@stdlib`; inherited, it silently overrides `--project` and the child cannot even load Pkg.
function subprocess_env(cmd, depots)
    return addenv(
        cmd, "JULIA_DEPOT_PATH" => join(depots, ":"), "JULIA_LOAD_PATH" => "@:@stdlib"
    )
end

@testset "marks survive precompilation" begin
    mktempdir() do dir
        env = joinpath(dir, "env")
        mkpath(env)
        # Scratch depot FIRST so every cache this test writes lands in it, and the real depot
        # after it so registries and already-built stdlibs are still found.
        depots = [joinpath(dir, "depot"), DEPOT_PATH...]
        setup = """
        using Pkg
        Pkg.activate($(repr(env)); io = devnull)
        Pkg.develop([
            Pkg.PackageSpec(path = $(repr(dirname(@__DIR__)))),
            Pkg.PackageSpec(path = $(repr(FIXTURE))),
        ]; io = devnull)
        """
        run(
            subprocess_env(
                `$(Base.julia_cmd()) --startup-file=no --project=$env -e $setup`, depots
            ),
        )

        cold = run_probe(env, depots)   # compiles the fixture
        warm = run_probe(env, depots)   # loads it from the cache the cold run wrote

        @test warm["CACHED"] == "true"
        @testset "$phase" for (phase, r) in
                              ("compiled from source" => cold, "from cache" => warm)
            @test r["NAMES"] == "unsettled,unsettled_type"
            @test r["REASON"] == "the return shape is still being decided"
            @test r["SINCE"] == "0.1.0"
            @test r["TRACKING"] == "https://example.invalid/issues/1"
            # `settled` is documented and the other two are declared, so nothing is left over —
            # the audit of a marked package agrees with the marks that survived.
            @test r["UNACCOUNTED"] == ""
            @test r["STABLE"] == "settled"
        end
        @test cold == warm
    end
end
