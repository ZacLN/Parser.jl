parse_kw(ps::ParseState, ::Type{Val{Tokens.IMPORT}}) = parse_imports(ps)
parse_kw(ps::ParseState, ::Type{Val{Tokens.IMPORTALL}}) = parse_imports(ps)
parse_kw(ps::ParseState, ::Type{Val{Tokens.USING}}) = parse_imports(ps)

parse_kw(ps::ParseState, ::Type{Val{Tokens.MODULE}}) = parse_module(ps)
parse_kw(ps::ParseState, ::Type{Val{Tokens.BAREMODULE}}) = parse_module(ps)

function parse_module(ps::ParseState)
    # Parsing
    kw = INSTANCE(ps)
    if ps.nt.kind == Tokens.IDENTIFIER
        next(ps)
        arg = INSTANCE(ps)
    else
        @catcherror ps arg = @precedence ps 15 @closer ps block @closer ps ws parse_expression(ps)
    end

    block = EXPR{Block}(Any[])
    @default ps while ps.nt.kind !== Tokens.END
        @catcherror ps a = @closer ps block parse_doc(ps)
        push!(block, a)
    end

    # Construction
    next(ps)
    ret = EXPR{(kw isa KEYWORD{Tokens.MODULE} ? ModuleH : BareModule)}(Any[kw, arg, block, INSTANCE(ps)])
    return ret
end

function parse_dot_mod(ps::ParseState, is_colon = false)
    args = Any[]

    while ps.nt.kind == Tokens.DOT || ps.nt.kind == Tokens.DDOT || ps.nt.kind == Tokens.DDDOT
        next(ps)
        d = INSTANCE(ps)
        if d isa OPERATOR{Tokens.DOT,false}
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
        elseif d isa OPERATOR{Tokens.DDOT,false}
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
        elseif d isa OPERATOR{Tokens.DDDOT,false}
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
            push!(args, OPERATOR{Tokens.DOT,false}(1, 1:1))
        end
    end

    # import/export ..
    if ps.nt.kind == Tokens.COMMA || ps.ws.kind == NewLineWS || ps.nt.kind == Tokens.ENDMARKER
        if length(args) == 2
            return Any[INSTANCE(ps)]
        end
    end

    while true
        if ps.nt.kind == Tokens.AT_SIGN
            next(ps)
            at = INSTANCE(ps)
            next(ps)
            a = INSTANCE(ps)
            push!(args, EXPR{MacroName}(Any[at, a]))
        elseif ps.nt.kind == Tokens.LPAREN
            next(ps)
            a = EXPR{InvisBrackets}(Any[INSTANCE(ps)])
            @catcherror ps push!(a, @default ps @closer ps paren parse_expression(ps))
            next(ps)
            push!(a, INSTANCE(ps))
            push!(args, a)
        elseif ps.nt.kind == Tokens.EX_OR
            @catcherror ps a = @closer ps comma parse_expression(ps)
            push!(args, a)
        elseif !is_colon && isoperator(ps.nt) && ps.ndot
            next(ps)
            push!(args, OPERATOR{ps.t.kind,false}(ps.nt.startbyte - ps.t.startbyte - 1, 1 + (0:ps.t.endbyte - ps.t.startbyte)))
        else
            next(ps)
            push!(args, INSTANCE(ps))
        end

        if ps.nt.kind == Tokens.DOT
            next(ps)
            push!(args, INSTANCE(ps))
        elseif isoperator(ps.nt) && ps.ndot
            push!(args, PUNCTUATION{Tokens.DOT}(1, 1:1))
        else
            break
        end
    end
    args
end


function parse_imports(ps::ParseState)
    kw = INSTANCE(ps)
    kwt = kw isa KEYWORD{Tokens.IMPORT} ? Import :
          kw isa KEYWORD{Tokens.IMPORTALL} ? ImportAll :
          Using
    tk = ps.t.kind

    arg = parse_dot_mod(ps)

    if ps.nt.kind != Tokens.COMMA && ps.nt.kind != Tokens.COLON
        ret = EXPR{kwt}(vcat(kw, arg))
    elseif ps.nt.kind == Tokens.COLON

        ret = EXPR{kwt}(vcat(kw, arg))
        t = 0

        next(ps)
        push!(ret, INSTANCE(ps))

        @catcherror ps arg = parse_dot_mod(ps, true)
        append!(ret, arg)
        while ps.nt.kind == Tokens.COMMA
            next(ps)
            push!(ret, INSTANCE(ps))
            @catcherror ps arg = parse_dot_mod(ps, true)
            append!(ret, arg)
        end
    else
        ret = EXPR{kwt}(vcat(kw, arg))
        while ps.nt.kind == Tokens.COMMA
            next(ps)
            push!(ret, INSTANCE(ps))
            @catcherror ps arg = parse_dot_mod(ps)
            append!(ret, arg)
        end
    end

    return ret
end

function parse_kw(ps::ParseState, ::Type{Val{Tokens.EXPORT}})
    # Parsing
    kw = INSTANCE(ps)
    ret = EXPR{Export}(vcat(kw, parse_dot_mod(ps)))

    while ps.nt.kind == Tokens.COMMA
        next(ps)
        push!(ret, INSTANCE(ps))
        @catcherror ps arg = parse_dot_mod(ps)[1]
        push!(ret, arg)
    end

    return ret
end



