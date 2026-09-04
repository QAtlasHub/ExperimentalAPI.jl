# The mark, in the rendered documentation, without the author typing the reason a second time.
#
# Typed twice, the prose and the machine-readable declaration drift, and the machine-readable one
# loses — nobody reads it, so nobody notices. This registers an `@experimental` block so a docs
# page can ask the module instead:
#
#     ```@experimental
#     MyPackage
#     ```

module ExperimentalAPIDocumenterExt

using ExperimentalAPI: ExperimentalAPI, marks_markdown
using Documenter: Documenter

# Reached through `Documenter` rather than declared as a dependency of its own: `MarkdownAST` is
# Documenter's, and an extension that names it separately would have to keep a compat bound on a
# package it never chose.
const MarkdownAST = Documenter.MarkdownAST

abstract type ExperimentalBlocks <: Documenter.Expanders.NestedExpanderPipeline end

# Between `@raw` (11.0) and the tail of the pipeline: nothing else matches `@experimental`, so the
# exact position only has to be stable, not early.
Documenter.Selectors.order(::Type{ExperimentalBlocks}) = 11.5

function Documenter.Selectors.matcher(::Type{ExperimentalBlocks}, node, page, doc)
    return Documenter.iscode(node, r"^@experimental")
end

function Documenter.Selectors.runner(::Type{ExperimentalBlocks}, node, page, doc)
    x = node.element
    mods = Module[]
    for line in split(x.code, '\n')
        name = strip(line)
        isempty(name) && continue
        m = _resolve(String(name))
        if m === nothing
            @error "@experimental block: `$name` is not a loaded module" page = page.source
            return nothing
        end
        push!(mods, m)
    end
    isempty(mods) && return nothing
    md = join((marks_markdown(m) for m in mods), "\n")
    # Inserted as siblings and the block unlinked, rather than replacing the element: the parsed
    # markdown is several blocks, and a code block's element cannot hold more than one.
    for block in Documenter.mdparse(md; mode=:blocks)
        MarkdownAST.insert_before!(node, block)
    end
    MarkdownAST.unlink!(node)
    return nothing
end

function _resolve(name::AbstractString)
    parts = Symbol.(split(name, "."))
    for (_, root) in Base.loaded_modules
        nameof(root) === parts[1] || continue
        m = root
        for p in parts[2:end]
            (isdefined(m, p) && getglobal(m, p) isa Module) || return nothing
            m = getglobal(m, p)
        end
        return m
    end
    return nothing
end

end # module
