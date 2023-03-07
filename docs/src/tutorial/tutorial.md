# Tutorial to Automa
As much as we, the developers, want to make it easy to use Automa, it remains a difficult package.
The following tutorial will take you through different use cases of Automa in order of increasing complexity.
Although you may want to skip ahead to the problem that most resemble your use case, I recommend reading these in order.

## Matching a regex
The simplest use of Automa is to match a regex.
It's unlikely you are going to want to use Automa for this instead of Julia's built-in regex engine PCRE, unless you need the extra performance that Automa brings over PCRE.
Nonetheless, it serves as a good starting point to introduce Automa's regex.

### Building a regex
Regex are made using the `@re_str` macro, like this: `re"ABC[DEF]"`, similar to the built-in regex macro `r"ABC[DEF]"`.
They support the following content:
* Literal symbols, such as `re"ABC"`, `re"\xfe\xa2"` or `re"Æ"`
* Symbol sets with `[]`, like `re"[ABC]"`. This only works with bytes or ASCII characters.
* `|` for alternation, as in `re"A|B"`
* Repetition, with `X*` meaning zero or more repetitions of X
* `+`, where `X+` means `XX*`, i.e. 1 or more repetitions of X
* `?`, where `X?` means `X | ""`, i.e. 0 or 1 occurrences of X. It applies to the last element of the regex
* Parentheses to group expressions, like in `A(B|C)?`

Regexes support the following operations:
* `*` for concatenation, with `re"A" * re"B"` being the same as `re"AB"`.
  Regex can also be concatenated with `Char`s and `String`s, which will cause the chars/strings to be converted to regex first.
* `|` for alternation, with `re"A" | re"B"` being the same as `re"A|B"`
* `&` for intersection of regex, i.e. for regex `A` and `B`, the set of inputs matching `A & B` is exactly the intersection of the inputs match `A` and those matching `B`.
  As an example, `re"A[AB]C+D?" & re"[ABC]+"` is `re"ABC"`.
* `\` for difference, such that for regex `A` and `B`, `A \ B` creates a new regex matching all those inputs that match `A` but not `B`.
* `!` for inversion, such that `!re"[A-Z]"` matches all other strings than those which match `re"[A-Z]"`.
  Note that `!re"a"` also matches e.g. `"aa"`, since this does not match `re"a"`.

Finally, the funtions `opt`, `rep` and `rep1` is equivalent to the operators `?`, `*` and `+`, so i.e. `opt(re"a" * rep(re"b") * re"c")` is equivalent to `re"(ab*c)?"`.

In this tutorial, let's look at a simplified version of the FASTA format.
The format we will use is the following:

* The format is a series of zero or more _records_, concatenated
* A _record_ consists of the concatenation of:
    - A leading '>'
    - A header, composed of one or more letters in 'a-z',
    - A newline symbol '\n'
    - A series of one or more _sequence lines_
* A _sequence line_ is the concatenation of:
    - One or more symbols from the alphabet [ACGT]
    - A newline

In other words, our format is the following regex:

`(>[a-z]+\n([ACGT]+\n)+)*`

In Automa, we will typically construct this incrementally, like such:

```julia
regex = let
    header = re"[a-z]+"
    seqline = re"[ACGT]+"
    record = '>' * header * '\n' * rep1(seqline * '\n')
    RE.rep(record)
end
```

### Compiling the regex
In order to create code, the regex must first be compiled to a `Machine`, which is a struct that represents an optimised DFA.
We can do that with `compile(regex)`.
Under the hood, this compiles the regex to an NFA, then compiles the NFA to a DFA, and then optimises the DFA to a `Machine`.

Normally, we don't care about the regex directly, but only want the `Machine`.
So, it is idiomatic to constuct the regex in a `let` statement, and so have the following code at top level:

```julia
machine = let
    header = re"[a-z]+"
    seqline = re"[ACGT]+"
    record = re">" * header * re"\n" * RE.rep1(seqline * re"\n")
    compile(RE.rep(record))
end
```

Note that, because this is a top-level expression, the regex will be constructed and compiled to a `Machine` during package precompilation, which greatly helps load times.

### Creating a validator function
Automa comes with a convenience function `generate_validator_function`, which creates an Expr object that evaluates to a function that accepts a byte buffer (that is, something that implements `sizeof` and `pointer`), and checks if the given regex matches.
It returns `nothing` if it matches, else it returns the 1-indexed position of the first byte that was a mismatch.
If the regex fails to match due to an unexpected end of input, it returns `sizeof(input) + 1`.

Given the `Machine`, we can therefore do

```
@eval $(generate_validator_function(:validate_fasta, machine))
```

And we now have a function:

```
julia> validate_fasta(">hello\nTAGAGA\nTAGAG") # missing trailing newline
20

julia> validate_fasta(">hello\nTAGAGA\nTAGAG\n")
```

## Note: Automa is byte-oriented (limited Unicode support)
Even as Julia considers strings to be iterators of `Char`, Automa has only a weak concept of characters.
Instead, its input is always a _byte buffer_, from which it loads a single byte at a time using a pointer.
This has the following consequences:

* In text with multi-byte characters such as `"αβγ"`, every byte is considered an input.
  So, if you set up automa to perform an action for every input in that string, it will execute 6 actions.
* While unicode text is accepted, it is parsed as simply a byte sequence. I.e. `re"α"` is parsed
  equivalently to `re"\xce\xb1"`.
* Sets does not yet support multi-byte characters, i.e. you cannot yet do `re"[αβγ]"` or `re"[α-γ]"`.
  This is because sets are sets of single inputs, i.e. sets of single bytes.
