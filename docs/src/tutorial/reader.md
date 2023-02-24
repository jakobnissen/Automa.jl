# Creating a `Reader` type
We're almost at the stage where we can recreate something like a FASTA reader.
The use of `generate_reader` as we learned in the previous section has two issues we need to address:
The first is that, while we were able to read multiple records from the reader by calling `read_record` multiple times, no state was preserved between these calls, and so, no state can be preserved between reading individual records.

Imagine you have a format with two kinds of records, A and B types.
Hence, while a B record can appear at any time, once you've seen a B record, there can'y be any more A records.
A records must come before B records in the file.
When reading records from the file, you must be able to store whether you've seen a B record.

We address this by creating a `Reader` type which wraps the IO being parsed, and which store any state we want to preserve between records.
Let's stick to our simplified FASTA format - see previous sections for the format definition and the `Machine` we generated:

```julia
mutable struct Reader{S <: TranscodingStream}
    io::S
    automa_state::Int
end

Reader(io::TranscodingStream) = Reader{typeof(io)}(io, 1)
Reader(io::IO) = Reader(NoopStream(io))
```

The `Reader` contains an instance of `TranscodingStream` to read from, and stores the Automa state between records.
The beginning state of Automa is always 1.
We can now create our reader function like this:
There are only three differences from the definitions in the previous section:
* I no longer have `p -= 1` in the `:record` action - because we can store the Automa state between records such that the machine can handle beginning in the middle of a record if necessary, there is no need to reset the value of `p` in order to restore the IO to the state right before each record.
* I return `(cs, state)` instead of just `state`, because I want to update the Automa state of the Reader, so when it reads the next record, it begins in the same state where the machine left off from the previous state
* In the arguments, I add `start_state`, and in the `initcode` I set `cs` to the start state, so the machine begins from the correct state

```julia
actions = Dict{Symbol, Expr}(
    :mark_position => :(@mark),
    :header => :(header = String(data[@markpos():p-1])),
    :seqline => :(append!(buffer, data[@markpos():p-1])),
    :record => quote
        seq = Seq(header, String(buffer))
        found_sequence = true
        @escape
    end
)

generate_reader(
    :read_record,
    machine;
    actions=actions,
    arguments=(:(start_state::Int),),
    initcode=quote
        buffer = UInt8[]
        found_sequence = false
        header = ""
        cs = start_state
        local seq
    end,
    loopcode=quote
        found_sequence && @goto __return__
    end,
    returncode=quote
        if cs < 0
            error("Malformed FASTA file")
        elseif found_sequence
            return (cs, seq)
        else
            throw(EOFError())
        end
    end
) |> eval
```

We then create a function that reads from the `Reader`, making sure to update the `automa_state` of the reader:

```julia
function read_record(reader::Reader)
    (cs, seq) = read_record(reader.io, reader.automa_state)
    reader.automa_state = cs
    return seq
end
```

Let's test it out:

```julia
julia> read_record(reader)
Seq("a", "T")

julia> read_record(reader)
Seq("tag", "GAGATATA")

julia> read_record(reader)
ERROR: EOFError: read end of file
```

## Using multiple `Machine`s for one `Reader`
For very complicated formats, it can get unwieldy to have to express the format with a single gigantic regex and a single `Machine`.
Because `generate_reader` simply creates a function that operates on a `TranscodingStream`, if you can break the format down into multiple sub-formats, you can use a machine for each.
In our example, suppose our sequence formats was so complex that we needed a machine for it specifically.
We could then first create a function that parsed the sequence itself:


```julia
sequence_machine = let
    line = re"[ACGT]+"
    line.actions[:enter] = [:mark]
    line.actions[:exit] = [:line]
    next_seq_start = re">"
    next_seq_start.actions[:enter] = [:gentle_exit]

    sequence = RE.rep1(line * re"\n") * RE.opt(next_seq_start)
    Automa.compile(sequence)
end

sequence_actions = Dict{Symbol, Expr}(
    :mark => :(@mark),
    :line => :(append!(buffer, data[@markpos():p-1])),
    :gentle_exit => quote
        # Set cs to 0 to signal accept state (machine did not error
        # and is done), and rewind p by 1 to not consume '>' byte.
        # Under normal circumstances, @escape will advance the buffer
        # 1 byte in order to prepare for the next byte
        cs = 0
        p -= 1
        @escape
    end
)

generate_reader(
    :parse_sequence,
    sequence_machine;
    actions=sequence_actions,
    returncode=quote
        return iszero(cs) ? String(buffer) : error("Malformed sequence")
    end,
    initcode=:(buffer = UInt8[]),
) |> eval
```

We can then test the generated `parse_sequence` function independently.
When we're satisfied it works, we can then use the function in our main parser, e.g.:

```julia
fasta_machine = let
    header = re"[a-z]+"
    header.actions[:enter] = [:mark]
    header.actions[:exit] = [:header]
    sequence_enter = re"\n"
    sequence_enter.actions[:enter] = [:read_sequence]
    compile(RE.rep(re">" * header * sequence_enter))
end

fasta_actions = Dict{Symbol, Expr}(
    :mark => :(@mark),
    :header => :(header = String(data[@markpos():p-1])),
    :read_sequence => quote
        # Set buffer to where it should begin reading
        # inside parse_sequence
        buffer.bufferpos = p + 1
        seq = Seq(header, parse_sequence(stream))
        # Set p to where the buffer ended up.
        # prevent p from advancing 1 for next iteration
        p = buffer.bufferpos - 1
        found_record = true
        @escape
    end
)

generate_reader(
    :read_record,
    fasta_machine;
    arguments=(:(start_state::Int),),
    initcode=quote
        header = ""
        found_record = false
        cs = start_state
        local seq
    end,
    actions=fasta_actions,
    loopcode=:(found_record && @goto __return__),
    returncode=quote
        if found_record
            return (cs, seq)
        else
            throw(EOFError())
        end
    end
) |> eval
```




```