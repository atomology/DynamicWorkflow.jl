using OrderedCollections: OrderedSet

export Job, @job, Unassigned, SuccessResult, FailResult, JobState, JobContext, current_context
export fetch, result, status, istasksuccess, isalive

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
    task::Union{Nothing, Task}
    function WTask(f, args...)
        @nospecialize f args
        return new(f, args, nothing)
    end
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

"""
    current_context() -> Union{Nothing, JobContext}

Return the `JobContext` of the currently executing job, or `nothing` if called outside a job.
Uses Julia `task_local_storage` for implicit context propagation.
"""
function current_context()
    return get(task_local_storage(), :job_context, nothing)
end

"""
Build a `JobContext` for a new job, linking it to the parent context if one exists.
"""
function _make_context(uuid::UUID)
    parent_ctx = current_context()
    if parent_ctx !== nothing
        push!(parent_ctx.child_ids, uuid)
        return JobContext(uuid, parent_ctx.curr_id, UUID[])
    else
        return JobContext(uuid)
    end
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
    context::JobContext
    task::WTask
    output::OutputRef
    status::JobState
end

function Job(f::Function, args...)
    @debug "[$(now())] creating job with function: $f"
    uuid = UUIDs.uuid4()
    @debug "uuid $uuid"
    if !isassigned(JS)
        throw("JobScheduler not initialized. Use start_scheduler().")
    end
    name = string(f)
    ctx = _make_context(uuid)
    args = map(a -> a isa Job ? a.output : a, args)
    t = WTask(f, args...)
    output = OutputRef(uuid, Unassigned())
    j = Job(name, uuid, ctx, t, output, PENDING)
    submit!(j, JS[])
    return j
end

"""
    @job f(args...)

Wrap a function call and create a job which will be submitted immediately to the global JobScheduler.
Functions are plain Julia functions — no special first argument needed.

Parent-child relationships are tracked automatically via task-local storage when
`@job` is called inside a running job.

# Examples
```julia
my_add(x, y) = x + y
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
j3 = @job my_add(j1, j2)  # j3 depends on j1 and j2
```
"""
macro job(expr)
    @debug "[$(now())] creating job with expression: $expr"
    name = string(expr.args[1])
    f = esc(expr.args[1])
    args = map(a -> esc(a), expr.args[2:end])
    return quote
        if !isassigned(JS)
            throw("JobScheduler not initialized. Use start_scheduler().")
        end
        uuid = UUIDs.uuid4()
        outputref = OutputRef(uuid, Unassigned())
        eval_args = ($(args...),)
        parsed_args = map(a -> a isa Job ? a.output : a, eval_args)
        ctx = _make_context(uuid)
        job = Job($name, uuid, ctx, WTask($f, parsed_args...), outputref, PENDING)
        submit!(job, JS[])
        job
    end
end


"""
    status(job::Job)

Return one of the [`JobState`](@ref) enum values.
"""
function status(job::Job)
    return job.status
end

"""
    result(job::Job)

Get the result of a job without blocking.

# Returns
The job's result or [`Unassigned`](@ref) if not ready
"""
function result(job::Job)
    return result(job.output)
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

Extract task arguments from a job.
"""
function task_args(j::Job)
    return j.task.args
end

"""
$(SIGNATURES)

Extract the JobContext from a job.
"""
context(j::Job) = j.context

"""
Non-blocking call to scheudle a Job to run with available threads.
"""
function run!(job::Job)
    ctx = job.context
    original_f = job.task.f
    original_args = job.task.args
    wrapped() = task_local_storage(:job_context, ctx) do
        invokelatest(original_f, original_args...)
    end
    job.task.task = Task(wrapped)
    job.task.task.sticky = false
    schedule(job.task.task)
    return yield()
end

function Base.wait(job::Job)
    while true
        if status(job) in (COMPLETED, FAILED, CANCELLED)
            return
        end
        # TODO why we need yield here?
        yield()
    end
    return
end

function Base.wait(jobs::AbstractVector{Job})
    while true
        if all([istaskdone(j) for j in jobs])
            return
        end
        yield()
    end
    return
end

function Base.yield(job::Job)
    return job.task.task !== nothing && yield(job.task.task)
end

function Base.istaskstarted(job::Job)
    return job.task.task !== nothing && istaskstarted(job.task.task)
end

function Base.istaskdone(job::Job)
    return job.task.task !== nothing && istaskdone(job.task.task)
end

function Base.istaskfailed(job::Job)
    return job.task.task !== nothing && istaskfailed(job.task.task)
end

"""
$(SIGNATURES)

Check if a job has completed successfully (done and not failed).
"""
istasksuccess(job::Job) = istaskdone(job) && !istaskfailed(job)


function Base.show(io::IO, ::MIME"text/plain", job::Job)
    return print(io, "Job(\"$(job.name)\", $(head(job.uuid)), status=$(repr("text/plain", status(job))))")
end


function Base.show(io::IO, ::MIME"text/plain", status::JobState)
    return if status == PENDING
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
