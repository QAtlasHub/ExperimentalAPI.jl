# A real package, loaded from its own precompile cache by test/test_precompile.jl. The marks it
# carries are written at ITS precompile time — which is the moment a design that stored them in
# ExperimentalAPI's own state would lose them, and this fixture is how that gets caught.
#
# It carries one of each KIND of mark, because they are stored differently and only one of them
# was ever put through a cache: a whole-name declaration, a mark attached to a definition (which
# also records the signature it created), and a mark on a method of somebody else's generic. The
# last is the hard one — its `sig` names `typeof(Base.show)` and a type defined here, and it has
# to come back out of the cache image intact.
module MarkedPkg

using ExperimentalAPI

export settled
public unsettled, unsettled_type, Widget, consumer

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

"A type whose printed form is not settled."
struct Widget end

# A method on a generic this package does not own. The mark lives here, in the module that wrote
# the method; `Base.show` is not made experimental for anybody else.
@experimental "printing format not settled" Base.show(io::IO, ::Widget) = print(io, "W")

"Documented, and reaches an unsettled definition without naming it in its own signature."
consumer(x) = first(unsettled(x))

end
