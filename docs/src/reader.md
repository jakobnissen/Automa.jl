# Creating a `Reader` type
The use of `generate_reader` as we learned in the previous section "Parsing from an io" has two issues we need to address:
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
* I no longer have the code to decrement `p` in the `:record` action - because we can store the Automa state between records such that the machine can handle beginning in the middle of a record if necessary, there is no need to reset the value of `p` in order to restore the IO to the state right before each record.
* I return `(cs, state)` instead of just `state`, because I want to update the Automa state of the Reader, so when it reads the next record, it begins in the same state where the machine left off from the previous state
* In the arguments, I add `start_state`, and in the `initcode` I set `cs` to the start state, so the machine begins from the correct state

```julia
actions = Dict{Symbol, Expr}(
    :mark_pos => :(@mark),
    :header => :(header = String(data[@markpos():p-1])),
    :seqline => :(append!(seqbuffer, data[@markpos():p-1])),
    :record => quote
        seq = Seq(header, String(seqbuffer))
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
        seqbuffer = UInt8[]
        found_sequence = false
        header = ""
        cs = start_state
    end,
    loopcode=quote
        if (is_eof && p > p_end) || found_sequence
            @goto __return__
        end
    end,
    returncode=:(found_sequence ? (cs, seq) : throw(EOFError()))
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