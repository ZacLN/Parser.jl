function parse_kw(ps::ParseState, ::Type{Val{Tokens.FOR}})
    # Parsing
    kw = INSTANCE(ps)
    @catcherror ps ranges = @default ps parse_ranges(ps)
    block = EXPR{Block}(Any[])
    @catcherror ps @default ps parse_block(ps, block)
    next(ps)
    ret = EXPR{For}(Any[kw, ranges, block, INSTANCE(ps)])

    return ret
end


function parse_ranges(ps::ParseState)
    arg = @closer ps range @closer ps ws parse_expression(ps)
    if ps.nt.kind == Tokens.COMMA
        arg = EXPR{Block}(Any[arg])
        while ps.nt.kind == Tokens.COMMA
            next(ps)
            push!(arg, INSTANCE(ps))

            @catcherror ps nextarg = @closer ps comma @closer ps ws parse_expression(ps)
            push!(arg, nextarg)
        end
    end
    return arg
end



function parse_kw(ps::ParseState, ::Type{Val{Tokens.WHILE}})
    # Parsing
    kw = INSTANCE(ps)
    @catcherror ps cond = @default ps @closer ps ws parse_expression(ps)
    block = EXPR{Block}(Any[])
    @catcherror ps @default ps parse_block(ps, block)
    next(ps)

    ret = EXPR{While}(Any[kw, cond, block, INSTANCE(ps)])

    return ret
end

function parse_kw(ps::ParseState, ::Type{Val{Tokens.BREAK}})
    return INSTANCE(ps)
end

function parse_kw(ps::ParseState, ::Type{Val{Tokens.CONTINUE}})
    return INSTANCE(ps)
end


"""
parse_generator(ps)

Having hit `for` not at the beginning of an expression return a generator.
Comprehensions are parsed as SQUAREs containing a generator.
"""
function parse_generator(ps::ParseState, ret)
    next(ps)
    kw = INSTANCE(ps)
    ret = EXPR{Generator}(Any[ret, kw])
    @catcherror ps ranges = @closer ps paren @closer ps square parse_ranges(ps)

    if ps.nt.kind == Tokens.IF
        if ranges isa EXPR{Block}
            ranges = EXPR{Filter}(Any[ranges.args...])
        else
            ranges = EXPR{Filter}(Any[ranges])
        end
        next(ps)
        unshift!(ranges, INSTANCE(ps))
        @catcherror ps cond = @closer ps range @closer ps paren parse_expression(ps)
        unshift!(ranges, cond)
        push!(ret, ranges)
    else
        if ranges isa EXPR{Block}
            append!(ret, ranges)
        else
            push!(ret, ranges)
        end
    end

    # This should reverse order of iterators
    if ret.args[1] isa EXPR{Generator} || ret.args[1] isa EXPR{Flatten}
        ret = EXPR{Flatten}(Any[ret])
    end

    return ret
end
