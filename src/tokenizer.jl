# Currently, actions are added to final byte. This usually inhibits SIMD,
# because the end position must be updated every byte.
# It would be faster to add actions to :exit, but then the action will not actually
# trigger when a regex is exited with an "invalid byte" - the beginning of a new regex.
# I'm not quite sure how to handle this.
"""
    make_tokenizer(
        funcname::Symbol, tokens::Vector{Pair{Symbol, RE}};
        goto=true, unambiguous=false
    )

Create code which when evaluated, defines a function called `funcname`.
This function will read a buffer (string, `Vector{UInt8}` etc) and return a vector
of 3-tuples of integers:
* The first is the 1-based starting index of the token in the buffer
* The second is the length of the token in bytes
* The third is the token kind: The index in the input list `tokens`.
Any actions inside the input regexes will be ignored.

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
    tokens::Vector{Pair{Symbol, RegExp.RE}};
    goto::Bool=true,
    unambiguous=false
)
    ctx = if goto
        Automa.CodeGenContext(generator=:goto)
    else
        Automa.DefaultCodeGenContext
    end
    vars = ctx.vars
    symbols = map(first, tokens)
    if !allunique(symbols)
        error("Names of tokens must be unique")
    end
    if :__enter_token ∈ symbols
        error("Token symbol cannot be named `:__enter_token`")
    end
    tokens = map(tokens) do (symbol, regex)
        regex = onfinal!(RegExp.strip_actions(regex), Symbol(:__token_, symbol))
        symbol => onenter!(regex, :__enter_token)
    end
    predefined_actions = Dict{Symbol, Action}()
    for (priority, (symbol, _)) in enumerate(tokens)
        predefined_actions[Symbol(:__token_, symbol)] = Action(Symbol(:__token_, symbol), 1000 + priority)
    end
    # We intentionally set unambiguous=true. With the current construction of
    # this tokenizer, this will cause the longest token to be matched, i.e. for
    # the regex "ab" and "a", the text "ab" will emit only the "ab" regex.
    nfa = re2nfa(RegExp.RE(:alt, map(last, tokens)), predefined_actions)
    machine = nfa2machine(nfa; unambiguous=unambiguous)
    actions = Dict{Symbol, Expr}(
        :__enter_token => :(token_start = $(vars.p)),
    )
    for (i, symbol) in enumerate(symbols)
        actions[Symbol(:__token_, symbol)] = quote
            stop = $(vars.p)
            token = $(UInt32(i))
        end
    end
    return quote
        function $(funcname)(data)
            $(generate_init_code(ctx, machine))
            tokens = Vector{Tuple{Int, Int32, UInt32}}(undef, 1024)
            n_tokens = UInt(0)
            stop = 0
            start = 1
            token_start = 1
            while $(vars.p) ≤ $(vars.p_end)
                $(vars.p) = token_start
                token = UInt32(0)
                $(vars.cs) = 1
                $(generate_exec_code(ctx, machine, actions))
                $(vars.cs) = 1

                # We emit an error token if either we have a real token and also un-emitted error data
                # (in which case we know the end of the error data, namely before the start of the real token),
                # Or if we reach EOF without having found a token
                if (!iszero(token) & (start < token_start)) | (iszero(token) & ($(vars.p) > $(vars.p_end)))
                    n_tokens += UInt(1)
                    if n_tokens > length(tokens)
                        resize!(tokens, n_tokens + UInt(1023))
                    end
                    len = iszero(token) ? $(vars.p) - start : token_start - start 
                    @inbounds tokens[n_tokens] = (start, (len)%Int32, UInt32(0))
                end

                # Emit a token if we have one
                if !iszero(token)
                    n_tokens += UInt(1)
                    if n_tokens > length(tokens)
                        resize!(tokens, n_tokens + UInt(1023))
                    end
                    @inbounds tokens[n_tokens] = (token_start, (stop-token_start+1)%Int32, token)
                    start = token_start = $(vars.p) = stop + 1
                    # TODO: Execute code here when a token is emitted
                else
                    # If we have no token, then we begin looking for a new token at the next byte
                    token_start += 1
                end
            end
            return resize!(tokens, n_tokens)
        end
    end
end
