function norm_ast(a::Any)
    if isa(a, Expr)
        for (i, arg) in enumerate(a.args)
            a.args[i] = norm_ast(arg)
        end
        if a.head === :line
            return Expr(:line, a.args[1], :none)
        end
        if a.head === :macrocall
            fa = a.args[1]
            long_enough = length(a.args) >= 3
            if fa === Symbol("@int128_str") && long_enough
                return Base.parse(Int128, a.args[3])
            elseif fa === Symbol("@uint128_str") && long_enough
                return Base.parse(UInt128, a.args[3])
            elseif fa === Symbol("@bigint_str") && long_enough
                return  Base.parse(BigInt, a.args[3])
            elseif fa == Symbol("@big_str") && long_enough
                s = a.args[3]
                n = tryparse(BigInt, s)
                if !(n === nothing)
                    return (n)
                end
                n = tryparse(BigFloat, s)
                if !(n === nothing)
                    return isnan((n)) ? :NaN : (n)
                end
                return s
            end
        elseif length(a.args) >= 2 && Meta.isexpr(a, :call) && a.args[1] == :- && isa(a.args[2], Number)
            return -a.args[2]
        end
        return a
    elseif isa(a, QuoteNode)
        return Expr(:quote, norm_ast(a.value))
    elseif isa(a, AbstractFloat) && isnan(a)
        return :NaN
    end
    return a
end

function meta_parse_file(str)
    pos = 1
    x1 = Expr(:file)
    try
        while pos <= sizeof(str)
            x, pos = Meta.parse(str, pos)
            push!(x1.args, x)
        end
    catch er
        isa(er, InterruptException) && rethrow(er)

        return x1, true
    end
    if length(x1.args) > 0  && x1.args[end] === nothing
        pop!(x1.args)
    end
    x1 = norm_ast(x1)
    CSTParser.remlineinfo!(x1)
    return x1, false
end

function cst_parse_file(str)
    x, ps = CSTParser.parse(CSTParser.ParseState(str), true)
    sp = CSTParser.check_span(x)
    # remove leading/trailing nothings
    if length(x.args) > 0 && CSTParser.is_nothing(x.args[1])
        popfirst!(x.args)
    end

    if !isempty(sp)
        @error "CST spans inconsistent!"
    end

    x0 = norm_ast(Expr(x))
    x0, CSTParser.has_error(ps) || !isempty(sp)
end

@testset "Parsing files in Base" begin
    dir = joinpath(Sys.BINDIR, Base.DATAROOTDIR)
    for (root, _, files) in walkdir(dir)
        for fpath in files
            file = joinpath(root, fpath)
            endswith(file, ".jl") || continue

            str = read(file, String)

            cst_expr, cst_err = cst_parse_file(str)
            meta_expr, meta_err = meta_parse_file(str)
            @test cst_err == meta_err
            if cst_err || meta_err
                if cst_err && !meta_err
                    @error "CSTParser.parse errored, but Meta.parse didn't." file=file
                elseif !cst_err && meta_err
                    @error "Meta.parse errored, but CSTParser.parse didn't." file=file
                end
            else
                if cst_expr == meta_expr
                    @test true
                else
                    @error "parsing difference" file=file
                    c0, c1 = CSTParser.compare(cst_expr, meta_expr)
                    printstyled(c0, bold = true, color = :light_red)
                    println()
                    printstyled(c1, bold=true, color=:light_green)
                    println()
                    @test false
                end
            end
        end
    end
end
