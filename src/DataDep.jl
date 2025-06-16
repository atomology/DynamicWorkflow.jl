module DataDep

using Reexport
using DocStringExtensions
using UUIDs
@reexport using Graphs
using GraphMakie, GLMakie
using Base: Threads
import Base.Threads: @spawn
using Dates

include("scheduler.jl")

include("plot.jl")
export draw_graph

end # module DataDep

