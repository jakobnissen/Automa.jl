# Text validators
The simplest use of Automa is to simply match a regex.
It's unlikely you are going to want to use Automa for this instead of Julia's built-in regex engine PCRE, unless you need the extra performance that Automa brings over PCRE.
Nonetheless, it serves as a good starting point to introduce Automa.

Suppose we have the FASTA regex from the regex page:

```julia
fasta_regex = let
    header = re"[a-z]+"
    seqline = re"[ACGT]+"
    record = '>' * header * '\n' * rep1(seqline * '\n')
    rep(record)
end
```

In order to create code, the regex must first be compiled to a `Machine`, which is a struct that represents an optimised DFA.
We can do that with `compile(regex)`.
Under the hood, this compiles the regex to an NFA, then compiles the NFA to a DFA, and then optimises the DFA to a `Machine`.

Normally, we don't care about the regex directly, but only want the `Machine`.
So, it is idiomatic to compile the regex in the same `let` statement it is being built in:

```julia
machine = let
    header = re"[a-z]+"
    seqline = re"[ACGT]+"
    record = re">" * header * '\n' * rep1(seqline * '\n')
    compile(rep(record))
end
```

Note that, if this code is placed at top level in a package, the regex will be constructed and compiled to a `Machine` during package precompilation, which greatly helps load times.

## Buffer validator
Automa comes with a convenience function `generate_buffer_validator`:

```@docs
Automa.generate_buffer_validator
```

Given the `Machine`, we can therefore do

```julia
julia> eval(generate_buffer_validator(:validate_fasta, machine));
```

And we now have a function that checks if some data matches the regex:
```julia
julia> validate_fasta(">hello\nTAGAGA\nTAGAG") # missing trailing newline
0

julia> validate_fasta(">helloXXX") # Error at byte index 7
7

julia> validate_fasta(">hello\nTAGAGA\nTAGAG\n") # nothing; it matches
```

## IO validators
For large files, having to read the data into a buffer to validate it may not be possible.
When the package `TranscodingStreams` is loaded, Automa also supports creating IO validators with the `generate_io_validator` function:

```@docs
Automa.generate_io_validator
```

This works very similar to `generate_buffer_validator`, but the generated function takes an `IO`, and has a different return value:
* If the data matches, still return `nothing`
* Else, return (byte, (line, column)) where byte is the first errant byte, and (line, column) the position of the byte. If the errant byte is a newline, column is 0. If the input reaches unexpected EOF, byte is `nothing`, and (line, column) points to the last line/column in the IO:

```julia
julia> eval(generate_io_validator(:validate_io, machine));

julia> validate_io(">hello\nTAGAGA\n")

julia> validate_io(">helX")
(0x58, (1, 5))

julia> validate_io(">hello\n\n")
(0x0a, (3, 0))

julia> validate_io(">hello\nAC")
(nothing, (2, 2))
```

Computing the column effectively requires buffering at least one line of the input.
If you want to validate files with large lines such that buffering one line will take too much memory, set `report_col` to `false`, in which case the return value will be (byte, line).

## Reference
```@docs
Automa.compile
```