"""
Run, and re-run, Quarto notebooks and convert the results to Jupyter notebook files.

# Usage

```julia
julia> using QuartoNotebookRunner

julia> server = QuartoNotebookRunner.Server();

julia> QuartoNotebookRunner.run!(server, "notebook.qmd", output = "notebook.ipynb")

julia> QuartoNotebookRunner.close!(server, "notebook.qmd")

```
"""
module QuartoNotebookRunner

# Imports.

import Base64
import CommonMark
import Compat
import IOCapture
import IterTools
import JSON3
import Logging
import Malt
import PNGFiles
import PrecompileTools
import ProgressMeter
import REPL
import Random
import Sockets
import TOML
import YAML

# Exports.

export Server, render, run!, close!

# Includes.

include("server.jl")
include("socket.jl")
include("worker.jl")
include("precompile.jl")

end # module QuartoNotebookRunner
