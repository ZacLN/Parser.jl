function parse_kw(ps::ParseState, ::Type{Val{Tokens.FUNCTION}})
    startbyte = ps.t.startbyte
    start_col = ps.t.startpos[2] + 4

    # Parsing
    kw = INSTANCE(ps)
    format_kw(ps)
    # signature

    if isoperator(ps.nt.kind) && ps.nt.kind != Tokens.EX_OR && ps.nnt.kind == Tokens.LPAREN
        start1 = ps.nt.startbyte
        next(ps)
        op = OPERATOR(ps)
        next(ps)
        if issyntaxunarycall(op)
            sig = EXPR{UnarySyntaxOpCall}(EXPR[op, INSTANCE(ps)], 0, Variable[], "")
        else
            sig = EXPR{Call}(EXPR[op, INSTANCE(ps)], 0, Variable[], "")
        end
        @catcherror ps startbyte @default ps @closer ps paren parse_comma_sep(ps, sig)
        next(ps)
        push!(sig.args, INSTANCE(ps))
        sig.span = ps.nt.startbyte - start1
        @default ps @closer ps inwhere @closer ps ws @closer ps block while !closer(ps)
            @catcherror ps startbyte sig = parse_compound(ps, sig)
        end
    else
        @catcherror ps startbyte sig = @default ps @closer ps inwhere @closer ps block @closer ps ws parse_expression(ps)
    end
    
    while ps.nt.kind == Tokens.WHERE
        @catcherror ps startbyte sig = @default ps @closer ps inwhere @closer ps block @closer ps ws parse_compound(ps, sig)
    end

    if sig isa EXPR{InvisBrackets} && !(sig.args[2] isa EXPR{TupleH})
        sig = EXPR{TupleH}(sig.args, sig.span, Variable[], "")
    end

    _get_sig_defs!(sig)

    block = EXPR{Block}(EXPR[], 0, Variable[], "")
    @catcherror ps startbyte @default ps @scope ps Scope{Tokens.FUNCTION} parse_block(ps, block, start_col)
    

    # Construction
    if isempty(block.args)
        if sig isa EXPR{Call} || sig isa EXPR{BinarySyntaxOpCall} && !(sig.args[1] isa EXPR{OPERATOR{PlusOp,Tokens.EX_OR,false}})
            args = EXPR[sig, block]
        else
            args = EXPR[sig]
        end
    else
        args = EXPR[sig, block]
    end
    
    next(ps)
    
    ret = EXPR{FunctionDef}(EXPR[kw], ps.nt.startbyte - startbyte, Variable[], "")
    for a in args
        push!(ret.args, a)
    end
    push!(ret.args, INSTANCE(ps))

    ret.defs = [Variable(Expr(_get_fname(sig)), :Function, ret)]
    return ret
end

"""
    parse_call(ps, ret)

Parses a function call. Expects to start before the opening parentheses and is passed the expression declaring the function name, `ret`.
"""
function parse_call(ps::ParseState, ret::EXPR{OPERATOR{PlusOp,Tokens.EX_OR,false}})
    startbyte = ps.t.startbyte
    arg = @precedence ps 20 parse_expression(ps)
    ret = EXPR{UnarySyntaxOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    return ret
end
function parse_call(ps::ParseState, ret::EXPR{OPERATOR{DeclarationOp,Tokens.DECLARATION,false}})
    startbyte = ps.t.startbyte
    arg = @precedence ps 20 parse_expression(ps)
    ret = EXPR{UnarySyntaxOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    return ret
end
function parse_call(ps::ParseState, ret::EXPR{OP}) where OP <: OPERATOR{TimesOp,Tokens.AND}
    startbyte = ps.t.startbyte
    arg = @precedence ps 20 parse_expression(ps)
    ret = EXPR{UnarySyntaxOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    return ret
end
function parse_call(ps::ParseState, ret::EXPR{OPERATOR{ComparisonOp,Tokens.ISSUBTYPE,false}})
    startbyte = ps.t.startbyte
    arg = @precedence ps 13 parse_expression(ps)
    ret = EXPR{Call}(EXPR[ret; arg.args], ret.span + arg.span, Variable[], "")
    return ret
end

function parse_call(ps::ParseState, ret::EXPR{OPERATOR{ComparisonOp,Tokens.ISSUPERTYPE,false}})
    startbyte = ps.t.startbyte
    arg = @precedence ps 13 parse_expression(ps)
    ret = EXPR{Call}(EXPR[ret; arg.args], ret.span + arg.span, Variable[], "")
    return ret
end

function parse_call(ps::ParseState, ret::EXPR{OP}) where OP <: OPERATOR{20,Tokens.NOT}
    startbyte = ps.t.startbyte
    arg = @precedence ps 13 parse_expression(ps)
    if arg isa EXPR{TupleH}
        ret = EXPR{Call}(EXPR[ret; arg.args], ret.span + arg.span, Variable[], "")
    else
        ret = EXPR{UnaryOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    end
    return ret
end

function parse_call(ps::ParseState, ret::EXPR{OP}) where OP <: OPERATOR{PlusOp,Tokens.PLUS}
    startbyte = ps.t.startbyte
    arg = @precedence ps 13 parse_expression(ps)
    if arg isa EXPR{TupleH}
        ret = EXPR{Call}(EXPR[ret; arg.args], ret.span + arg.span, Variable[], "")
    else
        ret = EXPR{UnaryOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    end
    return ret
end

function parse_call(ps::ParseState, ret::EXPR{OP}) where OP <: OPERATOR{PlusOp,Tokens.MINUS}
    startbyte = ps.t.startbyte
    arg = @precedence ps 13 parse_expression(ps)
    if arg isa EXPR{TupleH}
        ret = EXPR{Call}(EXPR[ret; arg.args], ret.span + arg.span, Variable[], "")
    else
        ret = EXPR{UnaryOpCall}(EXPR[ret, arg], ret.span + arg.span, Variable[], "")
    end
    return ret
end

function parse_call(ps::ParseState, ret)
    startbyte = ps.t.startbyte
    
    next(ps)
    ret = EXPR{Call}(EXPR[ret, INSTANCE(ps)], ret.span - ps.t.startbyte, Variable[], "")
    format_lbracket(ps)
    @default ps @closer ps paren parse_comma_sep(ps, ret)
    next(ps)
    push!(ret.args, INSTANCE(ps))
    format_rbracket(ps)
    ret.span += ps.nt.startbyte
    
    # if length(ret.args) > 0 && ismacro(ret.args[1])
    #     ret.head = MACROCALL
    # end
    # if ret.head isa HEAD{Tokens.CCALL} && length(ret.args) > 1 && ret.args[2] isa IDENTIFIER && (ret.args[2].val == :stdcall || ret.args[2].val == :fastcall || ret.args[2].val == :cdecl || ret.args[2].val == :thiscall)
    #     arg = splice!(ret.args, 2)
    #     push!(ret.args, EXPR(arg, [], arg.span))
    # end

    return ret
end


function parse_comma_sep(ps::ParseState, ret::EXPR, kw = true, block = false, formatcomma = true)
    startbyte = ps.nt.startbyte

    @catcherror ps startbyte @nocloser ps inwhere @noscope ps @nocloser ps newline @closer ps comma while !closer(ps)
        block && (ps.trackscope = true)
        a = parse_expression(ps)

        if kw && !ps.closer.brace && a isa EXPR{BinarySyntaxOpCall} && a.args[2] isa EXPR{OPERATOR{AssignmentOp,Tokens.EQ,false}}
            a = EXPR{Kw}(a.args, a.span, Variable[], "")
            # remove format message for kw args
            if !isempty(ps.diagnostics) && ps.nt.startbyte - a.args[3].span - a.args[2].span <= last(last(ps.diagnostics).loc) <= ps.nt.startbyte - a.args[3].span
                pop!(ps.diagnostics)
            end
        end
        push!(ret.args, a)
        if ps.nt.kind == Tokens.COMMA
            next(ps)
            push!(ret.args, INSTANCE(ps))
            if formatcomma
                format_comma(ps)
            else
                format_no_rws(ps)
            end
        end
        if ps.ws.kind == SemiColonWS
            break
        end
    end


    if ps.ws.kind == SemiColonWS
        if block
            body = EXPR{Block}(EXPR[pop!(ret.args)], 0, Variable[], "")
            body.span = body.args[1].span
            # if last(body.args) isa EXPR{BinarySyntaxOpCall} && last(body.args).args[2] isa EXPR{OP} where OP <: OPERATOR{AssignmentOp,Tokens.EQ}
            #     _track_assignment(ps, last(body.args).args[1], last(body.args).args[3], last(body.args).defs)
            # end
            @nocloser ps newline @closer ps comma while @nocloser ps semicolon !closer(ps)
                @catcherror ps startbyte a = parse_expression(ps)
                push!(body.args, a)
                body.span += a.span
            end
            push!(ret.args, body)
            return body
        else
            ps.nt.kind == Tokens.RPAREN && return 
            paras = EXPR{Parameters}(EXPR[], -ps.nt.startbyte, Variable[], "")
            @nocloser ps inwhere @nocloser ps newline @nocloser ps semicolon @closer ps comma while !closer(ps)
                @catcherror ps startbyte a = parse_expression(ps)
                if kw && !ps.closer.brace && a isa EXPR{BinarySyntaxOpCall} && a.args[2] isa EXPR{OPERATOR{AssignmentOp,Tokens.EQ,false}}
                    a = EXPR{Kw}(a.args, a.span, Variable[], "")
                    # remove format message for kw args
                    if !isempty(ps.diagnostics) && ps.nt.startbyte - a.args[3].span - a.args[2].span <= last(last(ps.diagnostics).loc) <= ps.nt.startbyte - a.args[3].span
                        pop!(ps.diagnostics)
                    end
                end
                push!(paras.args, a)
                if ps.nt.kind == Tokens.COMMA
                    next(ps)
                    push!(paras.args, INSTANCE(ps))
                    format_comma(ps)
                end
            end
            paras.span += ps.nt.startbyte
            push!(ret.args, paras)
        end
    end
end


function _get_sig_defs!(sig1)
    params = _get_fparams(sig1)
    sig1.defs = Variable[Variable(p, :DataType, sig1) for p in params]
    
    sig = sig1
    while sig isa EXPR{BinarySyntaxOpCall} && (sig.args[2] isa EXPR{OPERATOR{DeclarationOp,Tokens.DECLARATION,false}} || sig.args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}})
        if sig.args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}}
            haswhere = true
        end
        sig = sig.args[1]
    end
    
    # Add variable def for struct call overloads
    fname = _get_fname(sig)
    if fname isa EXPR{InvisBrackets} && fname.args[2] isa EXPR{BinarySyntaxOpCall} && fname.args[2].args[2] isa EXPR{OPERATOR{DeclarationOp,Tokens.DECLARATION,false}}
        push!(sig1.defs, Variable(get_id(fname.args[2]).val, get_t(fname.args[2]), sig1))
    end

    for i = 2:length(sig.args)
        arg = sig.args[i]
        if arg isa EXPR{Parameters}
            for arg1 in arg.args
                a = _arg_id(arg1)
                !(a isa EXPR{IDENTIFIER}) && continue
                t = get_t(arg1)
                push!(sig1.defs, Variable(Symbol(a.val), t, sig1))
            end
        elseif !(arg isa EXPR{P} where P <: PUNCTUATION)
            a = _arg_id(arg)
            !(a isa EXPR{IDENTIFIER}) && continue
            t = get_t(arg)
            push!(sig1.defs, Variable(Symbol(a.val), t, sig1))
        end
    end
end

# NEEDS FIX
_arg_id(x) = x
_arg_id(x::EXPR{IDENTIFIER}) = x
_arg_id(x::EXPR{Quotenode}) = x.val
_arg_id(x::EXPR{Curly}) = _arg_id(x.args[1])
_arg_id(x::EXPR{Kw}) = _arg_id(x.args[1])


function _arg_id(x::EXPR{UnarySyntaxOpCall})
    if x.args[2] isa EXPR{OPERATOR{7,Tokens.DDDOT,false}}
        return _arg_id(x.args[1])
    else
        return x
    end
end

function _arg_id(x::EXPR{BinarySyntaxOpCall})
    if x.args[2] isa EXPR{OPERATOR{DeclarationOp,Tokens.DECLARATION,false}} || x.args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}}
        return _arg_id(x.args[1])
    else
        return x
    end
end


_get_fparams(x::EXPR, args = Symbol[]) = args

function _get_fparams(x::EXPR{Call}, args = Symbol[])
    if x.args[1] isa EXPR{Curly}
       _get_fparams(x.args[1], args)
    end
    unique(args)
end

function _get_fparams(x::EXPR{Curly}, args = Symbol[])
    for i = 3:length(x.args)
        a = x.args[i]
        if !(a isa EXPR{P} where P <: PUNCTUATION)
            if a isa EXPR{IDENTIFIER}
                push!(args, Expr(a))
            elseif a isa EXPR{BinarySyntaxOpCall} && a.args[2] isa EXPR{OPERATOR{ComparisonOp,Tokens.ISSUBTYPE,false}}
                push!(args, Expr(a).args[1])
            end
        end
    end 
    unique(args)
end

function _get_fparams(x::EXPR{BinarySyntaxOpCall}, args = Symbol[])
    if x.args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}}
        if x.args[1] isa EXPR{BinarySyntaxOpCall} && x.args[1].args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}}
            _get_fparams(x.args[1], args)
        end
        for i = 3:length(x.args)
            a = x.args[i]
            if !(a isa EXPR{P} where P <: PUNCTUATION)
                if a isa EXPR{IDENTIFIER}
                    push!(args, Expr(a))
                elseif a isa EXPR{BinarySyntaxOpCall} && a.args[2] isa EXPR{OPERATOR{ComparisonOp,Tokens.ISSUBTYPE,false}}
                    push!(args, Expr(a).args[1])
                end
            end
        end
    end
    return unique(args)
end


_get_fname(sig::EXPR{FunctionDef}) = _get_fname(sig.args[2])
_get_fname(sig::EXPR{IDENTIFIER}) = sig
_get_fname(sig::EXPR{Tuple}) = NOTHING
function _get_fname(sig::EXPR{BinarySyntaxOpCall}) 
    if sig.args[2] isa EXPR{OPERATOR{DeclarationOp,Tokens.DECLARATION,false}} || sig.args[2] isa EXPR{OPERATOR{WhereOp,Tokens.WHERE,false}}
        return _get_fname(sig.args[1])
    else
        return get_id(sig.args[1])
    end
end
_get_fname(sig) = get_id(sig.args[1])

_get_fsig(fdecl::EXPR{FunctionDef}) = fdecl.args[2]
_get_fsig(fdecl::EXPR{BinarySyntaxOpCall}) = fdecl.args[1]


declares_function(x) = false
declares_function(x::EXPR{FunctionDef}) = true
declares_function(x::EXPR{BinarySyntaxOpCall}) = x.args[2] isa EXPR{OPERATOR{AssignmentOp,Tokens.EQ,false}} && x.args[1] isa EXPR{Call}
