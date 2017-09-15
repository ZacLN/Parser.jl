import Tokenize.Lexers: peekchar, readchar, iswhitespace, emit, emit_error,  accept_batch, eof

const EmptyWS = Tokens.EMPTY_WS
const SemiColonWS = Tokens.SEMICOLON_WS
const NewLineWS = Tokens.NEWLINE_WS
const WS = Tokens.WS
const InvisibleBrackets = Tokens.INVISIBLE_BRACKETS
const EmptyWSToken = Token(EmptyWS, (0, 0), (0, 0), -1, -1, "")

"""
    Closer
Struct holding information on the tokens that will close the expression
currently being parsed.
"""
mutable struct Closer
    toplevel::Bool
    newline::Bool
    semicolon::Bool
    tuple::Bool
    comma::Bool
    dot::Bool
    paren::Bool
    quotemode::Bool
    brace::Bool
    inmacro::Bool
    insquare::Bool
    inwhere::Bool
    square::Bool
    block::Bool
    ifelse::Bool
    ifop::Bool
    range::Bool
    trycatch::Bool
    ws::Bool
    wsop::Bool
    precedence::Int
    stop::Int
end
Closer() = Closer(true, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, -1, typemax(Int))

"""
    ParseState

The parser's interface with `Tokenize.Lexers.Lexer`. This alters the output of `tokenize` in three ways:
+ Merging of whitespace, comments and semicolons;
+ Skips DOT tokens where they are followed by another operator and marks the trailing operator as dotted.
+ Keeps track of the previous, current and next tokens.
"""
mutable struct ParseState
    l::Lexer{Base.AbstractIOBuffer{Array{UInt8, 1}},Tokenize.Tokens.Token}
    done::Bool
    lt::Token
    t::Token
    nt::Token
    nnt::Token
    lws::Token
    ws::Token
    nws::Token
    nnws::Token
    dot::Bool
    ndot::Bool
    diagnostics::Vector{Diagnostics.Diagnostic}
    closer::Closer
    error_code::Diagnostics.ErrorCodes
    errored::Bool
end
function ParseState(str::Union{IO,String})
    ps = ParseState(tokenize(str), false, Token(), Token(), Token(), Token(), Token(), Token(), Token(), Token(), true, true, Diagnostics.Diagnostic[], Closer(), Diagnostics.ParseFailure, false)
    return next(next(ps))
end

function Base.show(io::IO, ps::ParseState)
    println(io, "ParseState $(ps.done ? "finished " : "")at $(position(ps.l.io))")
    println(io, "last    : ", ps.lt.kind, " ($(ps.lt))", "    ($(wstype(ps.lws)))")
    println(io, "current : ", ps.t.kind, " ($(ps.t))", "    ($(wstype(ps.ws)))")
    println(io, "next    : ", ps.nt.kind, " ($(ps.nt))", "    ($(wstype(ps.nws)))")
end
peekchar(ps::ParseState) = peekchar(ps.l)
wstype(t::Token) = t.kind == EmptyWS ? "empty" :
                   t.kind == NewLineWS ? "ws w/ newline" :
                   t.kind == SemiColonWS ? "ws w/ semicolon" : "ws"

function next(ps::ParseState)
    #  shift old tokens
    ps.lt = ps.t
    ps.t = ps.nt
    ps.nt = ps.nnt
    ps.lws = ps.ws
    ps.ws = ps.nws
    ps.nws = ps.nnws
    ps.dot = ps.ndot


    ps.nnt, ps.done  = next(ps.l, ps.done)
    # Handle dotted operators
    if ps.nt.kind == Tokens.DOT && ps.nws.kind == EmptyWS && isoperator(ps.nnt) && !non_dotted_op(ps.nnt)
        # ps.nt = ps.nnt
        ps.nt = Token(ps.nnt.kind, (ps.nnt.startpos[1], ps.nnt.startpos[2] - 1), ps.nnt.endpos, ps.nnt.startbyte - 1, ps.nnt.endbyte, ps.nnt.val)
        ps.ndot = true
        # combines whitespace, comments and semicolons
        if iswhitespace(peekchar(ps.l)) || peekchar(ps.l) == '#' || peekchar(ps.l) == ';'
            ps.nws = lex_ws_comment(ps.l, readchar(ps.l))
        else
            ps.nws = Token(EmptyWS, (0, 0), (0, 0), ps.nnt.endbyte, ps.nnt.endbyte, "")
        end
        ps.nnt, _ = next(ps.l, ps.done)
    else
        ps.ndot = false
    end
    # combines whitespace, comments and semicolons
    if iswhitespace(peekchar(ps.l)) || peekchar(ps.l) == '#' || peekchar(ps.l) == ';'
        ps.nnws = lex_ws_comment(ps.l, readchar(ps.l))
    else
        ps.nnws = EmptyWSToken
    end
    ps.done = ps.nt.kind == Tokens.ENDMARKER
    return ps
end


"""
    lex_ws_comment(l::Lexer, c)

Having hit an initial whitespace/comment/semicolon continues collecting similar
`Chars` until they end. Returns a WS token with an indication of newlines/ semicolons. Indicating a semicolons takes precedence over line breaks as the former is equivalent to the former in most cases.
"""
function lex_ws_comment(l::Lexer, c::Char)
    newline = c == '\n'
    semicolon = c == ';'
    if c == '#'
        newline = read_comment(l)
    else
        newline, semicolon = read_ws(l, newline, semicolon)
    end
    while iswhitespace(peekchar(l)) || peekchar(l) == '#' || peekchar(l) == ';'
        c = readchar(l)
        if c == '#'
            read_comment(l)
            newline = newline || peekchar(l) == '\n'
            semicolon = semicolon || peekchar(l) == ';'
        elseif c == ';'
            semicolon = true
        else
            newline, semicolon = read_ws(l, newline, semicolon)
        end
    end

    return emit(l, semicolon ? SemiColonWS :
                   newline ? NewLineWS : WS)
end



function read_ws(l::Lexer, newline, semicolon)
    while iswhitespace(peekchar(l))
        c = readchar(l)
        c == '\n' && (newline = true)
        c == ';' && (semicolon = true)
    end
    return newline, semicolon
end

function read_comment(l::Lexer)
    if peekchar(l) != '='
        while true
            pc = peekchar(l)
            if pc == '\n' || eof(pc)
                return true
            end
            readchar(l)
        end
    else
        c = readchar(l) # consume the '='
        n_start, n_end = 1, 0
        while true
            if eof(c)
                return false
            end
            nc = readchar(l)
            if c == '#' && nc == '='
                n_start += 1
            elseif c == '=' && nc == '#'
                n_end += 1
            end
            if n_start == n_end
                return true
            end
            c = nc
        end
    end
end

isemptyws(t::Token) = t.kind == EmptyWS
