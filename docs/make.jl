using Documenter
using TranscodingStreams # to load extension
using Automa

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
        "Parsing buffers" => "parser.md",
        "Customizing codegen" => "custom.md",
        "Parsing IOs" => "io.md",
        "Creating readers" => "reader.md",
        "Debigging Automa" => "debugging.md",
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