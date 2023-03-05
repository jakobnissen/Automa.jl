using Automa

keyword = re"break|const|continue|else|elseif|end|for|function|if|return|type|using|while"
identifier = re"[A-Za-z_][0-9A-Za-z_!]*"
operator = re"-|\+|\*|/|%|&|\||^|!|~|>|<|<<|>>|>=|<=|=>|==|==="
macrocall = re"@" * re"[A-Za-z_][0-9A-Za-z_!]*"
comment = re"#[^\r\n]*"
char = '\'' * (re"[ -&(-~]" | ('\\' * re"[ -~]")) * '\''
string = '"' * rep(re"[ !#-~]" | re"\\\\\"") * '"'
triplestring = "\"\"\"" * (re"[ -~]*" \ re"\"\"\"") * "\"\"\""
newline = re"\r?\n"

minijulia = [
    :identifier   => identifier,
    :comma        => re",",
    :colon        => re":",
    :semicolon    => re";",
    :dot          => re"\.",
    :question     => re"\?",
    :equal        => re"=",
    :lparen       => re"\(",
    :rparen       => re"\)",
    :lbracket     => re"\[",
    :rbracket     => re"]",
    :lbrace       => re"{",
    :rbrace       => re"}",
    :dollar       => re"$",
    :and          => re"&&",
    :or           => re"\|\|",
    :typeannot    => re"::",
    :keyword      => keyword,
    :operator     => operator,
    :macrocall    => macrocall,
    :integer      => re"[0-9]+",
    :comment      => comment,
    :char         => char,
    :string       => string,
    :triplestring => triplestring,
    :newline      => newline,
    :spaces       => re"[\t ]+",
]

#=
write("minijulia.dot", Automa.machine2dot(minijulia.machine))
run(`dot -Tsvg -o minijulia.svg minijulia.dot`)
=#

make_tokenizer(:tokenize, minijulia) |> eval

tokens = tokenize("""
quicksort(xs) = quicksort!(copy(xs))
quicksort!(xs) = quicksort!(xs, 1, length(xs))

function quicksort!(xs, lo, hi)
    if lo < hi
        p = partition(xs, lo, hi)
        quicksort!(xs, lo, p - 1)
        quicksort!(xs, p + 1, hi)
    end
    return xs
end

function partition(xs, lo, hi)
    pivot = div(lo + hi, 2)
    pvalue = xs[pivot]
    xs[pivot], xs[hi] = xs[hi], xs[pivot]
    j = lo
    @inbounds for i in lo:hi-1
        if xs[i] <= pvalue
            xs[i], xs[j] = xs[j], xs[i]
            j += 1
        end
    end
    xs[j], xs[hi] = xs[hi], xs[j]
    return j
end
""")
