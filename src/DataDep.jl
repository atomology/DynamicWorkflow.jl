module DataDep

using Reexport
using UUIDs
@reexport using Graphs
using GraphMakie, GLMakie
using OrderedCollections
using Base: Threads
import Base.Threads: @spawn


# similar to OutputReference in Jobflow
# reference to a result that may not exist yet
mutable struct OutputRef
    # same uuid with the associated job
    uuid::UUID
    result::Any
end
# used as OutputRef.result to indicate unfinished job
struct Unassigned end

mutable struct WTask
    f::Function
    args::Tuple
    task::Task
    function WTask(f, args...)
        @nospecialize f args
        # set sticky bit to false by default to allow multi-threading
        t = Task(() -> invokelatest(f, args...))
        t.sticky = false
        new(f, args, t)
    end
end

function task(w::WTask)
    t = Task(()->invokelatest(w.f, w.args...))
    t.sticky = false
    return t
end

mutable struct Job
    name::String
    uuid::UUID
    task::WTask
    output::OutputRef
end

function Job(f::Function, args...)
    uuid = UUIDs.uuid4()
    name = string(f)
    t = WTask(f, args...)
    outputref = OutputRef(uuid, Unassigned())
    j = Job(name, uuid, t, outputref)
    enqueue!(j, Q[])
    return j
end

# Macro to define jobs
macro job(expr)
    uuid = UUIDs.uuid4()
    name = string(expr.args[1])
    # evaluate function and arguments in caller scope
    f = esc(expr.args[1])
    args = map(a -> esc(a), expr.args[2:end])
    outputref = OutputRef(uuid, Unassigned())
    return quote
        eval_args = ($(args...),)
        parsed_args = map(a->a isa Job ? a.output : a, eval_args)
        job = Job($name, $uuid, WTask($f, parsed_args...), $outputref)
        enqueue!(job, Q[])
        job
    end
end

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa OutputRef, job.task.args)
end

struct JobQueue
    # jobs to run
    queue::OrderedDict{UUID, Job}
    # jobs running
    running::OrderedDict{UUID, Job}
    # the dependency graph of ran jobs
    g::SimpleDiGraph
    # mapping between graph node id and job uuid
    node2id::Dict{Int, UUID}
    id2node::Dict{UUID, Int}
    function JobQueue()
        queue = OrderedDict{UUID, Job}()
        running = OrderedDict{UUID, Job}()
        g = SimpleDiGraph()
        node2id = Dict{Int, UUID}()
        id2node = Dict{UUID, Int}()
        return new(queue, running, g, node2id, id2node)
    end
end

inqueue(id::UUID, q::JobQueue) = in(id, union(keys(q.queue), keys(q.running)))

function Graphs.add_vertex!(q::JobQueue, uuid::UUID)
    try
        add_vertex!(q.g)
        node = nv(q.g)
        q.node2id[node] = uuid
        q.id2node[uuid] = node
        return true
    catch
        return false
    end
end

global Q = Ref{JobQueue}()
Q[] = JobQueue()

# return true if job is runnable
function resolve_args!(job::Job, q::JobQueue)::Union{Nothing, Vector{UUID}}
    @debug "resolving job: $(job.name), id: $(job.uuid)"
    new_args = Any[]
    depends_on = UUID[]
    for i in eachindex(job.task.args)
        arg = job.task.args[i]
        # argument is normal variables
        # we assume it is always accessiable
        if !(arg isa OutputRef)
            push!(new_args, arg)
            continue
        end
        # argument is OutputRef
        # 1. of a in-queue Job not finished yet, terminate resolving and wait for next main cycle
        # 2. of a finished Job, then update arg
        # 3. of a unknown Job, then throw error
        if arg.result isa Unassigned
            if inqueue(arg.uuid, q)
                @debug "job arguments not fullfilled, will not run"
                return nothing
            else
                @error "job dependency error!"
            end
        end
            
        push!(new_args, arg.result)
        push!(depends_on, arg.uuid)

    end
    job.task.args = Tuple(new_args)
    return depends_on
end


function enqueue!(job::Job, q::JobQueue)
    push!(q.queue, job.uuid => job)
end

function scheduler_main(q::JobQueue, shutdown::Channel{Bool})
    @async begin
        while true
            if isready(shutdown)
                @info "JobScheduler shutting down!"
                break
            end
            if isempty(q.queue) && isempty(q.running)
                sleep(1)
                continue
            end
            # task submission
            for (uuid, job) in q.queue
                # TODO how to check DAG?
                depends_on = resolve_args!(job, q)
                # dependencies not fully fullyfilled
                if depends_on === nothing
                    continue
                end
                # update queue and graph
                delete!(q.queue, uuid)
                push!(q.running, uuid=>job)
                add_vertex!(q, uuid)
                for id in depends_on
                    @assert add_edge!(q.g, q.id2node[id], q.id2node[job.uuid])
                end
                @debug "Spawning job: $(job.name) uuid: $(job.uuid)"
                run!(job)
            end
            # check results
            for (uuid, job) in q.running
                if istaskdone(job)
                    # only place to write output, so no lock needed
                    job.output.result = fetch(job.task.task)
                    delete!(q.running, uuid)
                elseif istaskfailed(job)
                    @warn "Failed job: $(job.name) (id: $(job.uuid))"
                    delete!(q.running, uuid)
                    # error_handle(job)
                end
            end
            # TODO waitedtime
            sleep(1)
        end
    end
end


"""
Non-blocking call to force scheudle a Job to run with available threads. 
"""
function run!(job::Job)
    # reinitlialize task to 1) update args 2) ignore previous task status
    job.task.task = task(job.task)
    schedule(job.task.task)
    yield()
end

function Base.wait(job::Job)
    while true
        if istaskdone(job)
            break
        end
        # TODO wtf we need yield here?
        # shouldn't fetch has implicit yielding???
        yield()
    end
end

"""
Blocking call to wait for and get the result of the job
"""
function Base.fetch(job::Job)
    wait(job)
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

function draw_graph(q::JobQueue)
    g = q.g
    labels = map(i -> string(q.node2id[i])[end-4:end], 1:nv(g))
    f, ax, p = graphplot(g;
        ilabels=labels,
        method=:spring,
        arrow_size=15,
        edge_color=:gray,
    )
    ax.title = "Job Graphs"
    hidedecorations!(ax)
    hidespines!(ax)
    ax.aspect = DataAspect()
    return f
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

end # module DataDep

