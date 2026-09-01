# A real package, loaded from its own precompile cache by test/test_precompile.jl. The marks it
# carries are written at ITS precompile time — which is the moment a design that stored them in
# ExperimentalAPI's own state would lose them, and this fixture is how that gets caught.
module MarkedPkg

using ExperimentalAPI

export settled
public unsettled, unsettled_type

"Documented, and not going to change."
settled(x) = x

@experimental(
    "the return shape is still being decided",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/1",
    function unsettled(x)
        return (x, x)
    end
)

@experimental("may become a parametric type", struct unsettled_type
    v::Int
end)

end
