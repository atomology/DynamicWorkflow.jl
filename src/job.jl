using OrderedCollections: OrderedSet

export Job, @job, Unassigned, SuccessResult, FailResult, JobState, JobContext
export fetch, result, status, istasksuccess, isqueuealive

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

"""
$(SIGNATURES)

Create a new Task from a WTask with latest scope and multi-threading.
"""
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
The first argument of the function should take a JobContext.  

# Examples
```julia
my_add(ctx::JobContext, x, y) = x + y
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
        outputref = OutputRef(uuid, Unassigned())
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
        job = Job($name, uuid, WTask($f, parsed_args...), outputref, PENDING)
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


"""
$(SIGNATURES)

Extract task arguments from a job, excluding the first argument (JobContext).
"""
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
    parent_id::Union{Nothing,UUID}
    child_ids::Vector{UUID}
end
JobContext(curr_id) = JobContext(curr_id, nothing, UUID[])

"""
$(SIGNATURES)

Extract the JobContext from job, which is the first argument to the task.
"""
context(j::Job) = j.task.args[1]

function dependencies(job::Job)
    # this is a naive implementation
    # filter only the first layer of dependencies
    # no recursive dependencies
    return filter(x -> x isa AbstractResult, job.task.args)
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


function Base.show(io::IO, ::MIME"text/plain", job::Job)
    print(io, "Job(\"$(job.name)\", $(head(job.uuid)), status=$(repr("text/plain", status(job))))")
end


function Base.show(io::IO, ::MIME"text/plain", status::JobState)
    if status == PENDING
        print(io, "🚧PENDING")
    elseif status == RUNNING
        print(io, "🏃RUNNING")
    elseif status == COMPLETED
        print(io, "✅COMPLETED")
    elseif status == FAILED
        print(io, "❌FAILED")
    elseif status == CANCELLED
        print(io, "⭕CANCELLED")
    end
end
