using OrderedCollections: OrderedSet
using PrettyTables

export start_scheduler, stop_scheduler, allcomplete, cancel!

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

function Base.show(io::IO, ::MIME"text/plain", Q::JobQueue)
    # Print summary information
    println(io, "JobQueue with $(length(Q.jobs)) jobs:")
    println(io, "  Pending: $(length(Q.pending))")
    println(io, "  Running: $(length(Q.running))")
    println(io, "  Done: $(length(Q.completed))")

    # If there are jobs, create a table with job details
    if !isempty(Q.jobs)
        # Prepare data for the table
        names = String[]
        uuids = String[]
        statuses = String[]

        for (uuid, job) in Q.jobs
            # Get job status as string
            status_str = string(job.status)

            # Add row to data
            push!(names, string(job.name))
            push!(uuids, head(uuid))
            push!(statuses, status_str)
        end

        # Create highlighters for different statuses
        hl_pending = Highlighter(
            (data, i, j) -> j == 3 && data[i, j] == "PENDING",
            crayon"yellow"
        )

        hl_running = Highlighter(
            (data, i, j) -> j == 3 && data[i, j] == "RUNNING",
            crayon"blue bold"
        )

        hl_completed = Highlighter(
            (data, i, j) -> j == 3 && data[i, j] == "COMPLETED",
            crayon"green"
        )

        hl_failed = Highlighter(
            (data, i, j) -> j == 3 && data[i, j] == "FAILED",
            crayon"red bold"
        )

        hl_cancelled = Highlighter(
            (data, i, j) -> j == 3 && data[i, j] == "CANCELLED",
            crayon"magenta"
        )

        # Print table with job information and highlighting
        pretty_table(io, hcat(names, uuids, statuses);
            header=["Name", "UUID", "Status"],
            alignment=[:l, :l, :l],
            crop=:none,
            highlighters=(hl_pending, hl_running, hl_completed, hl_failed, hl_cancelled)
        )
    end
end


function Base.show(io::IO, Q::JobQueue)
    print(io, "JobQueue($(length(Q.jobs)) jobs)")
end
