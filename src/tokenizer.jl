struct Tokenizer{F, D}
    f::F
    data::D
end

Tokenizer(f::Function, data) = Tokenizer{typeof(f), typeof(data)}(f, data)
Base.IteratorSize(::Type{<:Tokenizer}) = Base.SizeUnknown()

# Currently, actions are added to final byte. This usually inhibits SIMD,
# because the end position must be updated every byte.
# It would be faster to add actions to :exit, but then the action will not actually
# trigger when a regex is exited with an "invalid byte" - the beginning of a new regex.
# I'm not quite sure how to handle this.
"""
    make_tokenizer(
        funcname::Symbol, tokens::Vector{<:Union{Re, Pair{RE, Expr}}};
        goto=true, unambiguous=false
    )

Create code which when evaluated, defines a function called `funcname`.
This function will read a buffer (string, `Vector{UInt8}` etc) and return a vector
of 3-tuples of integers:
* The first is the 1-based starting index of the token in the buffer
* The second is the length of the token in bytes
* The third is the token kind: The index in the input list `tokens`.

# Extra help
Any actions inside the input regexes will be ignored, but for every token that is
a `Pair{RE, Expr}`, the expression will be evaluated when the token is emitted.

The keyword `unambiguous` decides which of multiple matching tokens is emitted:
If `false` (default), the longest token is emitted. If multiple tokens have the
same length, the one with the highest index is returned.
If `true`, `make_tokenizer` will error if any possible input text can be broken
ambiguously down into tokens.

If `goto` (default), use the faster, but more complex goto code generator.

# Example:
```
julia> make_tokenizer(:foo, [:a => re"ab+", :b => re"a"]) |> eval;

julia> foo("abbbabaaababa")
7-element Vector{Tuple{Int64, Int32, UInt32}}:
 (1, 4, 0x00000001)
 (5, 2, 0x00000001)
 (7, 1, 0x00000002)
 (8, 1, 0x00000002)
 (9, 2, 0x00000001)
 (11, 2, 0x00000001)
 (13, 1, 0x00000002)
```
"""
function make_tokenizer(
    funcname::Symbol,
    tokens::Vector{RegExp.RE};
    goto::Bool=true,
    unambiguous=false
)
    ctx = if goto
        Automa.CodeGenContext(generator=:goto)
    else
        Automa.DefaultCodeGenContext
    end
    vars = ctx.vars
    tokens = map(enumerate(tokens)) do (i, regex)
        onenter!(onfinal!(RegExp.strip_actions(regex), Symbol(:__token_, i)), :__enter_token)
    end
    # We need the predefined actions here simply because it allows us to add priority to the actions.
    # This is necessary to guarantee that tokens are disambiguated in the correct order.
    predefined_actions = Dict{Symbol, Action}()
    # In these actions, store enter token and exit token.
    actions = Dict{Symbol, Expr}(
        :__enter_token => :(token_start = $(vars.p)),
    )
    for i in eachindex(tokens)
        predefined_actions[Symbol(:__token_, i)] = Action(Symbol(:__token_, i), 1000 + i)
        # The action for every token's final byte is to say: "This is where the token ends, and this is
        # what kind it is"
        actions[Symbol(:__token_, i)] = quote
            stop = $(vars.p)
            token = $(UInt32(i))
        end
    end
    # We intentionally set unambiguous=true. With the current construction of
    # this tokenizer, this will cause the longest token to be matched, i.e. for
    # the regex "ab" and "a", the text "ab" will emit only the "ab" regex.
    # Here, the NFA (i.e. the final regex we match) is a giant alternation statement between each of the tokens,
    # i.e. input is token1 or token2 or ....
    nfa = re2nfa(RegExp.RE(:alt, tokens), predefined_actions)
    machine = nfa2machine(nfa; unambiguous=unambiguous)
    return quote
        $(funcname)(data) = $(Tokenizer)($(funcname), data)
        function Base.iterate(tokenizer::$(Tokenizer){typeof($funcname)}, state=(1, Int32(1), UInt32(0)))
            data = tokenizer.data
            (start, len, token) = state
            start > sizeof(data) && return nothing
            if !iszero(token)
                return (state, (start + len, Int32(0), UInt32(0)))
            end
            $(generate_init_code(ctx, machine))
            token_start = start
            stop = 0
            token = UInt32(0)
            while true
                $(vars.p) = token_start
                # Every time we try to find a token, we reset the machine's state to 1, i.e. we carry
                # no memory between each token.
                $(vars.cs) = 1
                $(generate_exec_code(ctx, machine, actions))
                $(vars.cs) = 1

                # There are only a few possibilities for why it stopped execution, we handle
                # each of them here.
                # If a token was found:
                if !iszero(token)
                    found_token = (token_start, (stop-token_start+1)%Int32, token)
                    # If a token was found, but there are some error data, we emit the error data first,
                    # then set the state to be nonzero so the token is emitted next iteration
                    if start < token_start
                        error_token = (start, (token_start-start)%Int32, UInt32(0))
                        return (error_token, found_token)
                    # If no error data, simply emit the token with a zero state
                    else
                        return (found_token, (stop+1, Int32(0), UInt32(0)))
                    end
                else
                    # If no token was found and EOF, emit an error token for the rest of the data
                    if $(vars.p) > $(vars.p_end)
                        error_token = (start, ($(vars.p) - start)%Int32, UInt32(0))
                        return (error_token, ($(vars.p_end)+1, Int32(0), UInt32(0)))
                    # If no token, and also not EOF, we continue, looking at next byte
                    else
                        token_start += 1
                    end
                end
            end
        end
    end
end