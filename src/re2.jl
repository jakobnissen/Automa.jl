module RegExp

# WHY?
# Type stable for compilation speed
# Easier to reason about code
# Replace
# foo.actions[:enter] = [:bar]
# onenter(foo, :bar)

using Automa: ByteSet, range_encode

struct REActions
    enter::Union{Nothing, Vector{Symbol}}
    exit::Union{Nothing, Vector{Symbol}}
    all::Union{Nothing, Vector{Symbol}}
    final::Union{Nothing, Vector{Symbol}}
end

const NO_ACTIONS = REActions(nothing, nothing, nothing, nothing)

struct REHead
    x::UInt8
    function REHead(x::Integer)
        x > 6 && error("REHead out of range")
        new(x)
    end
end

const SYMBOL = REHead(0x00)
const REP = REHead(0x01)
const CAT = REHead(0x02)
const ALT = REHead(0x03)
const AND = REHead(0x04)
const DIFF = REHead(0x05)
const NULLHEAD = REHead(0x06)

mutable struct RE
    # What kind of regex is this? I.e. cat, rep, alt etc
    head::REHead
    # Content of regex - depends on head
    args::Union{ByteSet, RE, Tuple{RE, RE}, Vector{RE}, Nothing}
    actions::Union{Nothing, REActions}
    when::Union{Nothing, Symbol}
    
    function RE(head::REHead, args::Union{ByteSet, RE, Tuple{RE, RE}, Vector{RE}, Nothing})
        if head === SYMBOL
            (args isa ByteSet) || error("SYMBOL must take ByteSet")
            isempty(args) && error("Cannot make SYMBOL regex with empty byteset")
        elseif head === REP
            (args isa RE) || error("REP must take one regex")
        elseif head === NULLHEAD
            args === nothing || error("NULLHEAD regex `take nothing` as argument")
        elseif head === CAT
            (args isa Vector{RE}) || error("CAT must take Vector{RE}")
        else
            (args isa Tuple{RE, RE}) || error("RE must take tuple of RE")
        end
        new(head, args, nothing, nothing)
    end
end

function enter!(x::RE, actions::Vector{Symbol})
    these_actions = isempty(actions) ? nothing : actions
    act = x.actions === nothing ? NO_ACTIONS : x.actions
    RE.actions = REActions(these_actions, act.exit, act.all, act.final)
    nothing
end
enter!(x::RE, action::Symbol) = enter!(x, [action])

function exit!(x::RE, actions::Vector{Symbol})
    these_actions = isempty(actions) ? nothing : actions
    act = x.actions === nothing ? NO_ACTIONS : x.actions
    RE.actions = REActions(act.enter, these_actions, act.all, act.final)
    nothing
end
exit!(x::RE, action::Symbol) = exit!(x, [action])

function Base.all!(x::RE, actions::Vector{Symbol})
    these_actions = isempty(actions) ? nothing : actions
    act = x.actions === nothing ? NO_ACTIONS : x.actions
    RE.actions = REActions(act.enter, act.exit, these_actions, act.final)
    nothing
end
Base.all!(x::RE, action::Symbol) = onall!(x, [action])

function final!(x::RE, actions::Vector{Symbol})
    these_actions = isempty(actions) ? nothing : actions
    act = x.actions === nothing ? NO_ACTIONS : x.actions
    RE.actions = REActions(act.enter, act.exit, act.all, these_actions)
    nothing
end
final!(x::RE, action::Symbol) = final!(x, [action])

function when(x::RE, s::Symbol)
    x.when = s
    nothing
end

# NULL is not the empty set, but the empty string (these are different regex)
const NULL = RE(NULLHEAD, nothing)

# Primitives
function cat(a::RE, b::RE)
    a === NULL && return b
    b === NULL && return a
    v = if a.head === CAT
        if b.head === CAT
            append!(copy(a.args::Vector), b.args::Vector)
        else
            push!(copy(a.args::Vector), b)
        end
    elseif b.head === CAT
        # we know a is not cat, we just checked
        pushfirst!(copy(b.args::Vector), a)
    else
        [a, b]
    end
    RE(CAT, v)
end

function cat(a::RE, b::RE, c::Vararg{RE})
    isempty(c) && return cat(a, b)
    cat(a, cat(b, c...))
end
Base.:*(a::RE, b::RE, c::Vararg{RE}) = cat(a, b, c...)

alt(a::RE, b::RE) = RE(ALT, (a, b))
Base.:|(a::RE, b::RE) = alt(a, b)

function rep(a::RE)
    a === NULL && return NULL
    RE(REP, a)
end

Base.intersect(a::RE, b::RE) = RE(AND, (a, b))
Base.:&(a::RE, b::RE) = intersect(a, b)

Base.setdiff(a::RE, b::RE) = RE(DIFF, (a, b))
Base.:\(a::RE, b::RE) = setdiff(a, b)

sym(x::ByteSet) = RE(SYMBOL, x)

# Derived
rep1(a::RE) = cat(a, rep(a))
opt(a::RE) = alt(NULL, a)
Base.:!(x::RE) = setdiff(rep(ANY), x)

# RE constructors from bytes/strings/chars
literal(x::UInt8) = sym(ByteSet((x,)))

function literal(c::Char)
    if isascii(c)
        return literal(UInt8(c))
    else
        cu = codeunits(string(c))
        foldr(codeunits(string(c)), init=NULL) do byte, re
            cat(literal(byte), re)
        end
    end
end

literal(s::AbstractString) = literal(String(s))
function literal(s::Union{String, SubString{String}})
    foldr(s, init=NULL) do char, re
        cat(literal(char), re)
    end
end

# Printing
function printbyte(io::IO, b::UInt8, inrange::Bool)
    if inrange && b == UInt8('-')
        print(io, "\\-")
    elseif inrange && b == UInt8(']')
        print(io, "\\]")
    else
        print(io,
            if b ≤ 0x7f
                escape_string(string(Char(b)))
            else
                "\\x" * string(b, base=16)
            end
        )
    end
end

function printstring(x::REHead)
    if x === CAT
        "cat"
    elseif x === ALT
        "alt"
    elseif x === AND
        "intersect"
    elseif x === DIFF
        "setdiff"
    else
        error()
    end
end

function print_syms(io::IO, bs::ByteSet)
    if length(bs) == 1
        printbyte(io, first(bs), false)
    else
        @assert length(bs) > 1
        print(io, "[")
        for r in range_encode(bs)
            if length(r) == 1
                printbyte(io, first(r), true)
            elseif length(r) == 2
                printbyte(io, first(r), true)
                printbyte(io, last(r), true)
            else
                @assert length(r) > 1
                printbyte(io, first(r), true)
                print(io, '-')
                printbyte(io, last(r), true)
            end
        end
        print(io, "]")
    end
end

Base.show(io::IO, x::RE) = _show(io, x, 0, false)
function _show(io::IO, x::RE, indent::Int, newline::Bool)
    head = x.head
    ind = "    "^(indent)
    print(io, ind)
    ending = newline ? "\n" : ""
    if head === NULLHEAD
        return print(io, "NULL", ending)
    elseif head === SYMBOL
        args = x.args::ByteSet
        print(io, "re\"")
        print_syms(io, x.args::ByteSet)
        print(io, "\"", ending)
    elseif head === REP
        args = x.args::RE
        print(io, "rep(\n")
        _show(io, args, indent+1, true)
        print(io, ind, ")", ending)
    elseif head === CAT
        # Show as rep1 if possible
        args = x.args::Vector
        if length(args) == 2 && args[1].head === REP && args[1].args === args[2]
            print(io, "rep1(\n")
            _show(io, r2, indent+1, true)
            print(io, ind, ")", ending)
        # Else, if literal, show as that
        elseif all(i -> i.head === SYMBOL, args)
            print(io, "re\"", literal_string(args), "\"", ending)
        # Else, show what can be shown as literals as that, rest using recursion
        else
            print(io, "cat(\n")
            start = stop = 1
            while start ≤ length(args)
                while stop ≤ length(args) && args[stop].head === SYMBOL
                    stop += 1
                end
                stop -= 1
                if stop ≥ start
                    print(io, ind, "    re\"", literal_string(args[start:stop]), "\",\n")
                    start = stop+1
                    stop = start
                else
                    _show(io, args[start], indent+1, false)
                    print(io, ",\n")
                    start += 1
                end
            end
            print(io, "    "^(indent), ")" * (newline ? "\n" : ""))
        end
    elseif head === ALT
        # Show as opt if possible
        a1, a2 = x.args::Tuple
        if a1 === NULL || a2 === NULL
            arg = a1 === NULL ? a2 : a1
            print(io, "opt(\n")
            _show(io, arg, indent+1, true)
            print(io, ind, ")", ending)
        else
            _defaultshow(io, x, indent, newline)
        end
    else
        _defaultshow(io, x, indent, newline)
    end
end

function literal_string(args::Vector{RE})
    buf = IOBuffer()
    for arg in args
        print_syms(buf, arg.args::ByteSet)
    end
    String(take!(buf))
end

function _defaultshow(io::IO, x::RE, indent::Int, newline::Bool)
    args = x.args::Tuple
    print(io, printstring(x.head), "(\n")
    _show(io, args[1], indent+1, false)
    print(io, ",\n")
    _show(io, args[2], indent+1, true)
    print(io, "    "^(indent), ")" * (newline ? "\n" : ""))
end

end # module