using UUIDs
using Base: method_argnames
using GraphMakie, GLMakie
using Graphs

# TODO
# fix the result reference mechanism

# similar to OutputReference in Jobflow
# reference to a result that may or may not exist yet
mutable struct OutputRef
    uuid::UUID
    result::Any
end

struct WTask
    task::Task
    args::Tuple

    function WTask(f, args...)
        @nospecialize f args

        # sticky bit to false so it can run any available threads
        t = Task(() -> f(args...), 0)
        new(t, args)
    end
end

mutable struct Job
    name::String
    uuid::UUID
    task::WTask
    output::OutputRef
end

function Job(f::Function, args...)
    uuid = UUIDs.uuid4()
    job_name = string(f)
    t = WTask(f, args...)
    outputref = OutputRef(uuid, Ref{Dict{String,Any}}())
    Job(job_name, uuid, t, outputref)
end

# Macro to define jobs
macro job(expr)
    name = string(expr.args[1])
    uuid = UUIDs.uuid4()
    f = expr.args[1]
    args = map(a -> eval(a), expr.args[2:end])
    processed_args = map(arg -> arg isa OutputRef ? arg.result : arg, args)
    wtask = WTask(Task(() -> f(processed_args...), 0), args...)
    outputref = OutputRef(uuid, Ref{Dict{String,Any}}())
    return quote
        Job($name, $uuid, $wtask, $outputref)
    end
end

function is_dag(g::SimpleDiGraph)
    try
        topological_sort(g)
    catch
        return false
    end
    return true
end

struct FlowGraph
    graph::DiGraph
    nodemap::Dict{Int,UUID}
    nodeorder::Vector{Int}
end

mutable struct Flow
    jobs::Vector{Job}
    graph::FlowGraph
end

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa OutputRef, job.task.args)
end

# Function to define a flow and resolve dependencies
function Flow(jobs::Vector{Job}; traversal::Symbol=:topological)
    if isempty(jobs)
        error("No jobs provided")
    end

    n = length(jobs)
    g = DiGraph(n)

    jobmap = Dict{UUID,Int}()
    nodemap = Dict{Int,UUID}()
    for (i, job) in enumerate(jobs)
        jobmap[job.uuid] = i
        nodemap[i] = job.uuid
    end

    if n == 1
        fg = FlowGraph(g, nodemap, [1])
        return Flow(jobs, fg)
    end

    for job in jobs
        for dep in dependencies(job)
            add_edge!(g, jobmap[dep.uuid], jobmap[job.uuid])
        end
    end

    if traversal == :bfs
        # TODO what if first one has dep?
        nodeorder = Int[1]
        queue = Int[1]
        seen = Set{Int}([1])
        while !isempty(queue)
            node = popfirst!(queue)
            for neighbor in outneighbors(g, node)
                if !(neighbor in seen)
                    push!(queue, neighbor)
                    push!(nodeorder, neighbor)
                    push!(seen, neighbor)
                end
            end
        end
    elseif traversal == :topological
        is_dag(g) || error("The job dependencies form a cycle!")
        nodeorder = topological_sort(g)
    else
        throw(ArgumentError("Traversal method not supported"))
    end
    fg = FlowGraph(g, nodemap, nodeorder)
    return Flow(jobs, fg)
end



function add(x, y)
    x + y
end

function foo(a::OutputRef, b::OutputRef)
    a.result + b.result
end

j1 = Job(add, 1, 2)
j2 = Job(add, 2, 3)
j3 = Job(foo, j1.output, j2.output)
flow = Flow([j1, j2, j3])

g = flow.graph
graphplot(g.graph; method=:spring)
map(n -> g.nodemap[n], g.nodeorder)

# check if there is any outputref in the input arguments
# method_argnames(methods(add)[1])


# Flow([j1, j2])

# FIXME

j1 = @job add(1, 2)
j2 = @job add(2, 3)
j3 = @job add(j1.output, j2.output)
j4 = @job add(j3.output, j2.output)
flow = Flow([j1, j2, j3, j4])
g = flow.graph
graphplot(g.graph; method=:spring)
map(n -> g.nodemap[n], g.nodeorder)
j3.uuid