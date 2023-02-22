# Theory of regular expressions
Most programmers are familiar with _regular expressions_, or _regex_, for short.
What many programmers don't know is that regex have a deep theoretical underpinning, that can be leaned upon to produce highly efficient code.

Informally, a regular expression can be thought of as any pattern that can be constructed from the following atoms:
* The empty string is a valid regular expression, i.e. `re""`
* Literal matching of a single symbol like a character, i.e. `re"p"`

Atoms can be combined with the following operations, if R and P are two regular expressions:
* Alternation, i.e `R | P`, meaning either match R or P.
* Concatenation, i.e. `R * P`, meaning match first R, then P
* Repetition, i.e. `R*`, meaning match R zero or more times consecutively.

Popular regex libraries include more operations like `?` and `+`.
These can trivially be constructed from the above mentioned primitives,
i.e. `R?` is `"" | R`,
and `R+` is `R * R*`.

Some implementations of regular expression engines, such as PCRE which is the default in Julia as of Julia 1.8,
also support operations like backreferences and lookbehind.
These operations can NOT be constructed from the above atoms and axioms, meaning that PCRE expressions are not regular expressions in the theoretical sense.

The practical importance of theoretically sound regular expressions is that there exists algorithms that can match regular expressions on O(N) time and O(1) space,
whereas this is not true for PCRE expressions, which are therefore significantly slower. 

To match regex, the regex are transformed to _finite automata_, which are then implemented in code.

## Nondeterministic finite automata
The programmer Ken Thompson, of Unix fame, deviced _Thompson's construction_, an algorithm to constuct a nondeterministic finite automaton (NFA) from a regex.
An NFA can be thought of as a flowchart (or a directed graph), where one can move from node to node on directed edges.
Edges are either labeled `ϵ`, in which the machine can freely move through the edge to its destination node,
or labeled with one or more input symbols, in which the machine may traverse the edge upon consuming said input.

Maybe an illustration is in order:
The following regex: `r"[+-][0-9][0-9]+"`
Can be converted to the following NFA:

And a string conforms to the regex if, and only if, there is a path through this NFA that matches each symbol of the string in order, and which ends in an _accept state_ - thats the state(s) marked with a double circle.

Node the ϵ-edges, which can be traversed without consuming an input symbol.
The existance of these means that an input may have multiple valid paths through the NFA - that's what makes it nondeterministic.
It is possible to model an NFA in code. When a node A is encountered with ϵ-edges to B, the machine is simply considered to be in both state A and B at the same time.

This, however, adds unwelcome complexity to the implementation and makes it slower.
Luckily, every NFA has an equivalent _determinisitic finite automaton_, which can be constructed from the NFA using the so-called _powerset construction_.

## Deterministic finite automata
Or DFAs, as they are called, are similar to NFAs, but do not contain ϵ-edges.
This means that a given input string has either zero paths (if it does not match the regex), one, unambiguous path, through the DFA.
In other words, every input symbol triggers one unambiguous state transition.

Let's visualize the DFA equivalent to the NFA above:

It might not be obvious, but the DFA above accepts exactly the same inputs as the previous NFA.
DFAs are way simpler to simulate in code than NFAs, precisely because at every state, for every input, there is exactly one action:
DFAs can be simulated either using a lookup table, of possible state transitions,
or by hardcoding GOTO-statements from node to node when the correct input is matched.
Code simulating DFAs can be ridicuously fast, with each state transition taking less than 1 nanosecond, if implemented well.

Unfortunately, as the name "powerset construction" hints, convering an NFA with N nodes has a worst-case complexity of O(2^N).
This inconvenient fact drives important design decisions in regex implementations.
There are basically two approaches:

Automa.jl will just construct the DFA directly, and accept a worst-case complexity of O(2^N).
This is acceptable (I think) for Automa, because this construction happens in Julia's package precompilation stage (not on package loading or usage),
and because the DFAs are assumed to be constants within a package.
So, if a developer accidentally writes an NFA which is unacceptably slow to convert to a DFA, it will be caught in development.
Luckily, it's pretty rare to have NFAs that result in truly abysmally slow conversions to DFA's:
While bad corner cases exist, they are rarely as catastrophic as the O(2^N) would suggest.
Currently, Automa's regex/NFA/DFA compilation pipeline is very slow and unoptimized.

Other implementations, like the popular `ripgrep` command line tool, uses an adaptive approach.
It constructs the DFA on the fly, as each symbol is being matched, and then caches the DFA.
If the DFA size grows too large, the cache is flushed.
If the cache is flushed too often, it falls back to simulating the NFA directly.
Such an approach is necessary for `ripgrep`, because the regex -> NFA -> DFA compilation happens at runtime and must be near-instantaneous, unlike Automa, where it happens during package precompilation and can afford to be slow.

## Actions and preconditions
Automa simulates the DFA by having the DFA create a Julia Expr, which is then used to generate a Julia function using metaprogramming.
Like all other Julia code, this function is then optimized by Julia and then LLVM, making the DFA simulations very fast.

Because Automa just constructs Julia functions, we can do extra tricks that ordinary regex engines cannot:
We can splice arbitrary Julia code into the DFA simulation.
Currently, Automa supports two such kinds of code: _actions_, and _preconditions_.

Actions are Julia code that is executed during certain state transitions.
Preconditions are Julia code, that evaluates to a `Bool` value, and which is checked before a state transition.
If it evaluates to `false`, the transition is not taken.
