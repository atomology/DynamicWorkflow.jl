using Documenter
using DynamicWorkflow

makedocs(
    sitename="DynamicWorkflow.jl",
    format=Documenter.HTML(edit_link="main"),
    modules=[DynamicWorkflow],
    doctest=false,
    repo=Documenter.Remotes.GitHub("atomology", "DynamicWorkflow.jl"),
    pages=[
        "Home" => "index.md",
        "API Reference" => "api.md",
    ]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo="github.com/atomology/DynamicWorkflow.jl.git",
    devbranch="main",
)
