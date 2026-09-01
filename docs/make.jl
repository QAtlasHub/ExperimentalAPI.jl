using ExperimentalAPI
using Documenter

makedocs(;
    sitename="ExperimentalAPI.jl",
    format=Documenter.HTML(;
        canonical="https://codes.sota-shimozono.com/ExperimentalAPI.jl/stable/",
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
        "Checking" => "checking.md",
        "Release decisions" => "releases.md",
        "Adopting it" => "adopting.md",
        "API" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/QAtlasHub/ExperimentalAPI.jl", devbranch="main", push_preview=true
)
