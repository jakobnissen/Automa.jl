# DOT Language
# ============

function nfa2dot(nfa::NFA)
    buf = IOBuffer()
    println(buf, "digraph {")
    println(buf, "  graph [ rankdir = LR ];")
    println(buf, "  0 -> 1;")
    println(buf, "  0 [ shape = point ];")
    serial = 0
    serials = Dict(nfa.start => (serial += 1))
    unmarked = Set([nfa.start])
    while !isempty(unmarked)
        s = pop!(unmarked)
        for (l, T) in s.next, t in T
            if !haskey(serials, t)
                serials[t] = (serial += 1)
                push!(unmarked, t)
            end
            println(buf, "  $(serials[s]) -> $(serials[t]) [ label = \"$(label2str(l))\" ];")
        end
    end
    for (node, serial) in serials
        shape = node == nfa.final ? "doublecircle" : "circle"
        xlabel = actions2str([a.name for a in node.actions])
        println(buf, "  $(serial) [ shape = $(shape), xlabel = \"$(xlabel)\" ];")
    end
    println(buf, "}")
    return takebuf_string(buf)
end

function dfa2dot(dfa::DFA)
    buf = IOBuffer()
    println(buf, "digraph {")
    println(buf, "  graph [ rankdir = LR ];")
    println(buf, "  start -> 1;")
    println(buf, "  start [ shape = point ];")
    println(buf, "  final [ shape = point ];")
    serial = 0
    serials = Dict(dfa.start => (serial += 1))
    unmarked = Set([dfa.start])
    while !isempty(unmarked)
        s = pop!(unmarked)
        for (l, (t, as)) in s.next
            if !haskey(serials, t)
                serials[t] = (serial += 1)
                push!(unmarked, t)
            end
            label = label2str(l, as)
            println(buf, "  $(serials[s]) -> $(serials[t]) [ label = \"$(label)\" ];")
        end
        if s.final
            label = label2str(:eof, s.eof_actions)
            println(buf, "  $(serials[s]) -> final [ label = \"$(label)\" ];")
        end
    end
    for (node, serial) in serials
        shape = node.final ? "doublecircle" : "circle"
        println(buf, "  $(serial) [ shape = $(shape) ];")
    end
    println(buf, "}")
    return takebuf_string(buf)
end

function label2str(label, actions)
    if isempty(actions)
        return label2str(label)
    else
        return string(label2str(label), '/', actions2str(actions))
    end
end

function label2str(label)
    if label == :eps
        return "ε"
    elseif label == :eof
        return "EOF"
    elseif isa(label, UInt8)
        return escape_string(escape_string(string(''', Char(label), ''')))
    elseif isa(label, UnitRange{UInt8})
        if length(label) == 1
            return string(label2str(first(label)))
        else
            return string(label2str(first(label)), ':', label2str(last(label)))
        end
    elseif isa(label, Vector)
        return join([label2str(l) for l in label], ',')
    else
        return escape_string(repr(label))
    end
end

function actions2str(actions)
    return join(actions, ',')
end
