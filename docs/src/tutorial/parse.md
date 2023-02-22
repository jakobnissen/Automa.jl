## Parsing from a buffer
The next step from validating a regex is to parse data from a byte buffer (e.g. a string, a `Vector{UInt8}` or similar).
Currently, Automa loads data through pointers, and therefore does not read data of types such as `UnitRange{UInt8}`.
Furthermore, be careful about passing strided views to Automa - while Automa can extract a pointer from a strided view, it will always advance the pointer one byte at a time, disregarding the view's stride.

Anyway, we still want to parse our simplified FASTA data. Let's parse it into a `Vector{Seq}`, where `Seq` is defined as:

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
* On "enter", meaning it will be executed when reading the first byte of the regex
* On "final", where it will be executed when reading the last byte of the regex.
  Note that it's not possible to determine the final byte for some regex like `re"X+"`, since
  the machine reads only 1 byte at a time and cannot look ahead.
* On "exit", meaning it will be executed on reading the first byte AFTER the regex, or when exiting the regex by encountering the end of inputs (only for a regex match, not an unexpected end of input)
* On "all", where it will be executed when reading every byte that is part of the regex.

A list of action names it added to a regex at a position like such:

```julia
my_regex = re"ABC"
my_regex.actions[:enter] = [:action_a, :action_b]
my_regex.actions[:exit] = [:action_c]
```

In which case the code named `action_a`, then that named `action_b` will executed in order when entering the regex, and the code named `action_c` will be executed when exiting the regex.

Let's update our `Machine` regex code from the previous tutorial example, this time adding actions.
To parse a simplified FASTA file into a `Vector{Seq}`, I want four actions:

* When the machine enters into the header, or a sequence line, I want it to mark the position with where it entered into the regex. The marked position will be used as the leftmost position where the header or sequence is extracted later
* When exiting the header, I want to extract the bytes from the marked position in the action above, to the last header byte (i.e. the byte before the current byte), and use these bytes as the sequence header
* When exiting a sequence line, I want to do the same: Extract from the marked position to one before the current position, but this time I want to append the current line to a buffer containing all the lines of the sequence
* When exiting a record, I want to construct a `Seq` object from the header bytes and the buffer with all the sequence lines, then push the `Seq` to the result,

```julia
machine = let
    header = re"[a-z]+"
    header.actions[:enter] = [:mark_position]
    header.actions[:exit] = [:header]
    
    seqline = re"[ACGT]+"
    seqline.actions[:enter] = [:mark_position]
    seqline.actions[:exit] = [:seqline]
    
    record = re">" * header * re"\n" * RE.rep1(seqline * re"\n")
    record.actions[:exit] = [:record]
    compile(RE.rep(record))
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

These variables can be renamed at will using the `CodeGenContext` type - we will come back to that later.

The actions we want executed, we place in a `Dict{Symbol, Expr}`:
```julia
actions = Dict{Symbol, Expr}(
    :mark_position => :(pos = p),
    :header => :(header = String(data[pos:p-1])),
    :seqline => :(append!(buffer, data[pos:p-1])),
    :record => quote
        seq = Seq(header, String(buffer))
        push!(seqs, seq)
    end
)
```

We can now construct a function that parses our data.
In the code written in the dict above, besides the variables defined for us by Automa,
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
```
julia> parse_fasta(">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG\n")
2-element Vector{Seq}:
 Seq("abc", "TAGAAAGA")
 Seq("header", "AAAGGGCG")
```

The code above parses with about 300 MB/s on my laptop.
Not bad, but in the next section of the tutorial, we can see how to customize Automa's generated code to, among other things, produce much more efficient code.

If we give out function a bad input - for example, if we forget the trailing newline, it throws an error:
```
julia> parse_fasta(">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG")
ERROR: Error during FSM execution at buffer position 33.
Last 32 bytes were:

">abc\nTAGA\nAAGA\n>header\nAAAG\nGGCG"

Observed input: EOF at state 5. Outgoing edges:
 * '\n'/seqline
 * [ACGT]

Input is not in any outgoing edge, and machine therefore errored.
```

It is possible to customize much more about Automa's generated code - read on to learn more.
