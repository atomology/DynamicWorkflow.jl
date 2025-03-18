using UUIDs
using Base: method_argnames
using Graphs
using GraphMakie, GLMakie



# TODO
# 1. implement dynamic scheduling through `response`
# 2. multi-threading and async job excution
# 3. add a central database to record all jobs (uuid, name, dir)


# similar to OutputReference in Jobflow
# reference to a result that may or may not exist yet
mutable struct OutputRef
    uuid::UUID
    result::Any
end

struct Unassigned
end

mutable struct WTask
    f::Function
    task::Task
    args::Tuple

    function WTask(f, args...)
        @nospecialize f args

        # set sticky bit to false so it can run any available threads
        t = Task(() -> f(args...), 0)
        new(f, t, args)
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
    outputref = OutputRef(uuid, Unassigned())
    Job(job_name, uuid, t, outputref)
end

# Macro to define jobs
macro job(expr)
    name = string(expr.args[1])
    uuid = UUIDs.uuid4()
    f = expr.args[1]
    args = map(a -> eval(a), expr.args[2:end])
    # processed_args = map(arg -> arg isa OutputRef ? arg.result : arg, args)
    # wtask = WTask(Task(() -> f(processed_args...), 0), args...)
    outputref = OutputRef(uuid, Unassigned())
    return quote
        Job($name, $uuid, WTask($f, $args...), $outputref)
    end
end
function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa OutputRef, job.task.args)
end

function resolve_args!(job::Job)
    new_args = Any[]
    for i in eachindex(job.task.args)
        arg = job.task.args[i]
        if !(arg isa OutputRef)
            push!(new_args, arg)
            continue
        end

        if arg.result isa Unassigned
            throw(ArgumentError("Argument $i is not assigned"))
        end

        push!(new_args, arg.result)
    end
    job.task.args = Tuple(new_args)
    job.task.task = Task(() -> job.task.f(job.task.args...), 0)
    return job
end


function run!(job::Job)
    resolve_args!(job)
    schedule(job.task.task)
    job.output.result = fetch(job.task.task)
end

function Base.fetch(job::Job)
    fetch(job.task.task)
end

function Base.yield(job::Job)
    yield(job.task.task)
end

function Base.istaskstarted(job::Job)
    istaskstarted(job.task.task)
end

function Base.istaskdone(job::Job)
    istaskdone(job.task.task)
end

function Base.istaskfailed(job::Job)
    istaskfailed(job.task.task)
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

function is_dag(g::SimpleDiGraph)
    try
        topological_sort(g)
    catch
        return false
    end
    return true
end

function draw_graph(flow::Flow)
    g = flow.graph.graph
    labels = map(i -> uuid2job(flow.graph.nodemap[i], flow).name, 1:nv(g))
    f, ax, p = graphplot(g;
        ilabels=labels,
        method=:spring,
        arrow_size=15,
        edge_color=:gray,
    )
    ax.title = "Flow Graph"
    hidedecorations!(ax)
    hidespines!(ax)
    ax.aspect = DataAspect()
    return f
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


function uuid2job(uuid::UUID, flow::Flow)
    i = findfirst(job -> job.uuid == uuid, flow.jobs)
    return flow.jobs[i]
end

function run!(flow::Flow)
    for i in flow.graph.nodeorder
        job = uuid2job(flow.graph.nodemap[i], flow)
        run!(job)
    end
end

function add(x, y)
    x + y
end

# no cycle
j1 = @job add(1, 2)
j2 = @job add(2, 3)
j3 = @job add(j1.output, j2.output)
j4 = @job add(j3.output, j2.output)

flow = Flow([j4, j2, j3, j1])
draw_graph(flow)

run!(flow)
j4.output.result

# with cycle
c1 = @job add(1, 2)
c2 = @job add(2, c1.output)
c3 = @job add(3, c2.output)
# during the workflow somehow you changed the argument of c1
c1.task.args = (1, c3.output)
flow = Flow([c1, c2, c3])