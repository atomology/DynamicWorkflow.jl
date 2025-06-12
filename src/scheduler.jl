abstract type AbstractJob end
abstract type AbstractResult end

"""
$(TYPEDEF)
Placeholder for a job result that may not exist yet (like Future). The UUID is the same as the associated job.
"""

mutable struct OutputRef
    uuid::UUID
    result::AbstractResult
end

struct SuccessResult <: AbstractResult
    # same uuid with the associated job
    value::Any
end

struct FailResult <: AbstractResult
    # same uuid with the associated job
    err::Any
end

# to indicate result 
struct Unassigned <: AbstractResult end

"""
$(TYPEDEF)
A wrapper for a function and its arguments to be run as a task.
"""
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
    t = Task(() -> invokelatest(w.f, w.args...))
    t.sticky = false
    return t
end

"""
$(TYPEDEF)
A job that can be scheduled and run. The uuid is used to identify the job
and the result.
"""
mutable struct Job <: AbstractJob
    name::String
    uuid::UUID
    task::WTask
    output::OutputRef
end

# TODO FIX same as macro
# function Job(f::Function, args...)
#     uuid = UUIDs.uuid4()
#     name = string(f)
#     t = WTask(f, args...)
#     result = OutputRef(uuid, Unassigned())
#     j = Job(name, uuid, t, result)
#     enqueue!(j, Q[])
#     return j
# end

"""
$(SIGNATURES)
Wrap a function and create a job which will be enqueued immediately to the global JobQueue.
The first argument of the function must be of type `JobContext`. When calling without a `ctx`,
the default will be used, and the job will be regarded as a parent job. 
"""
macro job(expr)
    @debug "[$(now())] creaing job with expression: $expr"
    uuid = UUIDs.uuid4()
    @debug "[$(now())] uuid $uuid"
    name = string(expr.args[1])
    # evaluate function and arguments in caller scope
    f = esc(expr.args[1])
    args = map(a -> esc(a), expr.args[2:end])
    output = OutputRef(uuid, Unassigned())
    return quote
        eval_args = ($(args...),)
        parsed_args = map(a -> a isa Job ? a.output : a, eval_args)
        # can call func without ctx
        if isempty(parsed_args) || !isa(parsed_args[1], JobContext)
            @debug "no context for job $($uuid)"
            parsed_args = (JobContext($uuid), parsed_args...)
        else
            @debug "[$(now())] job context for job $($uuid)"
        end
        job = Job($name, $uuid, WTask($f, parsed_args...), $output)
        enqueue!(job, Q[])
        job
    end
end

function task_args(j::Job)
    if !isempty(j.task.args)
        return j.task.args[2:end]
    else
        return j.task.args
    end
end

"""
$(TYPEDEF)
Help to build the dependency graph
"""
mutable struct JobContext
    parent_id::UUID
    child_ids::Vector{UUID}

    JobContext(parent_id) = new(parent_id, UUID[])
end

context(j::Job) = j.task.args[1]

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa AbstractResult, job.task.args)
end


"""
$(TYPEDEF)
A queue for jobs to be scheduled and run. Only one global instance of `JobQueue` should exist
and is created by `start_scheduler`.
"""
struct JobQueue
    # jobs to run
    queue::OrderedDict{UUID, Job}
    # jobs running
    # TODO change to set of UUIDs
    running_jobs::OrderedDict{UUID,Job}
    # jobs ran (with only outputs)
    completed_jobs::OrderedDict{UUID,Job}
    # the dependency graph of ran jobs
    g::SimpleDiGraph
    # mapping between graph node id and job uuid
    node2id::Dict{Int,UUID}
    id2node::Dict{UUID,Int}
    function JobQueue()
        queue = OrderedDict{UUID,Job}()
        running = OrderedDict{UUID,Job}()
        ran = OrderedDict{UUID,Job}()
        g = SimpleDiGraph()
        node2id = Dict{Int,UUID}()
        id2node = Dict{UUID,Int}()
        return new(queue, running, ran, g, node2id, id2node)
    end
end

isinqueue(id::UUID, q::JobQueue) = in(id, union(keys(q.queue), keys(q.running_jobs)))
isfinished(q::JobQueue) = isempty(q.queue) && isempty(q.running_jobs)

# can directly access the global queue by Q[]
global Q = Ref{JobQueue}()
global SHUTDOWN = Ref{Channel{Bool}}()

function start_scheduler()
    @info "Starting JobScheduler..."
    Q[] = JobQueue()
    SHUTDOWN[] = Channel{Bool}(1)
    return scheduler_main(Q[], SHUTDOWN[])
end

function stop_scheduler()
    @info "Stopping JobScheduler..."
    put!(SHUTDOWN[], true)
end

function stop_scheduler(shutdown::Channel{Bool})
    @info "Stopping JobScheduler..."
    put!(shutdown, true)
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

# return nothing if job is not runnable
function resolve_args!(job::Job, q::JobQueue)::Union{Nothing,Vector{UUID}}
    @debug "resolving denpendecies for job: $(job.name), uuid: $(job.uuid)"
    new_args = Any[]
    depends_on = UUID[]
    ctx = context(job)
    for arg in task_args(job)
        # argument is normal variables, we assume it is always accessiable
        if !(arg isa OutputRef)
            push!(new_args, arg)
            continue
        end

        if arg.result isa Unassigned
            @debug "job $(job.uuid) dependencies not fullfilled, will not run!"
            return nothing
            # if isinqueue(arg.uuid, q)
            #     return nothing
            # else
            #     @error "job dependency error!"
            # end
        elseif arg.result isa SuccessResult
            push!(new_args, arg.result.value)
            push!(depends_on, arg.uuid)
        else
            # TODO error propogation
            @error "job $(job.uuid) dependencies errored, stop queue!"
        end
    end
    pushfirst!(new_args, ctx)
    @debug "resolve arguments: $new_args"
    job.task.args = Tuple(new_args)
    return depends_on
end

function enqueue!(job::Job, q::JobQueue)
    push!(q.queue, job.uuid => job)
end

"""
$(SIGNATURES)
Try to dequeue a job from the JobQueue.
"""
function dequeue!(job::Job, q::JobQueue)
    if in(job.uuid, keys(q.queue))
        return delete!(q.queue, job.uuid)
    elseif in(job.uuid, keys(q.running_jobs))
        @error "Job $(job.name) (id: $(job.uuid)) is running, cannot dequeue!"
    elseif in(job.uuid, keys(q.completed_jobs))
        @error "Job $(job.name) (id: $(job.uuid)) is already ran, cannot dequeue!"
    else
        @error "Job $(job.name) (id: $(job.uuid)) not found in queue!"
    end
end


function scheduler_main(q::JobQueue, shutdown::Channel{Bool}; sleep_time=1)
    @async begin
        while true
            if isready(shutdown)
                @info "JobScheduler shutting down!"
                break
            end
            if isempty(q.queue) && isempty(q.running_jobs)
                sleep(sleep_time)
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
                push!(q.running_jobs, uuid => job)
                # update dependency graph
                add_vertex!(q, uuid)
                for id in depends_on
                    add_edge!(q.g, q.id2node[id], q.id2node[job.uuid])
                end
                # push current job to parent job's context
                ctx = context(job)
                if ctx.parent_id != uuid
                    push!(ctx.child_ids, uuid)
                    add_edge!(q.g, q.id2node[ctx.parent_id], q.id2node[job.uuid])
                end
                @debug "Running job: $(job.name), uuid: $(job.uuid)"
                run!(job)
            end
            # check results
            for (uuid, job) in q.running_jobs
                if istaskdone(job)
                    # only place to write output, so no lock needed
                    job.output.result = SuccessResult(fetch(job.task.task))
                    delete!(q.running_jobs, uuid)
                    push!(q.completed_jobs, uuid => job)
                elseif istaskfailed(job)
                    job.output.result = FailResult(fetch(job.task.task))
                    @warn "Failed job: $(job.name) (id: $(job.uuid))"
                    delete!(q.running_jobs, uuid)
                    push!(q.completed_jobs, uuid => job)
                    # error_handle(job)
                end
            end
            # TODO can be change to only update when a channel receives a message
            sleep(sleep_time)
        end
    end
end


"""
Non-blocking call to force scheudle a Job to run with available threads. 
"""
function run!(job::Job)
    # reinitlialize task to update args and ignore previous task status
    job.task.task = task(job.task)
    schedule(job.task.task)
    yield()
end

function Base.wait(job::Job)
    while true
        if istaskdone(job)
            break
        end
        # TODO why we need yield here?
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



