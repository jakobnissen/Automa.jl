```@meta
CurrentModule = Automa
DocTestSetup = quote
    using TranscodingStreams
    using Automa
end
```

# Parsing from an IO

!!! note
    Parsing from an IO relies on TranscodingStreams.jl, and the relevant methods are defined in an extension module in Automa.
    If you use Julia 1.9 or later, you must load TranscodingStreams before loading Automa to test this functionality.

Some file types are gigabytes or tens of gigabytes in size.
For these files, parsing from a buffer may be impractical, as they require you to read in the entire file in memory at once.
Automa enables this by hooking into `TranscodingStreams.jl`, a package that provides a wrapper IO of the type `TranscodingStream`.
Importantly, these streams buffer their input data.
Automa is thus able to operate directly on the input buffers of `TranscodingStream` objects.

Unfortunately, this _significantly_ complicates things compared to parsing from a simple buffer.
The main problem is that, when reading from a buffered stream, the byte array visible from `Automa` is only a small slice of the total input data.
Worse, when the end of the stream is reached, data from the buffer is flushed, i.e. removed from the stream.
To handle this, Automa must reach deep into the implementation details of `TranscodingStreams`, and also break some of its own abstractions.
It's not pretty, but it's what we have.

Practically speaking, parsing from IO is done with the function `Automa.generate_reader`.
Despite its name, this function is NOT directly used to generate objects like `FASTA.Reader`.
Instead, this function produces Julia code (an `Expr` object) that, when evaluated, defines a function that can execute an Automa machine on an IO.
Let me first show the code generated by `generate_reader` in pseudocode format:

```
function { function name }(stream::TranscodingStream, { args... })
    { init code }

    @label __exec__

    p = current buffer position
    p_end = final buffer position

    # the eof call below will first flush any used data from buffer,
    # then load in new data, before checking if it's really eof.
    is_eof = eof(stream)
    execute normal automa parsing of the buffer
    update buffer position to match p

    { loop code }

    if cs < 0 # meaning: erroneous input or erroneous EOF
        { error code }
    end

    if machine errored or reached EOF
        @label __return__
        { return code }
    end
    @goto __exec__
end
```

The content marked `{ function name }`, `{ args... }`, `{ init code }`, `{ loop code }`, `{ error code }` and `{ return code }` are arguments provided to `Automa.generate_reader`.
By providing these, the user can customize the generated function further.

The main difference from the code generated to parse a buffer is the label/GOTO pair `__exec__`, which causes Automa to repeatedly load data into the buffer, execute the machine, then flush used data from the buffer, then execute the machine, and so on, until interrupted.

Importantly, when parsing from a buffer, `p` and `p_end` refer to the position _in the current buffer_.
This may not be the position in the stream, and when the data in the buffer is flushed, it may move the data in the buffer so that `p` now become invalid.
This means you can't simply store a variable `marked_pos` that points to the current value of `p` and expect that the same data is at that position later.
Furthermore, `is_eof` is set to whether the stream has reached EOF.

## Example use
Let's show the simplest possible example of such a function.
We have a `Machine` (which, recall, is a compiled regex) called `machine`, and we want to make a function that returns `true` if a given `IO` contain data that conforms to the regex format specified by the `Machine`.

We will still use the machine from before, just without any actions:

```jldoctest io1; output = false
machine = let
    header = re"[a-z]+"
    seqline = re"[ACGT]+"
    record = re">" * header * '\n' * rep1(seqline * '\n')
    compile(rep(record))
end
@assert machine isa Automa.Machine

# output

```

To create our simple IO reader, we simply need to call `generate_reader`, where the `{ return code }` is a check if `iszero(cs)`, meaning if the machine exited at a proper exit state.
We also need to set `error_code` to an empty expression in order to prevent throwing an error on invalid code. Instead, we want it to go immediately to return - we call this section `__return__`, so we need to `@goto __return__`.
Then, we need to evaluate the code created by `generate_reader` in order to define the function `validate_fasta`

```jldoctest io1
julia> return_code = :(iszero(cs));

julia> error_code = :(@goto __return__);

julia> eval(generate_reader(:validate_fasta,  machine; returncode=return_code, errorcode=error_code));
```

The generated function `validate_fasta` has the function signature:
`validate_fasta(stream::TranscodingStream)`.
If our input IO is not a `TranscodingStream`, we can wrap it in the relatively lightweight `NoopStream`, which, as the name suggests, does nothing to the data:

```jldoctest io1
julia> io = NoopStream(IOBuffer(">a\nTAG\nTA\n>bac\nG\n"));

julia> validate_fasta(io)
true

julia> validate_fasta(NoopStream(IOBuffer("random data")))
false
```

## Reading a single record

!!! danger
    The following code is only for demonstration purposes.
    It has several one important flaw, which will be adressed in a later section, so do not copy-paste it for serious work.

There are a few more subtleties related to the `generate_reader` function.
Suppose we instead want to create a function that reads a single FASTA record from an IO.
In this case, it's no good that the function created from `generate_reader` will loop until the IO reaches EOF - we need to find a way to stop it after reading a single record.
We can do this with the pseudomacro `@escape`, as shown below.

We will reuse our `Seq` struct and our `Machine` from the "parsing from a buffer" section of this tutorial:

```jldoctest io2; output = false
struct Seq
    name::String
    seq::String
end

machine = let
    header = onexit!(onenter!(re"[a-z]+", :mark_pos), :header)
    seqline = onexit!(onenter!(re"[ACGT]+", :mark_pos), :seqline)
    record = onexit!(re">" * header * '\n' * rep1(seqline * '\n'), :record)
    compile(rep(record))
end
@assert machine isa Automa.Machine

# output
```

The code below contains `@escape` in the `:record` action - meaning: Break out of machine execution.

```jldoctest io2; output = false
actions = Dict{Symbol, Expr}(
    :mark_pos => :(pos = p),
    :header => :(header = String(data[pos:p-1])),
    :seqline => :(append!(seqbuffer, data[pos:p-1])),

    # Only this action is different from before!
    :record => quote
        seq = Seq(header, String(seqbuffer))
        found_sequence = true
        # Reset p one byte if we're not at the end
        p -= !(is_eof && p > p_end)
        @escape
    end
)
@assert actions isa Dict

# output
```

`@escape` is not actually a real macro, but what Automa calls a "pseudomacro".
It is expanded during Automa's own compiler pass _before_ Julia's lowering.
The `@escape` pseudomacro is replaced with code that breaks it out of the executing machine, without reaching EOF or an invalid byte.

Let's see how I use `generate_reader`, then I will explain each part:

```jldoctest io2; output = false
generate_reader(
    :read_record,
    machine;
    actions=actions,
    initcode=quote
        seqbuffer = UInt8[]
        pos = 0
        found_sequence = false
        header = ""
    end,
    loopcode=quote
        if (is_eof && p > p_end) || found_sequence
            @goto __return__
        end
    end,
    returncode=:(found_sequence ? seq : nothing)
) |> eval

# output
read_record (generic function with 1 method)
```

In the `:record`, action, a few new things happen.
* First, I set the flag `found_sequence = false`.
  In the loop code, I look for this flag to signal that the function should return.
  Remember, the loop code happens after machine execution, which can mean either that the execution was broken out of by `@escape`, or than the buffer ran out and need to be refilled.
  I could just return the sequence directly in the action, but then I would skip a bunch of the code generated by `generate_reader` which sets the buffer state correctly, _so this is never adviced_.
  Instead, in the _loop code_, which executes after the buffer has been flushed, I check for this flag, and goes to `__return__` if necessary.
  I could also just return directly in the loopcode, but I prefer only having one place to retun from the function.
* I use `@escape` to break out of the machine, i.e. stop machine execution
* Finally, I decrement `p`, if and only if the machine has not reached EOF (which happens when `is_eof` is true, meaning the last part of the IO has been buffered, and `p > p_end`, meaning the end of the buffer has been reached).
  This is because, the first record ends when the IO reads the second `>` symbol.
  If I then were to read another record from the same IO, I would have already read the `>` symbol.
  I need to reset `p` by 1, so the `>` is also read on the next call to `read_record`.

I can use the function like this:

```jldoctest io2
julia> io = NoopStream(IOBuffer(">a\nT\n>tag\nGAGA\nTATA\n"));

julia> read_record(io)
Seq("a", "T")

julia> read_record(io)
Seq("tag", "GAGATATA")

julia> read_record(io)
```

## Preserving data by marking the buffer
There are several problems with the implementation above: The following code in my actions dict:

```julia
header = String(data[pos:p-1])
```

Creates `header` by accessing the data buffer.
However, when reading an IO, how can I know that the data hasn't shifted around in the buffer between when I defined `pos`?
For example, suppose we have a short buffer of only 8 bytes, and the following FASTA file: `>abcdefghijkl\nA`.
Then, the buffer is first filled with `>abcdefg`.
When entering the header, I execute the action `:mark_position` at `p = 2`, so `pos = 2`.
But now, when I reach the end of the header, the used data in the buffer has been flushed, and the data is now:
`hijkl\nA`, and `p = 14`.
I then try to access `data[2:13]`, which is out of bounds!

Luckily, the buffers of `TranscodingStreams` allow us to "mark" a position to save it.
The buffer will not flush the marked position, or any position after the marked position.
If necessary, it will resize the buffer to be able to load more data while keeping the marked position.

Inside the function generated by `generate_reader`, we can use the zero-argument pseudomacro `@mark()`, which marks the position `p`.
The macro `@markpos()` can then be used to get the marked position, which will point to the same data in the buffer, even after the data in the buffer has been shifted after it's been flushed.
This works because the mark is stored inside the `TranscodingStream` buffer, and the buffer makes sure to update the mark if the content moves.
Hence, we can re-write the actions:

```julia
actions = Dict{Symbol, Expr}(
    :mark_position => :(@mark),
    :header => :(header = String(data[@markpos():p-1])),
    :seqline => :(append!(buffer, data[@markpos():p-1])),

    [:record action omitted...]
)
```

In our example above with the small 8-byte buffer, this is what would happen:
First, the buffer contains the first 8 bytes.
When `p = 2`, the mark is set, and the second byte is marked::

```
content: >abcdefg
mark:     ^
p = 2     ^
```

Then, when `p = 9` the buffer is exhausted, the used data is removed, BUT, the mark stays, so byte 2 is preserved, and only the first byte is removed.
The code in `generate_reader` loops around to `@label __exec__`, which sets p to the current buffer position.
The buffer now looks like this:

```
content: abcdefgh
mark:    ^
p = 8           ^
```

Only 1 byte was cleared, so when `p = 9`, the buffer will be exhausted again.
This time, no data can be cleared, so instead, the buffer is resized to fit more data:

```
content: abcdefghijkl\nA
mark:    ^
p = 9            ^
```

Finally, when we reach the newline `p = 13`, the whole header is in the buffer, and so `data[@markpos():p-1]` will correctly refer to the header (now, `1:12`).

```
content: abcdefghijkl\nA
mark:    ^
p = 13               ^
```

Remember to update the mark, or to clear it with `@unmark()` in order to be able to flush data from the buffer afterwards.

## Reference
```@docs
Automa.generate_reader
Automa.@escape
Automa.@mark
Automa.@unmark
Automa.@markpos
Automa.@bufferpos
Automa.@relpos
Automa.@abspos
Automa.@setbuffer
```