using Documenter
using TranscodingStreams # to load extension
using Automa

DocMeta.setdocmeta!(Automa, :DocTestSetup, :(using Automa); recursive=true)

#include("create_pngs.jl")

makedocs(
    sitename = "Automa.jl",
    modules = [Automa],
    pages = [
        "Home" => "index.md",
        "Theory" => "theory.md",
        "Regex" => "regex.md",
        "Validators" => "validators.md",
        "Tokenizers" => "tokenizer.md",
        "Parsing buffers" => "parser.md",
        "Customizing codegen" => "custom.md",
        "Parsing IOs" => "io.md",
        "Creating readers" => "reader.md",
        "Debugging Automa" => "debugging.md",
        ],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true"
    ),
    checkdocs = :exports
)

deploydocs(
    repo = "github.com/BioJulia/Automa.jl.git",
    target = "build",
    push_preview = true,  
)
