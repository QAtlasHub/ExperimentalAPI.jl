using ExperimentalAPI
using Test

# ExperimentalAPI is its own first consumer: the audit it publishes is run against its own public
# surface, so shipping an undocumented, undeclared name fails this suite before it reaches anyone.
@testset "ExperimentalAPI" begin
    include("test_mark.jl")
    include("test_query.jl")
    include("test_audit.jl")
    include("test_release.jl")
    include("test_ext.jl")
    include("test_precompile.jl")
    include("test_dogfood.jl")
    # The case matrix. Written before the implementation, so most of it is @test_broken;
    # see test/spec/README.md for why that is the right register.
    include("spec/test_spec_declare.jl")
    include("spec/test_spec_propagate.jl")
    include("spec/test_spec_docstring.jl")
    include("spec/test_spec_verify.jl")
    include("spec/test_spec_runtime.jl")
    include("spec/test_spec_profile.jl")
    include("spec/test_spec_foreign.jl")
    include("spec/test_spec_forms.jl")
    include("spec/test_spec_integration.jl")
    include("spec/test_spec_dispatch.jl")
    include("test_aqua.jl")
end
