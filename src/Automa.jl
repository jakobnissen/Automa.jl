module Automa

export
    cat,
    alt,
    rep,
    @re_str,
    compile,
    generate_init,
    generate_exec

include("re.jl")
include("nfa.jl")
include("dfa.jl")
include("dot.jl")
include("machine.jl")
include("codegen.jl")

end # module
