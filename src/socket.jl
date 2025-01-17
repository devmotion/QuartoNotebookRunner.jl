# TCP socket server for running Quarto notebooks from external processes.

"""
    serve(; port)

Start a socket server for running Quarto notebooks from external processes.
Call `wait` on the returned task to block until the server is closed.

The port can be specified as an integer or string. If unspecified, and no
arg-1 is provided, a random port will be chosen.

Message schema:

```json
{
    type: "run" | "close" | "stop"
    content: string
}
```

A description of the message types:

 -  `run` - Run a notebook. The content should be the absolute path to the
    notebook file. When the notebook is run, the server will return a response
    with the entire evaluated notebook content in a `notebook` field. Reuse a
    notebook process on subsequent runs. To restart a notebook, close it and run
    it again.

 -  `close` - Close a notebook. The `content` should be the absolute path to
    the notebook file. If no file is specified, all notebooks will be closed.
    When the notebook is closed, the server will return a response with a
    `status` field set to `true`.

 -  `stop` - Stop the server. The server will return a response with a `message`
    field set to `Server stopped.`.
"""
function serve(; port = get(ARGS, 1, rand(1024:65535)))
    getport(port::Integer) = port
    getport(port::AbstractString) = getport(tryparse(Int, port))
    getport(::Any) = throw(ArgumentError("Invalid port: $port"))

    port = getport(port)
    @info "Starting notebook server." port

    notebook_server = Server()
    task = Threads.@spawn begin
        socket_server = Sockets.listen(port)
        while isopen(socket_server)
            socket = nothing
            try
                socket = Sockets.accept(socket_server)
            catch error
                @error "Failed to accept connection" error
                break
            end
            if !isnothing(socket)
                Threads.@spawn while isopen(socket)
                    @debug "Waiting for request"
                    data = readline(socket; keep = true)
                    if isempty(data)
                        @debug "Connection closed."
                        break
                    else
                        json = try
                            _read_json(data)
                        catch error
                            msg = "Failed to parse json message."
                            @error msg error
                            _write_json(socket, (; error = msg))
                            continue
                        end
                        @debug "Received request" json
                        if json.type == "stop"
                            @debug "Closing connection."
                            close!(notebook_server)
                            _write_json(socket, (; message = "Server stopped."))
                            close(socket)
                            close(socket_server)
                        else
                            _write_json(socket, _handle_response(notebook_server, json))
                        end
                    end
                end
            end
        end
        @info "Server closed."
    end
    return errormonitor(task)
end

function _handle_response(
    notebooks::Server,
    request::@NamedTuple{type::String, content::String},
)
    @debug "debugging" request notebooks = collect(keys(notebooks.workers))
    type = request.type
    file = request.content

    type in ("close", "run") || return _log_error("Unknown request type: $type")

    # Closing:

    if type == "close" && isempty(file)
        close!(notebooks)
        return (; message = "Notebooks closed.")
    end

    isabspath(file) || return _log_error("File path must be absolute: $(repr(file))")
    isfile(file) || return _log_error("File does not exist: $(repr(file))")

    if type == "close"
        try
            close!(notebooks, file)
            return (; status = true)
        catch error
            return _log_error("Failed to close notebook: $file", error, catch_backtrace())
        end
    end

    # Running:

    if type == "run"
        try
            return (; notebook = run!(notebooks, file))
        catch error
            return _log_error("Failed to run notebook: $file", error, catch_backtrace())
        end
    end

    # Shouldn't get to this point.
    error("unreachable reached.")
end

function _log_error(message, error, backtrace)
    @error message error backtrace
    return (; error = message)
end
function _log_error(message)
    @error message
    return (; error = message)
end

# TODO: check what the message schema is for this.
_read_json(data) = JSON3.read(data, @NamedTuple{type::String, content::String})
_write_json(socket, data) = write(socket, JSON3.write(data), "\n")

# Compat:

if !isdefined(Base, :errormonitor)
    function errormonitor(t::Task)
        t2 = Task() do
            if istaskfailed(t)
                local errs = stderr
                try # try to display the failure atomically
                    errio = IOContext(PipeBuffer(), errs::IO)
                    Base.emphasize(errio, "Unhandled Task ")
                    Base.display_error(errio, Base.catch_stack(t))
                    write(errs, errio)
                catch
                    try # try to display the secondary error atomically
                        errio = IOContext(PipeBuffer(), errs::IO)
                        print(
                            errio,
                            "\nSYSTEM: caught exception while trying to print a failed Task notice: ",
                        )
                        Base.display_error(errio, Base.catch_stack())
                        write(errs, errio)
                        flush(errs)
                        # and then the actual error, as best we can
                        Core.print(Core.stderr, "while handling: ")
                        Core.println(Core.stderr, Base.catch_stack(t)[end][1])
                    catch e
                        # give up
                        Core.print(
                            Core.stderr,
                            "\nSYSTEM: caught exception of type ",
                            typeof(e).name.name,
                            " while trying to print a failed Task notice; giving up\n",
                        )
                    end
                end
            end
            nothing
        end
        Base._wait2(t, t2)
        return t
    end
end
