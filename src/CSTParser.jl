__precompile__()
module CSTParser
global debug = true

using AbstractTrees
using Tokenize
import Base: next, start, done, length, first, last, endof, getindex, setindex!
import Tokenize.Tokens
import Tokenize.Tokens: Token, iskeyword, isliteral, isoperator
import Tokenize.Lexers: Lexer, peekchar, iswhitespace

export ParseState, parse_expression

include("hints.jl")
import .Diagnostics: Diagnostic, LintCodes

include("lexer.jl")
include("errors.jl")
include("spec.jl")
include("utils.jl")
include("components/lists.jl")
include("components/operators.jl")
include("components/controlflow.jl")
include("components/functions.jl")
include("components/genericblocks.jl")
include("components/loops.jl")
include("components/macros.jl")
include("components/modules.jl")
include("components/prefixkw.jl")
include("components/strings.jl")
include("components/types.jl")
include("conversion.jl")
include("display.jl")
include("scoping.jl")


"""
    parse_expression(ps)

Parses an expression until `closer(ps) == true`. Expects to enter the
`ParseState` the token before the the beginning of the expression and ends
on the last token.

Acceptable starting tokens are:
+ A keyword
+ An opening parentheses or brace.
+ An operator.
+ An instance (e.g. identifier, number, etc.)
+ An `@`.

"""
function parse_expression(ps::ParseState)
    next(ps)
    if Tokens.begin_keywords < ps.t.kind < Tokens.end_keywords && ps.t.kind != Tokens.DO
        @catcherror ps ret = parse_kw(ps, Val{ps.t.kind})
    elseif ps.t.kind == Tokens.LPAREN
        @catcherror ps ret = parse_paren(ps)
    elseif ps.t.kind == Tokens.LSQUARE
        @catcherror ps ret = parse_array(ps)
    elseif ps.t.kind == Tokens.LBRACE
        @catcherror ps ret = parse_cell1d(ps)
    elseif isinstance(ps.t) || isoperator(ps.t)
        if ps.t.kind == Tokens.WHERE
            ret = IDENTIFIER(ps)
        else
            ret = INSTANCE(ps)
        end
        if (ret isa OPERATOR{Tokens.COLON,false}) && ps.nt.kind != Tokens.COMMA
            @catcherror ps ret = parse_unary(ps, ret)
        end
    elseif ps.t.kind == Tokens.AT_SIGN
        @catcherror ps ret = parse_macrocall(ps)
################################################################################
# Everything below here is an error
################################################################################
    elseif ps.t.kind in (Tokens.ENDMARKER, Tokens.COMMA, Tokens.RPAREN,
                         Tokens.RBRACE, Tokens.RSQUARE)
        return error_unexpected(ps, ps.t.startbyte, ps.t)
    else
        ps.errored = true
        return EXPR{ERROR}(Any[INSTANCE(ps)])
    end

    while !closer(ps)
        @catcherror ps ret = parse_compound(ps, ret)
    end

    return ret
end


"""
    parse_compound(ps, ret)

Handles cases where an expression - `ret` - is not followed by
`closer(ps) == true`. Possible juxtapositions are:
+ operators
+ `(`, calls
+ `[`, ref
+ `{`, curly
+ `,`, commas
+ `for`, generators
+ `do`
+ strings
+ an expression preceded by a unary operator
+ A number followed by an expression (with no seperating white space)
"""
function parse_compound(ps::ParseState, ret)
    if ps.nt.kind == Tokens.FOR
        ret = parse_generator(ps, ret)
    elseif ps.nt.kind == Tokens.DO
        ret = parse_do(ps, ret)
    elseif isajuxtaposition(ps, ret)
        op = OPERATOR{Tokens.STAR,false}(0, 1:0)
        ret = parse_operator(ps, ret, op)
    elseif ps.nt.kind == Tokens.LPAREN && isemptyws(ps.ws)
        ret = @closer ps paren parse_call(ps, ret)
    elseif ps.nt.kind == Tokens.LBRACE && isemptyws(ps.ws)
        ret = parse_curly(ps, ret)
    elseif ps.nt.kind == Tokens.LSQUARE && isemptyws(ps.ws) && !(ret isa OPERATOR)
        ret = @nocloser ps block parse_ref(ps, ret)
    elseif ps.nt.kind == Tokens.COMMA
        ret = parse_tuple(ps, ret)
    elseif isunaryop(ret) && ps.nt.kind != Tokens.EQ
        ret = parse_unary(ps, ret)
    elseif isoperator(ps.nt)
        next(ps)
        op = INSTANCE(ps)
        ret = parse_operator(ps, ret, op)
    elseif (ret isa IDENTIFIER || ret isa BinarySyntaxOpCall{OPERATOR{Tokens.DOT,false}}) && (ps.nt.kind == Tokens.STRING || ps.nt.kind == Tokens.TRIPLE_STRING)
        next(ps)
        @catcherror ps arg = parse_string_or_cmd(ps, ret)
        ret = EXPR{x_Str}(Any[ret, arg])
    # Suffix on x_str
    elseif ret isa EXPR{x_Str} && ps.nt.kind == Tokens.IDENTIFIER
        next(ps)
        arg = INSTANCE(ps)
        push!(ret, LITERAL{Tokens.STRING}(arg.fullspan, arg.span, ps.t.val))
    elseif (ret isa IDENTIFIER || ret isa BinarySyntaxOpCall{OPERATOR{Tokens.DOT,false}}) && ps.nt.kind == Tokens.CMD
        next(ps)
        @catcherror ps arg = parse_string_or_cmd(ps, ret)
        ret = EXPR{x_Cmd}(Any[ret, arg])
    elseif ret isa EXPR{x_Cmd} && ps.nt.kind == Tokens.IDENTIFIER
        next(ps)
        arg = INSTANCE(ps)
        push!(ret, LITERAL{Tokens.STRING}(arg.fullspan, 1:span(arg), ps.t.val))
    elseif ret isa UnarySyntaxOpCall && ret.arg2 isa OPERATOR{Tokens.PRIME}
        # prime operator followed by an identifier has an implicit multiplication
        @catcherror ps nextarg = @precedence ps 11 parse_expression(ps)
        ret = BinaryOpCall(ret, OPERATOR{Tokens.STAR,false}(0, 1:0), nextarg)
################################################################################
# Everything below here is an error
################################################################################
    elseif ps.nt.kind in (Tokens.ENDMARKER, Tokens.LPAREN, Tokens.RPAREN, Tokens.LBRACE,
                          Tokens.LSQUARE, Tokens.RSQUARE)
        return error_unexpected(ps, ps.nt.startbyte, ps.nt)
    elseif ret isa EXPR{<:OPERATOR}
        ps.errored = true
        push!(ps.diagnostics, Diagnostic{Diagnostics.UnexpectedOperator}(
            # TODO: Which operator? How do we get at the spelling
            0:0, [], "Unexpected operator"
        ))
        return EXPR{ERROR}(Any[INSTANCE(ps)])
    elseif ps.nt.kind == Tokens.IDENTIFIER
        ps.errored = true
        push!(ps.diagnostics, Diagnostic{Diagnostics.UnexpectedIdentifier}(
            ps.nt.startbyte:ps.nt.endbyte, [], "Unexpected identifier"
        ))
        return EXPR{ERROR}(Any[INSTANCE(ps)])
    else
        ps.errored = true
        return EXPR{ERROR}(Any[INSTANCE(ps)])
    end
    if ps.errored
        return EXPR{ERROR}(Any[INSTANCE(ps)])
    end
    return ret
end

"""
    parse_paren(ps, ret)

Parses an expression starting with a `(`.
"""
function parse_paren(ps::ParseState)
    ret = EXPR{TupleH}(Any[INSTANCE(ps)])

    @catcherror ps @default ps @nocloser ps inwhere @closer ps paren parse_comma_sep(ps, ret, false, true)

    if (length(ret.args) == 2 && !(ret.args[2] isa UnarySyntaxOpCall && ret.args[2].arg2 isa OPERATOR{Tokens.DDDOT,false})) || (length(ret.args) == 1 && ret.args[1] isa EXPR{Block})

        if (ps.ws.kind != SemiColonWS || (length(ret.args) == 2 && ret.args[2] isa EXPR{Block})) && !(ret.args[2] isa EXPR{Parameters})
            ret = EXPR{InvisBrackets}(ret.args)
        end
    end

    # handle closing ')'
    next(ps)
    push!(ret, INSTANCE(ps))
    return ret
end

"""
    parse(str, cont = false)

Parses the passed string. If `cont` is true then will continue parsing until the end of the string returning the resulting expressions in a TOPLEVEL block.
"""
function parse(str::String, cont = false)
    ps = ParseState(str)
    x, ps = parse(ps, cont)
    if ps.errored
        x = EXPR{ERROR}(Any[])
    end
    return x
end

function parse_doc(ps::ParseState)
    if ps.nt.kind == Tokens.STRING || ps.nt.kind == Tokens.TRIPLE_STRING
        next(ps)
        doc = INSTANCE(ps)
        if (ps.nt.kind == Tokens.ENDMARKER || ps.nt.kind == Tokens.END)
            return doc
        elseif isbinaryop(ps.nt) && !closer(ps)
            @catcherror ps ret = parse_compound(ps, doc)
            return ret
        end

        ret = parse_expression(ps)
        ret = EXPR{MacroCall}(Any[GlobalRefDOC, doc, ret])
    elseif ps.nt.kind == Tokens.IDENTIFIER && ps.nt.val == "doc" && (ps.nnt.kind == Tokens.STRING || ps.nnt.kind == Tokens.TRIPLE_STRING)
        next(ps)
        doc = INSTANCE(ps)
        next(ps)
        @catcherror ps arg = parse_string_or_cmd(ps, doc)
        doc = EXPR{x_Str}(Any[doc, arg])
        ret = parse_expression(ps)
        ret = EXPR{MacroCall}(Any[GlobalRefDOC, doc, ret])
    else
        ret = parse_expression(ps)
    end
    return ret
end

function parse(ps::ParseState, cont = false)
    if ps.l.io.size == 0
        return (cont ? EXPR{FileH}(Any[]) : nothing), ps
    end
    last_line = 0
    curr_line = 0

    if cont
        top = EXPR{FileH}(Any[])
        if ps.nt.kind == Tokens.WHITESPACE || ps.nt.kind == Tokens.COMMENT
            next(ps)
            push!(top, LITERAL{nothing}(ps.nt.startbyte, 1:ps.nt.startbyte, ""))
        end

        while !ps.done && !ps.errored
            curr_line = ps.nt.startpos[1]
            ret = parse_doc(ps)

            # join semicolon sep items
            if curr_line == last_line && last(top.args) isa EXPR{TopLevel}
                push!(last(top.args), ret)
            elseif ps.ws.kind == SemiColonWS
                push!(top, EXPR{TopLevel}(Any[ret]))
            else
                push!(top, ret)
            end
            last_line = curr_line
        end
    else
        if ps.nt.kind == Tokens.WHITESPACE || ps.nt.kind == Tokens.COMMENT
            next(ps)
            top = LITERAL{nothing}(ps.nt.startbyte, 1:ps.nt.startbyte, "")
        else
            top = parse_doc(ps)
            last_line = ps.nt.startpos[1]
            if ps.ws.kind == SemiColonWS
                top = EXPR{TopLevel}(Any[top])
                while ps.ws.kind == SemiColonWS && ps.nt.startpos[1] == last_line && ps.nt.kind != Tokens.ENDMARKER
                    ret = parse_doc(ps)
                    push!(top, ret)
                    last_line = ps.nt.startpos[1]
                end
            end
        end
    end

    return top, ps
end


function parse_file(path::String)
    x = parse(readstring(path), true)
    File([], [], path, x, [])
    # File([], (f -> (joinpath(dirname(path), f[1]), f[2])).(_get_includes(x)), path, x, [])
end

function parse_directory(path::String, proj = Project(path, []))
    for f in readdir(path)
        if isfile(joinpath(path, f)) && endswith(f, ".jl")
            try
                push!(proj.files, parse_file(joinpath(path, f)))
            catch
                println("$f failed to parse")
            end
        elseif isdir(joinpath(path, f))
            parse_directory(joinpath(path, f), proj)
        end
    end
    proj
end



ischainable(t::Token) = t.kind == Tokens.PLUS || t.kind == Tokens.STAR || t.kind == Tokens.APPROX

# include("_precompile.jl")
# _precompile_()
end
