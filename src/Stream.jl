"""
Streaming Interface of Automa.jl.

NOTE: This module is still experimental. The behavior may change without
deprecations.
"""
module Stream

import Automa
import TranscodingStreams: TranscodingStream, NoopStream

"""
    @relpos(pos)

Get the relative position of the absolute position `pos`.
"""
macro relpos(pos)
    esc(:(@assert buffer.markpos > 0; $(pos) - buffer.markpos + 1))
end

"""
    @abspos(pos)

Get the absolute position of the relative position `pos`.
""" 
macro abspos(pos)
    esc(:(@assert buffer.markpos > 0; $(pos) + buffer.markpos - 1))
end

"""
    generate_reader(funcname::Symbol, machine::Automa.Machine; kwargs...)

Generate a streaming reader function of the name `funcname` from `machine`.

The generated function consumes data from a stream passed as the first argument
and executes the machine with filling the data buffer.

This function returns an expression object of the generated function.  The user
need to evaluate it in a module in which the generated function is needed.

# Keyword Arguments
- `arguments`: Additional arguments `funcname` will take (default: `()`).
    The default signature of the generated function is `(stream::TranscodingStream,)`,
    but it is possible to supply more arguments to the signature with this keyword argument.
- `context`: Automa's codegenerator (default: `Automa.CodeGenContext()`).
- `actions`: A dictionary of action code (default: `Dict{Symbol,Expr}()`).
- `initcode`: Initialization code (default: `:()`).
- `loopcode`: Loop code (default: `:()`).
- `returncode`: Return code (default: `:(return cs)`).
- `errorcode`: Executed if `cs < 0` after `loopcode` (default error message)

See the source code of this function to see how the generated code looks like
```
"""
function generate_reader(
        funcname::Symbol,
        machine::Automa.Machine;
        arguments=(),
        context::Automa.CodeGenContext=Automa.DefaultCodeGenContext,
        actions::Dict{Symbol,Expr}=Dict{Symbol,Expr}(),
        initcode::Expr=:(),
        loopcode::Expr=:(),
        returncode::Expr=:(return $(context.vars.cs)),
        errorcode::Expr=Automa.generate_input_error_code(context, machine)
)
    # Add a `return` to the return expression if the user forgot it
    if returncode.head != :return
        returncode = Expr(:return, returncode)
    end
    # Create the function signature
    functioncode = :(function $(funcname)(stream::$(TranscodingStream)) end)
    for arg in arguments
        push!(functioncode.args[1].args, arg)
    end
    vars = context.vars
    functioncode.args[2] = quote
        $(vars.buffer) = stream.state.buffer1
        $(vars.data) = $(vars.buffer).data
        $(Automa.generate_init_code(context, machine))
        $(initcode)
        # Overwrite is_eof for Stream, since we don't know the real EOF
        # until after we've actually seen the stream eof
        $(vars.is_eof) = false

        # Code between __exec__ and the bottom is repeated in a loop,
        # in order to continuously read data, filling in new data to the buffer
        # once it runs out.
        # When the buffer is filled, data in the buffer may shift, which necessitates
        # us updating `p` and `p_end`.
        # Hence, they need to be redefined here.
        @label __exec__
        # The eof call here is what refills the buffer, if the buffer is used up,
        # eof will try refilling the buffer before returning true
        $(vars.is_eof) = eof(stream)
        $(vars.p) = $(vars.buffer).bufferpos
        $(vars.p_end) = $(vars.buffer).marginpos - 1
        $(Automa.generate_exec_code(context, machine, actions))
        
        # Advance the buffer, hence advancing the stream itself
        $(vars.buffer).bufferpos = $(vars.p)

        $(loopcode)

        if $(vars.cs) < 0
            $(errorcode)
        end

        # If the machine errored, or we're past the end of the stream, actually return.
        # Else, keep looping.
        if $(vars.cs) == 0 || ($(vars.is_eof) && $(vars.p) > $(vars.p_end))
            @label __return__
            $(returncode)
        end
        @goto __exec__
    end
    return functioncode
end

"""
    generate_io_validator(funcname::Symbol, machine::Machine, goto::Bool=false)

Create code that, when evaluated, defines a function named `funcname`.
This function takes an `IO`, and checks if the data in the input conforms
to the regex in `machine`, without executing any actions.
If the input conforms, return `nothing`. If the input reaches EOF prematurely, return `0`.
Else, return the 1-based `(line, col)` of the first invalid byte.
Note that sometimes the column cannot be determined, and will return be set to 0.
"""
function generate_io_validator(funcname::Symbol, machine::Automa.Machine, goto::Bool=false)
    ctx = if goto
        Automa.CodeGenContext(generator=:goto)
    else
        Automa.DefaultCodeGenContext
    end
    vars = ctx.vars
    loopcode = quote
        # This is actually surprisingly slow (about 6 GB/s)
        # Still, I guess it's OK for most people
        @inbounds for i in 1:$(vars.p)
            line_num += $(vars.mem)[i] == UInt8('\n')
        end
    end
    returncode = quote
        return if iszero(cs)
            nothing
        elseif $(vars.p) > $(vars.p_end)
            0
        else
            # We only bother looking in the current buffer in order
            # to determine the column. It's possible the last newline was
            # lost from the buffer, in which case we return 0 (as documented).
            # Fixing this case will slow down runtime too much.
            line_num -= $(vars.byte) == UInt8('\n')
            col = 0
            @inbounds for i in $(vars.p)-1:-1:1
                col += 1
                mem[i] == UInt8('\n') && break
            end
            (line_num, col)
        end
    end
    empty_actions = Dict{Symbol,Expr}(a => quote nothing end for a in Automa.machine_names(machine))
    function_code = generate_reader(
        funcname,
        machine;
        context=ctx,
        actions=empty_actions,
        initcode=:(line_num = 1),
        loopcode=loopcode,
        returncode=returncode,
        errorcode=:(@goto __return__),
    )
    return quote
        """
            $($(funcname))(io::IO)::Union{Int, Nothing}

        Checks if the data in `io` conforms to the given `Automa.Machine`.
        Returns `nothing` if it does, else the byte index of the first invalid byte.
        If the machine reached unexpected EOF, returns `0`.
        """
        $function_code

        $(funcname)(io::$(IO)) = $(funcname)($(NoopStream)(io))
    end 
end

end  # module
