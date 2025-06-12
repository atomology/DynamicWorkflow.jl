module DataDep

using Reexport
using DocStringExtensions
using UUIDs
@reexport using Graphs
using GraphMakie, GLMakie
using OrderedCollections
using Base: Threads
import Base.Threads: @spawn
using Dates

include("scheduler.jl")
export Job, @job, Unassigned, SuccessResult, FailResult, JobContext
export start_scheduler, stop_scheduler, isfinished

include("plot.jl")
export draw_graph

end # module DataDep

