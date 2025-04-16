module DataDep

using UUIDs
using Graphs
using GraphMakie, GLMakie
using OrderedCollections
using Base: Threads
import Base.Threads: @spawn

# TODO
# 1. implement dynamic scheduling through `response`
# 2. multi-threading and async job excution
# 3. add a central database to record all jobs (uuid, name, dir)


# similar to OutputReference in Jobflow
# reference to a result that may or may not exist yet
mutable struct OutputRef
    uuid::UUID # same uuid with the associated job
    result::Any
end
struct Unassigned end

mutable struct WTask
    f::Function
    task::Task
    args::Tuple
    function WTask(f, args...)
        @nospecialize f args
        # set sticky bit to false for multi-threading
        t = Task(() -> f(args...))
        t.sticky = false
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
    j = Job(job_name, uuid, t, outputref)
    enqueue!(j, Q[])
    return j
end

# Macro to define jobs
macro job(expr)
    name = string(expr.args[1])
    uuid = UUIDs.uuid4()
    f = eval(expr.args[1])
    args = map(a -> eval(a), expr.args[2:end])
    # processed_args = map(arg -> arg isa OutputRef ? arg.result : arg, args)
    # wtask = WTask(Task(() -> f(processed_args...), 0), args...)
    outputref = OutputRef(uuid, Unassigned())
    job = Job(name, uuid, WTask(f, args...), outputref)
    job.task.task.sticky = false
    enqueue!(job, Q[])
    return quote
        $job
    end
end

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa OutputRef, job.task.args)
end

struct JobQueue
    # TODO add jobs to store all jobs and can access job by uuid
    # jobs::Dict{UUID, Job}
    # queue::Vector{UUID}
    # running::Vector{UUID}

    # jobs to run will enqueue
    queue::OrderedDict{UUID, Job}
    # jobs already running
    running::OrderedDict{UUID, Job}
    # the dependency graph of ran jobs
    g::SimpleDiGraph
    # mapping between graph node id and job uuid
    node2id::Dict{Int, UUID}
    id2node::Dict{UUID, Int}
    function JobQueue()
        queue = Dict{UUID, Job}()
        running = Dict{UUID, Job}()
        g = SimpleDiGraph()
        node2id = Dict{Int, UUID}()
        id2node = Dict{UUID, Int}()
        return new(queue, running, g, node2id, id2node)
    end
end

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
function resolve_args!(job::Job, q::JobQueue)
    @debug "resolving job: $(job.name), id: $(job.uuid)"
    new_args = Any[]
    depends_on = UUID[]
    for i in eachindex(job.task.args)
        arg = job.task.args[i]
        # for normal variables, we assume they are always accessiable
        if !(arg isa OutputRef)
            push!(new_args, arg)
            continue
        end
        # previous Job not finished yet
        if arg.result isa Unassigned
            @debug "job will NOT run"
            return nothing
        end
        # finished kkk, ready to run
        push!(new_args, arg.result)
        push!(depends_on, arg.uuid)

    end
    job.task.args = Tuple(new_args)
    job.task.task = Task(() -> job.task.f(job.task.args...))
    job.task.task.sticky = false
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
Non-blocking call to scheudle a Job to run with available threads
"""
function run!(job::Job)
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

# shutdown = Channel{Bool}(1)  # Single-item shutdown channel
# t = scheduler_main(Q[], shutdown)


# j1 = @job add(1, 2)
# j2 = @job add(2, 3)

# # no cycle
# if 
#     j1 = @job add(1, 2)
#     j2 = @job add(2, 3)
# else
#     j3 = @job func(j1, j2)
#     j4 = @job add(j3.output, j2.output)
# end
# In, Out, InOut

# flow = Flow([j4, j2, j3, j1])
# draw_graph(flow)

# run!(flow)
# j4.output.result

# # with cycle
# c1 = @job add(1, 2)
# c2 = @job add(2, c1.output)
# c3 = @job add(3, c2.output)
# # during the workflow somehow you changed the argument of c1
# c1.task.args = (1, c3.output)
# flow = Flow([c1, c2, c3])


# function func(job_scf)
#     wfc_path = get_wfc(job_scf)
#     new_path = HPCInterface.copy_path(wfc_path, q_points)
#     for i in 1:q_points
#         @spawn dfpt(new_path[i])
#     end
#     HPCInterface.delete(new_path)
#     return output
# end


# j1 = @spawn func(job_scf)

# # Job Scheduler
# j2

# # Native Julia Scheulder



# function queue_worker(input::Channel, output::Channel, shutdown::Channel{Bool})
#     @async begin
#         while true
#             # Check for shutdown signal
#             if isready(shutdown)
#                 println("Worker shutting down")
#                 close(output)
#                 break
#             end
            
#             # Process items with timeout
#             item = try
#                 timedwait(0.5) do  # Check every 0.5 seconds
#                     isready(input) || isready(shutdown)
#                 end
#                 isready(input) ? take!(input) : nothing
#             catch e
#                 println("Error: ", e)
#                 continue
#             end
            
#             item === nothing && continue
            
#             # Process item
#             start = time()
#             println("Processing: ", item)
#             sleep(rand())  # Random processing time
            
#             # Send result
#             put!(output, "Processed $item for $(time() - start)")
#         end
#     end
# end

# # Usage
# input = Channel{String}(Inf)  # Unlimited buffer
# output = Channel{String}(10)
# shutdown = Channel{Bool}(1)  # Single-item shutdown channel

# worker = queue_worker(input, output, shutdown)

# # Producer task
# @async begin
#     for i in 1:10
#         put!(input, "Task $i")
#     end
# end

# put!(shutdown, false)  # Signal shutdown

# # Consumer
# if isopen(output) && isready(output)
#     for i in 1:10
#         println("Received: ", take!(output))
#     end
# end


# d = OrderedDict{Char,Int}()
# push!(d, 'a' => 1)


# for c in 'a':'d'
#     d[c] = c-'a'+1
# end
# for x in d
#    println(x)
#    delete!(d, x[1])
# end

# g = SimpleDiGraph()
# add_vertex!(g)
# add_edge!(g, 1, 2)
