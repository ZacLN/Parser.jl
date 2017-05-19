function parse_kw(ps::ParseState, ::Type{Val{Tokens.QUOTE}})
    startbyte = ps.t.startbyte
    start_col = ps.t.startpos[2] + 4

    # Parsing
    kw = INSTANCE(ps)
    format_kw(ps)
    @catcherror ps startbyte arg = @default ps parse_block(ps, start_col)
    next(ps)

    # Construction
    ret = EXPR(Quote, SyntaxNode[kw, arg, INSTANCE(ps)], ps.nt.startbyte - startbyte)
    
    return ret
end
