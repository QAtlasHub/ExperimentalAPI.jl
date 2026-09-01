# `test_surface` lives in an extension so that `ExperimentalAPI` — which is loaded by the package
# being marked, not only by its test suite — never drags `Test` into a runtime dependency.

module ExperimentalAPITestExt

using ExperimentalAPI: ExperimentalAPI, Audit, audit, isdocumented, isexperimental
using Test: Test, @test, @testset

function ExperimentalAPI.test_surface(
    m::Module; skip::AbstractVector{Symbol}=Symbol[], outputlevel::Int=0
)
    a = audit(m)
    outputlevel ≥ 1 && show(stdout, MIME"text/plain"(), a)
    @testset "public surface of $(nameof(m))" begin
        # One testset per name, so a failing CI log names the symbol in its header rather than
        # printing a set difference the reader has to diff by eye.
        @testset "$n is documented or @experimental" for n in setdiff(a.unaccounted, skip)
            @test isdocumented(m, n) || isexperimental(m, n)
        end
        # The allowlist can only shrink. An entry that has since been documented, declared or
        # deleted fails here — otherwise adopting this on a package with a backlog would leave a
        # list that silently stops describing anything, and a green suite would mean less every
        # release.
        @testset "skip entry $n is still needed" for n in skip
            @test n in a.unaccounted
        end
        # Needs no oracle: the module marked a name it never made public.
        @testset "@experimental $n is public" for n in a.dangling
            @test n in a.surface
        end
    end
    return a
end

end # module
