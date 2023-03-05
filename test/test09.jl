module Test09

using Automa
using Test

@testset "Test09" begin
    make_tokenizer(:tokenize, [
        :a  => re"a",
        :ab => re"a*b",
        :cd => re"cd"
    ]) |> eval

    @test tokenize("") == []
    @test tokenize("a") == [(1, 1, 1)]
    @test tokenize("b") == [(1, 1, 2)]
    
    @test tokenize("aa") == [(1,1,1), (2,1,1)]
    @test tokenize("ab") == [(1,2,2)]
    @test tokenize("aaa") == [(1,1,1), (2,1,1), (3,1,1)]
    @test tokenize("aab") == [(1,3,2)]
    @test tokenize("abaabba") == [(1,2,2), (3,3,2), (6,1,2), (7,1,1)]
    @test_throws ErrorException tokenize("c")
    @test_throws ErrorException tokenize("ac")
    @test_throws ErrorException tokenize("abc")
    @test_throws ErrorException tokenize("acb")
end

#=
@testset "Test09" begin
    tokenizer = Automa.compile(
        [re"a"      => :(emit(:a, ts:te)),
        re"a*b"    => :(emit(:ab, ts:te)),
        re"cd"    => :(emit(:cd, ts:te))]
    )
    ctx = Automa.CodeGenContext()

    @eval function tokenize(data)
        $(Automa.generate_init_code(ctx, tokenizer))
        tokens = Tuple{Symbol,String}[]
        emit(kind, range) = push!(tokens, (kind, data[range]))
        while p ≤ p_end && cs > 0
            $(Automa.generate_exec_code(ctx, tokenizer))
        end
        if cs < 0
            error()
        end
        return tokens
    end

    @test tokenize("") == []
    @test tokenize("a") == [(:a, "a")]
    @test tokenize("b") == [(:ab, "b")]
    @test tokenize("aa") == [(:a, "a"), (:a, "a")]
    @test tokenize("ab") == [(:ab, "ab")]
    @test tokenize("aaa") == [(:a, "a"), (:a, "a"), (:a, "a")]
    @test tokenize("aab") == [(:ab, "aab")]
    @test tokenize("abaabba") == [(:ab, "ab"), (:ab, "aab"), (:ab, "b"), (:a, "a")]
    @test_throws ErrorException tokenize("c")
    @test_throws ErrorException tokenize("ac")
    @test_throws ErrorException tokenize("abc")
    @test_throws ErrorException tokenize("acb")
end
=#
end
