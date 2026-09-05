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
#
# It asks about all three KINDS of mark, because they are stored differently: a whole-name
# declaration, a mark attached to a definition (which also carries the `Type` it created), and a
# mark on a method of `Base.show`, whose signature names a type defined in the cached package.
# Only the first of those had ever been through a cache. It also runs `reach` across the package
# boundary, which is the query that reads the other two.

using Test: @test, @testset

const FIXTURE = joinpath(@__DIR__, "fixtures", "MarkedPkg")

# Windows separates the entries of an environment path list with `;`, every other platform with
# `:`. Getting it wrong does not produce a subtly wrong depot — the child cannot find `Pkg` at
# all, which is how the first Windows run this package ever had failed while all 239 other tests
# on that runner passed.
const PATHSEP = Sys.iswindows() ? ";" : ":"

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
println("DEPOT1=", first(DEPOT_PATH))

# The signature half. A `Mark` records the signature it attached to, and that field is a `Type`
# living in a `const` vector inside the cache image — a different thing to serialise from a
# `Symbol` and a `String`, and the reason this probe is not just about names.
println("SIG=", ExperimentalAPI.mark(MarkedPkg, :unsettled).sig)
println("METHODMARKS=", join(sort(string.(getfield.(ExperimentalAPI.experimental_methods(MarkedPkg), :name))), ","))
println("SHOWSIG=", ExperimentalAPI.mark(MarkedPkg, :show).sig)
println("SHOWMARKED=", ExperimentalAPI.isexperimental(which(show, Tuple{IO,MarkedPkg.Widget})))
println("SHOWSIBLING=", ExperimentalAPI.isexperimental(which(show, Tuple{IO,Int})))
println("BASESHOW=", ExperimentalAPI.isexperimental(Base, :show))

# And the query that reads it: a caller in THIS process reaching a mark that was written while
# another process precompiled another package. Nothing here names `unsettled`.
caller(x) = MarkedPkg.consumer(x) + 1
control(x) = MarkedPkg.settled(x) + 1
println("REACH=", ExperimentalAPI.verdict(ExperimentalAPI.reach(caller, Tuple{Int})))
println("REACHCONTROL=", ExperimentalAPI.verdict(ExperimentalAPI.reach(control, Tuple{Int})))
println("REACHNAME=", join(sort(string.([r.mark.name for r in ExperimentalAPI.reach(caller, Tuple{Int}).reached])), ","))
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

# The child's environment is BUILT, not patched. `Pkg.test` exports a JULIA_LOAD_PATH pointing at
# its own temporary environment and omitting `@stdlib`; inherited, that overrides `--project` and
# the child cannot even load Pkg. Deleting the variable outright — rather than overwriting it with
# a hand-built list — leaves Julia's own default (`@:@v#.#:@stdlib`) in charge, which is both what
# is wanted and one fewer platform-specific string to get right.
#
# `setenv` REPLACES the environment rather than adding to it, so the base has to be `copy(ENV)`.
function subprocess_env(cmd, depots)
    env = copy(ENV)
    delete!(env, "JULIA_LOAD_PATH")
    env["JULIA_DEPOT_PATH"] = join(depots, PATHSEP)
    return setenv(cmd, env)
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

        # If JULIA_DEPOT_PATH did not take, the caches below went into the developer's real
        # depot and the "compiled fresh, then read back" claim is about the wrong depot. That
        # failure is otherwise silent, and silent pollution is worse than a red test.
        @test cold["DEPOT1"] == first(depots)
        @test warm["CACHED"] == "true"
        @testset "$phase" for (phase, r) in
                              ("compiled from source" => cold, "from cache" => warm)
            @test r["NAMES"] == "show,unsettled,unsettled_type"
            @test r["REASON"] == "the return shape is still being decided"
            @test r["SINCE"] == "0.1.0"
            @test r["TRACKING"] == "https://example.invalid/issues/1"
            # `settled`, `Widget` and `consumer` are documented and the rest are declared, so
            # nothing is left over — the audit of a marked package agrees with the marks that
            # survived.
            @test r["UNACCOUNTED"] == ""
            @test r["STABLE"] == "Widget,consumer,settled"

            # The signature came back, and it is the one the definition created rather than a
            # widened stand-in.
            @test r["SIG"] == "Tuple{typeof(MarkedPkg.unsettled), Any}"
            @test r["METHODMARKS"] == "show,unsettled"
            # The hard case: a mark on a method of somebody else's generic, whose signature names
            # `typeof(Base.show)` and a type defined in the cached package.
            @test r["SHOWSIG"] == "Tuple{typeof(show), IO, MarkedPkg.Widget}"
            @test r["SHOWMARKED"] == "true"
            # Controls, both of which would also be "true" for a mark that had widened to the
            # whole generic on its way through the cache.
            @test r["SHOWSIBLING"] == "false"
            @test r["BASESHOW"] == "false"

            # A caller that reaches a mark written during ANOTHER package's precompilation,
            # without naming it — and a control of the same depth that reaches nothing marked.
            @test r["REACH"] == "depends"
            @test r["REACHNAME"] == "unsettled"
            @test r["REACHCONTROL"] == "clean"
        end
        @test cold == warm
    end
end
