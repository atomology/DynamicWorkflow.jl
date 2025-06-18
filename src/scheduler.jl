using OrderedCollections: OrderedSet

export Job, @job, Unassigned, SuccessResult, FailResult, JobState, JobContext
export fetch, result, start_scheduler, stop_scheduler, allcomplete, cancel!, status, istasksuccess, isqueuealive

abstract type AbstractJob end
abstract type AbstractResult end

"""
Placeholder for a job result that may not exist yet (like Future). The UUID is the same as the associated job.

Fields
$(FIELDS)
"""
mutable struct OutputRef
    uuid::UUID
    result::AbstractResult
end

"""
$(TYPEDEF)
"""
struct SuccessResult <: AbstractResult
    # same uuid with the associated job
    value::Any
end

"""
$(TYPEDEF)
"""
struct FailResult <: AbstractResult
    # same uuid with the associated job
    err::Any
end

"""
$(TYPEDEF)
"""
struct Unassigned <: AbstractResult end

result(o::OutputRef) = result(o.result)
result(r::SuccessResult) = r.value
result(r::FailResult) = r.err
result(::Unassigned) = Unassigned

"""
A wrapper for a function and its arguments to be run as a task.

# Fields
$(FIELDS)
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
$(FIELDS)
One of the following states a job can be in: PENDING, RUNNING, COMPLETED, FAILED, CANCELLED.
"""
@enum JobState begin
    PENDING
    RUNNING
    COMPLETED
    FAILED
    CANCELLED
end

"""
A job that can be scheduled and run. The uuid is used to identify the job
and the result.

Fields
$(FIELDS)
"""
mutable struct Job <: AbstractJob
    name::String
    uuid::UUID
    task::WTask
    output::OutputRef
    status::JobState
end

function Job(f::Function, args...)
    @debug "[$(now())] creaing job with function: $f"
    uuid = UUIDs.uuid4()
    @debug "uuid $uuid"
    if !isassigned(Q)
        throw("JobQueue not initilized. Use start_scheduler().")
    end
    name = string(f)
    if isempty(args) || !isa(args[1], JobContext)
        @debug "no context for job $uuid"
        args = (JobContext(uuid), args...)
    else
        @debug "job context passed for job $uuid"
        parent_ctx = args[1]
        push!(parent_ctx.child_ids, uuid)
        args = (JobContext(uuid, parent_ctx.curr_id, UUID[]), args[2:end]...)
    end
    args = map(a -> a isa Job ? a.output : a, args)
    t = WTask(f, args...)
    result = OutputRef(uuid, Unassigned())
    j = Job(name, uuid, t, result, PENDING)
    enqueue!(j, Q[])
    return j
end

"""
$(SIGNATURES)
Wrap a function and create a job which will be enqueued immediately to the global JobQueue.
The first argument of the function must be of type `JobContext`. When calling without a `ctx`,
the default will be used, and the job will be regarded as a parent job. 

# Examples
```julia
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
j3 = @job my_add(j1, j2)  # j3 depends on j1 and j2
```
"""
macro job(expr)
    @debug "[$(now())] creaing job with expression: $expr"
    name = string(expr.args[1])
    # evaluate function and arguments in caller scope
    f = esc(expr.args[1])
    args = map(a -> esc(a), expr.args[2:end])
    return quote
        if !isassigned(Q)
            throw("JobQueue not initilized. Use start_scheduler().")
        end
        # macro excute when code is parsed, therefore
        # UUID generation needs to be in caller scope
        # otherwise will be the same in one macroexpansion
        uuid = UUIDs.uuid4()
        output = OutputRef(uuid, Unassigned())
        eval_args = ($(args...),)
        parsed_args = map(a -> a isa Job ? a.output : a, eval_args)
        # can call func without ctx
        if isempty(parsed_args) || !isa(parsed_args[1], JobContext)
            @debug "no context for job $(uuid)"
            parsed_args = (JobContext(uuid), parsed_args...)
        else
            @debug "job context passed for job $uuid"
            parent_ctx = parsed_args[1]
            push!(parent_ctx.child_ids, uuid)
            parsed_args = (JobContext(uuid, parent_ctx.curr_id, UUID[]), parsed_args[2:end]...)
        end
        job = Job($name, uuid, WTask($f, parsed_args...), output, PENDING)
        enqueue!(job, Q[])
        job
    end
end


"""
    status(job::Job)

Return one of the [`JobState`](@ref) enum values.
"""
function status(job::Job)
    job.status
end

"""
    result(job::Job)

Get the result of a job without blocking.

# Returns
The job's result or [`Unassigned`](@ref) if not ready
"""
function result(job::Job)
    result(job.output)
end

"""
    fetch(job::Job)

Get the result of a job, blocking until the job is completed.
"""
function Base.fetch(job::Job)
    try
        wait(job)
        return fetch(job.task.task)
    catch
        return job.task.task.result
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
Help to build the dependency graph.

Fields
$(FIELDS)
"""
mutable struct JobContext
    curr_id::UUID
    parent_id::Union{Nothing, UUID}
    child_ids::Vector{UUID}
end
JobContext(curr_id) = JobContext(curr_id, nothing, UUID[])

context(j::Job) = j.task.args[1]

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa AbstractResult, job.task.args)
end


"""
A queue for jobs to be scheduled and run. Only one global instance of `JobQueue` should exist
and is created by `start_scheduler`.

# Fields
$(FIELDS)
"""
mutable struct JobQueue
    # all jobs
    jobs::Dict{UUID,Job}
    # jobs to run
    pending::OrderedSet{UUID}
    # jobs running
    running::OrderedSet{UUID}
    # jobs ran (with only outputs)
    completed::OrderedSet{UUID}
    # the dependency graph of ran jobs
    g::SimpleDiGraph
    # mapping between graph node id and job uuid
    node2id::Dict{Int,UUID}
    id2node::Dict{UUID,Int}
    lock::ReentrantLock
    mainloop::Union{Nothing,Task}
    function JobQueue()
        jobs = Dict{UUID,Job}()
        pending = OrderedSet{UUID}()
        running = OrderedSet{UUID}()
        completed = OrderedSet{UUID}()
        g = SimpleDiGraph()
        node2id = Dict{Int,UUID}()
        id2node = Dict{UUID,Int}()
        return new(jobs, pending, running, completed, g, node2id, id2node, ReentrantLock(), nothing)
    end
end

# the global queue running on main processes
global Q = Ref{JobQueue}()
global SHUTDOWN = Ref{Channel{Bool}}()

inqueue(job::Job, q::JobQueue) = in(job.uuid, keys(q.jobs))
inqueue(job::Job) = isassigned(Q) && inqueue(job.uuid, Q[])
iscompleted(j::Job, q::JobQueue) = in(j.uuid, q.completed)
iscompleted(j::Job) = isassigned(Q) && iscompleted(j, Q[].completed)
isqueuealive(q::JobQueue) = !istaskdone(q.mainloop)
isqueuealive() = isassigned(Q) && isqueuealive(Q[])
"""
    allcomplete()

Check if all jobs in the scheduler are completed.
"""
allcomplete(q::JobQueue) = isempty(q.pending) && isempty(q.running)
allcomplete() = isassigned(Q) && allcomplete(Q[])

function enqueue!(job::Job, q::JobQueue)
    lock(q.lock) do
        push!(q.jobs, job.uuid => job)
        push!(q.pending, job.uuid)
        job.status = PENDING
    end
end

"""
$(SIGNATURES)
Try to cancel a job from running.

# Returns
`true` if the job was successfully cancelled, `false` otherwise
"""
function cancel!(job::Job, queue::JobQueue)
    if !inqueue(job, queue)
        @info "job $(job.uuid) is not in JobQueue"
        return false
    end

    if job.status != PENDING
        @warn "Job $(job.uuid) status: $(status(job)), cannot cancel."
        return false
    end

    id = job.uuid
    if in(id, queue.pending)
        lock(queue.lock) do
            delete!(queue.pending, job.uuid)
            delete!(queue.jobs, job.uuid)
            job.status = CANCELLED
        end
        return true
    else
        @warn "Job $(job.uuid) status unknown!"
        return false
    end
end
cancel!(job::Job) = cancel!(job, Q[])

"""
$(SIGNATURES)

The scheduler task can be accessed by `Q[].mainloop`.
"""
function start_scheduler()
    @info "Starting JobScheduler..."
    if isassigned(Q) && !istaskdone(Q[].mainloop)
        @warn "Scheduler is already running!"
        return nothing
    end
    Q[] = JobQueue()
    SHUTDOWN[] = Channel{Bool}(1)
    t = scheduler_main(Q[], SHUTDOWN[])
    Q[].mainloop = t
    return t
end

"""
$(SIGNATURES)

Stop the scheduler task.
"""
function stop_scheduler(shutdown::Channel{Bool})
    if !isqueuealive()
        @info "Job scheduler already stopped."
        return
    end
    @info "Stopping job scheduler..."
    put!(shutdown, true)
    wait(Q[].mainloop)
end
stop_scheduler() = stop_scheduler(SHUTDOWN[])

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
            return
        elseif arg.result isa SuccessResult
            push!(new_args, result(arg))
            push!(depends_on, arg.uuid)
        else
            # FailedResult
            # TODO error propogation
            @error "job $(job.uuid) dependencies errored, stop queue!"
        end
    end
    pushfirst!(new_args, ctx)
    @debug "resolved arguments: $new_args"
    job.task.args = Tuple(new_args)
    return depends_on
end

function scheduler_main(q::JobQueue, shutdown::Channel{Bool}; sleep_time=0.01)
    t = @async begin
        while true
            if isready(shutdown)
                @info "JobScheduler shut down!"
                break
            end
            if allcomplete(q)
                sleep(sleep_time)
                continue
            end
            # task submission
            for uuid in q.pending
                job = q.jobs[uuid]
                # TODO how to check DAG?
                depends_on = resolve_args!(job, q)
                # dependencies not fully fullyfilled
                if depends_on === nothing
                    continue
                end
                # job ready to run
                execute_job!(q, uuid, depends_on)
            end
            # check results
            for uuid in q.running
                job = q.jobs[uuid]
                if istasksuccess(job)
                    # only place to write output, so no lock needed
                    job.status = COMPLETED
                    job.output.result = SuccessResult(fetch(job))
                    lock(q.lock) do
                        delete!(q.running, uuid)
                        push!(q.completed, uuid)
                    end
                elseif istaskfailed(job)
                    @warn "Failed job: $(job.name) (id: $(job.uuid))"
                    job.status = FAILED
                    job.output.result = FailResult(fetch(job))
                    lock(q.lock) do
                        delete!(q.running, uuid)
                        push!(q.completed, uuid)
                    end
                    # error_handle(job)
                end
            end
            # TODO can be change to only update when a channel receives a message
            sleep(sleep_time)
        end
    end
    return t
end

function execute_job!(q::JobQueue, uuid::UUID, depends_on)
    job = q.jobs[uuid]
    try
        lock(q.lock) do
            delete!(q.pending, uuid)
            push!(q.running, uuid)
            job.status = RUNNING
            add_vertex!(q, uuid)
            # update dependency graph
            for id in depends_on
                add_edge!(q.g, q.id2node[id], q.id2node[job.uuid])
            end
            # context records the job dependency
            # child_ids are not used now
            ctx = context(job)
            @assert ctx.curr_id == uuid
            if !isnothing(ctx.parent_id) && ctx.parent_id != uuid
                add_edge!(q.g, q.id2node[ctx.parent_id], q.id2node[job.uuid])
            end
        end
        @debug "Running job: $(job.name), uuid: $(job.uuid)"
        run!(job)
    catch e
        job.status = FAILED
        job.output.result = FailResult(e)
        @warn "Failed job: $(job.name) (id: $(job.uuid))"
        lock(q.lock) do
            delete!(q.running, uuid)
            push!(q.completed, uuid)
        end
    end
end

"""
Non-blocking call to scheudle a Job to run with available threads. 
"""
function run!(job::Job)
    # reinitlialize task to update args and ignore previous task status
    job.task.task = task(job.task)
    schedule(job.task.task)
    yield()
end


# FIXME
function Base.wait(job::Job)
    while true
        if status(job) in (COMPLETED, FAILED, CANCELLED)
            return
        end
        # TODO why we need yield here?
        yield()
    end
end

function Base.wait(jobs::AbstractVector{Job})
    while true
        if all([istaskdone(j) for j in jobs])
            return
        end
        yield()
    end
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

istasksuccess(job::Job) = istaskdone(job) && !istaskfailed(job)
