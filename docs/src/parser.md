# Parsing from a buffer
Automa can leverage metaprogramming to combine regex and julia code to create parsers.
This is significantly more difficult than simply using validators or tokenizers, but still simpler than parsing from an IO.
Currently, Automa loads data through pointers, and therefore needs data backed by `Array{UInt8}` or `String` or similar - it does not work with types such as `UnitRange{UInt8}`.
Furthermore, be careful about passing strided views to Automa - while Automa can extract a pointer from a strided view, it will always advance the pointer one byte at a time, disregarding the view's stride.

As an example, let's use the simplified FASTA format intoduced in the regex section, with the following format: `re"(>[a-z]+\n([ACGT]+\n)+)*"`.
We want to parse it into a `Vector{Seq}`, where `Seq` is defined as:

```julia
struct Seq
    name::String
    seq::String
end
```

To do this, we need to inject Julia code into the regex validator while it is running.
The first step is to add _actions_ to our regex: These are simply names of Julia expressions to splice in,
where the expressions will be executed when the regex is matched.
We can choose the names arbitrarily.

Currently, actions can be added in the following places in a regex:
* With `onenter!`, meaning it will be executed when reading the first byte of the regex
* With `onfinal!`, where it will be executed when reading the last byte of the regex.
  Note that it's not possible to determine the final byte for some regex like `re"X+"`, since
  the machine reads only 1 byte at a time and cannot look ahead.
* With `onexit!`, meaning it will be executed on reading the first byte AFTER the regex,
  or when exiting the regex by encountering the end of inputs (only for a regex match, not an unexpected end of input)
* With `onall!`, where it will be executed when reading every byte that is part of the regex.

You can set the actions to be a single action name (represented by a `Symbol`), or a list of action names:
```julia
my_regex = re"ABC"
onenter!(my_regex, [:action_a, :action_b])
onexit!(my_regex, :action_c)
```

In which case the code named `action_a`, then that named `action_b` will executed in order when entering the regex, and the code named `action_c` will be executed when exiting the regex.

The `onenter!` etc functions return the regex they modify, so the above can be written:
```julia
my_regex = onexit!(onenter!(re"ABC", [:action_a, :action_b]), :action_c)
```

To parse a simplified FASTA file into a `Vector{Seq}`, I want four actions:

* When the machine enters into the header, or a sequence line, I want it to mark the position with where it entered into the regex.
  The marked position will be used as the leftmost position where the header or sequence is extracted later.
* When exiting the header, I want to extract the bytes from the marked position in the action above,
  to the last header byte (i.e. the byte before the current byte), and use these bytes as the sequence header
* When exiting a sequence line, I want to do the same:
  Extract from the marked position to one before the current position,
  but this time I want to append the current line to a buffer containing all the lines of the sequence
* When exiting a record, I want to construct a `Seq` object from the header bytes and the buffer with all the sequence lines, then push the `Seq` to the result,

```julia
machine = let
    header = onexit!(onenter!(re"[a-z]+", :mark_pos), :header)
    seqline = onexit!(onenter!(re"[ACGT]+", :mark_pos), :seqline)
    record = onexit!(re">" * header * '\n' * rep1(seqline * '\n'), :record)
    compile(rep(record))
end
```

We can now write the code we want executed.
When writing this code, we want access to a few variables used by the machine simulation.
For example, we might want to know at which byte position the machine is when an action is executed.
Currently, the following variables are accessible in the code:

* `byte`: The current input byte as a `UInt8`
* `p`: The 1-indexed position of `byte` in the buffer
* `p_end`: The length of the input buffer
* `is_eof`: Whether the machine has reached the end of the input.
* `cs`: The current state of the machine, as an integer
* `data`: The input buffer
* `mem`: The memory being read from, an `Automa.SizedMemory` object containing a pointer and a length

The actions we want executed, we place in a `Dict{Symbol, Expr}`:
```julia
actions = Dict(
    :mark_pos => :(pos = p),
    :header => :(header = String(data[pos:p-1])),
    :seqline => :(append!(buffer, data[pos:p-1])),
    :record => :(push!(seqs, Seq(header, String(buffer))))
)
```

For multi-line `Expr`, you can construct them with `quote ... end` blocks.

We can now construct a function that parses our data.
In the code written in the action dict above, besides the variables defined for us by Automa,
we also refer to the variables `buffer`, `header`, `pos` and `seqs`.
Some of these variables are defined in the code above (for example, in the `:(pos = p)` expression),
but we can't necessarily control the order in which Automa will insert these expressions into out final function.
Hence, let's initialize these variables at the top of the function we generate, such that we know for sure they are defined when used - whenever they are used.

The code itself is generated using `generate_code`:

```julia
@eval function parse_fasta(data)
    pos = 0
    buffer = UInt8[]
    seqs = Seq[]
    header = ""

    $(generate_code(machine, actions))

    return seqs
end
```

We can now use it:
```julia
julia> parse_fasta(">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG\n")
2-element Vector{Seq}:
 Seq("abc", "TAGAAAGA")
 Seq("header", "AAAGGGCG")
```

If we give out function a bad input - for example, if we forget the trailing newline, it throws an error:

```julia
julia> parse_fasta(">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG")
ERROR: Error during FSM execution at buffer position 33.
Last 32 bytes were:

">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG"

Observed input: EOF at state 5. Outgoing edges:
 * '\n'/seqline
 * [ACGT]

Input is not in any outgoing edge, and machine therefore errored.
```

The code above parses with about 300 MB/s on my laptop.
Not bad, but Automa can do better - read on to learn how to customize codegen.