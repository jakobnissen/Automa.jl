using Documenter
using TranscodingStreams # to load extension
using Automa
Automa.generate_io_validator

#include("make_pngs.jl")

makedocs(
    sitename = "Automa.jl",
    modules = [Automa],
    pages = [
        "Home" => "index.md",
        "Theory" => "theory.md",
        "Regex" => "regex.md",
        "Validators" => "validators.md",
        "Tokenizers" => "tokenizer.md",
        "References" => "references.md"
        ],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true")
)

deploydocs(
    repo = "github.com/BioJulia/Automa.jl.git",
    target = "build",
    push_preview = true,  
)
