using ExperimentalAPI
using Documenter

makedocs(;
    sitename="ExperimentalAPI.jl",
    format=Documenter.HTML(;
        # Measured 2026-09-03: the host serves `/` and `/dev/` with 200 and `/stable/` with 404,
        # because `gh-pages` holds only `dev` until a version is tagged. `/stable/` is still the
        # right canonical target — it materialises on the first release, and `/dev/` is a moving
        # target that should never be canonical. The previous value pointed at a host that does
        # not resolve at all.
        canonical="https://qatlashub.github.io/ExperimentalAPI.jl/stable/",
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link="main",
    ),
    modules=[ExperimentalAPI],
    # `:public` is the same claim this package makes about its users: a name on the public
    # surface without a docstring fails the build. ExperimentalAPI's own release layer is
    # declared @experimental AND documented, so it satisfies both.
    checkdocs=:public,
    pages=[
        "Home" => "index.md",
        "Declaring" => "declaring.md",
        "Observing" => "observing.md",
        "Analysing" => "analysing.md",
        "Checking" => "checking.md",
        "Release decisions" => "releases.md",
        "Adopting it" => "adopting.md",
        "API" => [
            "Declaring" => "api.md",
            "Observing and analysing" => "api-runtime.md",
            "Checking and releasing" => "api-checks.md",
        ],
    ],
)

deploydocs(;
    repo="github.com/QAtlasHub/ExperimentalAPI.jl", devbranch="main", push_preview=true
)
