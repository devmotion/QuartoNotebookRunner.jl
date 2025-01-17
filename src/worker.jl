const IOCaptureExpr = let file = joinpath(Base.pkgdir(IOCapture), "src", "IOCapture.jl")
    Meta.parseall(read(file, String); filename = file)
end

function worker_init(f::File)
    quote
        ### Start LOAD_PATH manipulations.
        try
            pushfirst!(LOAD_PATH, "@stdlib")

            import Pkg
            import REPL

            # Avoids needing to have to manually vendor the IOCapture.jl source,
            # since it's not apparently possible to send the `Module` object over
            # the wire from the server to the worker.
            $(IOCaptureExpr)
        finally
            popfirst!(LOAD_PATH)
        end
        ### End LOAD_PATH manipulations.

        const PROJECT = Base.active_project()
        const WORKSPACE = Ref(Module(:Notebook))
        const FRONTMATTER = Ref($(default_frontmatter()))

        # Interface:

        function refresh!(frontmatter = FRONTMATTER[])
            # Current directory should always start out as the directory of the
            # notebook file, which is not necessarily right initially if the parent
            # process was started from a different directory to the notebook.
            cd($(dirname(f.path)))

            # Reset back to the original project environment if it happens to
            # have changed during cell evaluation.
            PROJECT == Base.active_project() || Pkg.activate(PROJECT; io = devnull)

            # Attempt to clear up as much of the previous workspace as possible
            # by setting all the variables to `nothing`. This is a bit of a
            # hack, but since if a `Function` gets defined in a `Module` then it
            # gets rooted in the global MethodTable and stops the `Module` from
            # being GC'd, apparently. This should cover most use-cases, e.g. a
            # user creates a massive array in a cell, and then reruns it
            # numerous times. So long as it isn't a `const` we should be able to
            # clear it to `nothing` and GC the actual data.
            mod = WORKSPACE[]
            for name in names(mod; all = true)
                if isdefined(mod, name) && !Base.isdeprecated(mod, name)
                    try
                        Base.setproperty!(mod, name, nothing)
                    catch error
                        @debug "failed to undefine:" name error
                    end
                end
            end
            # Force GC to run to try and clean up the variables that are now set
            # to `nothing`.
            GC.gc()

            # Replace the module with a new one, so that redefinition of consts
            # works between notebook runs.
            WORKSPACE[] = Module(nameof(mod))

            # Ensure that `Pkg` is always available in the notebook so that users
            # can immediately activate a project environment if they want to.
            Core.eval(WORKSPACE[], :(import Main: Pkg, ojs_define))

            # Rerun the package loading hooks if the frontmatter has changed.
            if FRONTMATTER[] != frontmatter
                FRONTMATTER[] = frontmatter
                for (pkgid, hook) in PACKAGE_LOADING_HOOKS
                    if haskey(Base.loaded_modules, pkgid)
                        hook()
                    end
                end
            else
                FRONTMATTER[] = frontmatter
            end

            return nothing
        end

        function render(code::AbstractString, file::AbstractString, line::Integer)
            captured =
                Base.@invokelatest include_str(WORKSPACE[], code; file = file, line = line)
            results = Base.@invokelatest render_mimetypes(captured.value)
            return (;
                results,
                output = captured.output,
                error = captured.error ? string(typeof(captured.value)) : nothing,
                backtrace = collect(
                    eachline(
                        IOBuffer(
                            clean_bt_str(
                                captured.error,
                                captured.backtrace,
                                captured.value,
                            ),
                        ),
                    ),
                ),
            )
        end

        # Utilities:

        if VERSION >= v"1.8"
            function _parseall(text::AbstractString; filename = "none", lineno = 1)
                Meta.parseall(text; filename, lineno)
            end
        else
            function _parseall(text::AbstractString; filename = "none", lineno = 1)
                ex = Meta.parseall(text, filename = filename)
                _walk(x -> _fixline(x, lineno), ex)
                return ex
            end
            function _walk(f, ex::Expr)
                for (nth, x) in enumerate(ex.args)
                    ex.args[nth] = _walk(f, x)
                end
                return ex
            end
            _walk(f, @nospecialize(other)) = f(other)

            _fixline(x, line) =
                x isa LineNumberNode ? LineNumberNode(x.line + line - 1, x.file) : x
        end

        function include_str(
            mod::Module,
            code::AbstractString;
            file::AbstractString,
            line::Integer,
        )
            loc = LineNumberNode(line, Symbol(file))
            try
                ast = _parseall(code, filename = file, lineno = line)
                @assert Meta.isexpr(ast, :toplevel)
                # Note: IO capturing combines stdout and stderr into a single
                # `.output`, but Jupyter notebook spec appears to want them
                # separate. Revisit this if it causes issues.
                return IOCapture.capture(; rethrow = InterruptException, color = true) do
                    result = nothing
                    line_and_ex = Expr(:toplevel, loc, nothing)
                    for ex in ast.args
                        if ex isa LineNumberNode
                            loc = ex
                            line_and_ex.args[1] = ex
                            continue
                        end
                        # Wrap things to be eval'd in a :toplevel expr to carry line
                        # information as part of the expr.
                        line_and_ex.args[2] = ex
                        for transform in REPL.repl_ast_transforms
                            line_and_ex = transform(line_and_ex)
                        end
                        result = Core.eval(mod, line_and_ex)
                    end
                    return result
                end
            catch err
                if err isa Base.Meta.ParseError
                    return (;
                        result = err,
                        output = "",
                        error = true,
                        backtrace = catch_backtrace(),
                    )
                else
                    rethrow(err)
                end
            end
        end

        # passing our module removes Main.Notebook noise when printing types etc.
        with_context(io::IO) = IOContext(io, :module => WORKSPACE[], :color => true)

        function clean_bt_str(is_error::Bool, bt, err, prefix = "", mimetype = false)
            is_error || return UInt8[]

            # Only include the first encountered `top-level scope` in the
            # backtrace, since that's the actual notebook code. The rest is just
            # the worker code.
            bt = Base.scrub_repl_backtrace(bt)
            top_level = findfirst(x -> x.func === Symbol("top-level scope"), bt)
            bt = bt[1:something(top_level, length(bt))]

            if mimetype
                non_worker = findfirst(x -> contains(String(x.file), @__FILE__), bt)
                bt = bt[1:max(something(non_worker, length(bt)) - 3, 0)]
            end

            buf = IOBuffer()
            buf_context = with_context(buf)
            print(buf_context, prefix)
            Base.showerror(buf_context, err)
            Base.show_backtrace(buf_context, bt)

            return take!(buf)
        end

        function render_mimetypes(value)
            result = Dict{String,@NamedTuple{error::Bool, data::Vector{UInt8}}}()
            mimes = [
                "text/plain",
                "text/html",
                "text/latex",
                "image/svg+xml",
                "image/png",
                "application/json",
            ]
            for mime in mimes
                if showable(mime, value)
                    buffer = IOBuffer()
                    try
                        Base.@invokelatest show(with_context(buffer), mime, value)
                    catch error
                        backtrace = catch_backtrace()
                        result[mime] = (;
                            error = true,
                            data = clean_bt_str(
                                true,
                                backtrace,
                                error,
                                "Error showing value of type $(typeof(value))\n",
                                true,
                            ),
                        )
                        continue
                    end
                    # Only send back the bytes, we do the processing of the
                    # data on the parent process where we have access to
                    # whatever packages we need, e.g. working out the size
                    # of a PNG image or converting a JSON string to an
                    # actual JSON object that avoids double serializing it
                    # in the notebook output.
                    result[mime] = (; error = false, data = take!(buffer))
                end
            end
            return result
        end
        render_mimetypes(value::Nothing) =
            Dict{String,@NamedTuple{error::Bool, data::Vector{UInt8}}}()

        # Integrations:

        function ojs_define(; kwargs...)
            json_id = Base.PkgId(Base.UUID("682c06a0-de6a-54ab-a142-c8b1cf79cde6"), "JSON")
            dataframes_id =
                Base.PkgId(Base.UUID("a93c6f00-e57d-5684-b7b6-d8193f3e46c0"), "DataFrames")
            tables_id =
                Base.PkgId(Base.UUID("5d742f6a-9f54-50ce-8119-136d35baa42b"), "Tables")

            if haskey(Base.loaded_modules, json_id)
                JSON = Base.loaded_modules[json_id]
                contents =
                    if haskey(Base.loaded_modules, dataframes_id) &&
                       haskey(Base.loaded_modules, tables_id)
                        DataFrames = Base.loaded_modules[dataframes_id]
                        Tables = Base.loaded_modules[tables_id]
                        conv(x) = isa(x, DataFrames.AbstractDataFrame) ? Tables.rows(x) : x
                        [Dict("name" => k, "value" => conv(v)) for (k, v) in kwargs]
                    else
                        [Dict("name" => k, "value" => v) for (k, v) in kwargs]
                    end
                json = JSON.json(Dict("contents" => contents))
                return HTML("<script type='ojs-define'>$(json)</script>")
            else
                @warn "JSON package not available. Please install the JSON.jl package to use ojs_define."
                return nothing
            end
        end

        function _frontmatter()
            fm = FRONTMATTER[]

            fig_width = fm["fig-width"]
            fig_height = fm["fig-height"]
            fig_format = fm["fig-format"]
            fig_dpi = fm["fig-dpi"]

            if fig_format == "retina"
                fig_format = "svg"
            elseif fig_format == "pdf"
                fig_dpi = 96
            end

            # convert inches to pixels
            fig_width = fig_width * fig_dpi
            fig_height = fig_height * fig_dpi

            return (; fig_width, fig_height, fig_format, fig_dpi)
        end

        const PKG_VERSIONS = Dict{Base.PkgId,VersionNumber}()
        function _pkg_version(pkgid::Base.PkgId)
            # Cache the package versions since once a version of a package is
            # loaded we don't really support loading a different version of it,
            # so we can just cache the version number.
            if haskey(PKG_VERSIONS, pkgid)
                return PKG_VERSIONS[pkgid]
            else
                deps = Pkg.dependencies()
                if haskey(deps, pkgid.uuid)
                    return PKG_VERSIONS[pkgid] = deps[pkgid.uuid].version
                else
                    return nothing
                end
            end
        end

        function _CairoMakie_hook(pkgid::Base.PkgId, CairoMakie::Module)
            fm = _frontmatter()
            if fm.fig_format == "pdf"
                CairoMakie.activate!(; type = "png")
            else
                CairoMakie.activate!(; type = fm.fig_format)
            end
        end
        _CairoMakie_hook(::Any...) = nothing

        function _Makie_hook(pkgid::Base.PkgId, Makie::Module)
            fm = _frontmatter()
            if _pkg_version(pkgid) < v"0.20"
                Makie.update_theme!(; resolution = (fm.fig_width, fm.fig_height))
            else
                Makie.update_theme!(; size = (fm.fig_width, fm.fig_height))
            end
        end
        _Makie_hook(::Any...) = nothing

        function _Plots_hook(pkgid::Base.PkgId, Plots::Module)
            fm = _frontmatter()
            if (_pkg_version(pkgid) < v"1.28.1") && (fm.fig_format == "pdf")
                Plots.gr(size = (fm.fig_width, fm.fig_height), fmt = :png, dpi = fm.fig_dpi)
            else
                Plots.gr(
                    size = (fm.fig_width, fm.fig_height),
                    fmt = fm.fig_format,
                    dpi = fm.fig_dpi,
                )
            end
            return nothing
        end
        _Plots_hook(::Any...) = nothing

        const PACKAGE_LOADING_HOOKS = Dict{Base.PkgId,Function}()
        if isdefined(Base, :package_callbacks)
            let
                function package_loading_hook!(f::Function, name::String, uuid::String)
                    pkgid = Base.PkgId(Base.UUID(uuid), name)
                    PACKAGE_LOADING_HOOKS[pkgid] = function ()
                        mod = get(Base.loaded_modules, pkgid, nothing)
                        try
                            Base.@invokelatest f(pkgid, mod)
                        catch error
                            @error "hook failed" pkgid mod error
                        end
                        return nothing
                    end
                end
                package_loading_hook!(
                    _CairoMakie_hook,
                    "CairoMakie",
                    "13f3f980-e62b-5c42-98c6-ff1f3baf88f0",
                ),
                package_loading_hook!(
                    _Makie_hook,
                    "Makie",
                    "ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a",
                ),
                package_loading_hook!(
                    _Plots_hook,
                    "Plots",
                    "91a5bcdd-55d7-5caf-9e0b-520d859cae80",
                ),
                push!(
                    Base.package_callbacks,
                    function (pkgid)
                        hook = get(PACKAGE_LOADING_HOOKS, pkgid, nothing)
                        isnothing(hook) || hook()
                        return nothing
                    end,
                )
            end
        else
            @error "package_callbacks not defined"
        end

        # Once we've defined the functions perform an initial refresh to ensure
        # that all notebook runs start from a consistent state.
        refresh!()
    end
end
