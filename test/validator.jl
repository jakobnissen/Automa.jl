module Validator

import Automa
import Automa.RegExp: @re_str
using TranscodingStreams: NoopStream
using Test

@testset "Validator" begin
    machine = let
        Automa.compile(re"a(bc)*|(def)|x+" | re"def" | re"x+")
    end
    eval(Automa.generate_validator_function(:foobar, machine, false))
    eval(Automa.generate_validator_function(:barfoo, machine, true))

    eval(Automa.generate_io_validator(:io_bar, machine, false))
    eval(Automa.generate_io_validator(:io_foo, machine, true))

    for good_data in [
        "def"
        "abc"
        "abcbcbcbcbc"
        "x"
        "xxxxxx"
    ]
        @test foobar(good_data) ===
            barfoo(good_data) ===
            io_foo(IOBuffer(good_data)) ===
            io_bar(IOBuffer(good_data)) ===
            io_bar(NoopStream(IOBuffer(good_data))) ===
            nothing
    end

    for bad_data in [
        "",
        "abcabc",
        "abcbb",
        "abcbcb",
        "defdef",
        "xabc"
    ]
        @test foobar(bad_data) ===
            barfoo(bad_data) ===
            io_foo(IOBuffer(bad_data)) ===
            io_bar(IOBuffer(bad_data)) ===
            io_bar(NoopStream(IOBuffer(bad_data))) !==
            nothing
    end
end

end # module