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
    include("test_aqua.jl")
end
