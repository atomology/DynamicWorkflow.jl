using OrderedCollections: OrderedSet
using PrettyTables

export start_scheduler, stop_scheduler, allcomplete, cancel!

"""
The central scheduler for jobs. Only one global instance of `JobScheduler` should exist
and is created by `start_scheduler`.

# Fields
$(FIELDS)
"""
mutable struct JobScheduler
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
    function JobScheduler()
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

# the global scheduler running on main processes
global JS = Ref{JobScheduler}()
global SHUTDOWN = Ref{Channel{Bool}}()

Base.in(job::Job, js::JobScheduler) = in(job.uuid, keys(js.jobs))
iscompleted(j::Job, js::JobScheduler) = in(j.uuid, js.completed)
iscompleted(j::Job) = isassigned(JS) && iscompleted(j, JS[].completed)
"""
$(SIGNATURES)

Check if the scheduler's main loop is still running.
"""
isalive(js::JobScheduler) = !istaskdone(js.mainloop)
isalive() = isassigned(JS) && isalive(JS[])
"""
    allcomplete()

Check if all jobs in the scheduler are completed.
"""
allcomplete(js::JobScheduler) = isempty(js.pending) && isempty(js.running)
allcomplete() = isassigned(JS) && allcomplete(JS[])

function submit!(job::Job, js::JobScheduler)
    lock(js.lock) do
        push!(js.jobs, job.uuid => job)
        push!(js.pending, job.uuid)
        job.status = PENDING
    end
end

"""
$(SIGNATURES)
Try to cancel a job from running.

# Returns
`true` if the job was successfully cancelled, `false` otherwise
"""
function cancel!(job::Job, js::JobScheduler)
    if !(job in js)
        @info "job $(job.uuid) is not in JobScheduler"
        return false
    end

    if job.status != PENDING
        @warn "Job $(job.uuid) status: $(status(job)), cannot cancel."
        return false
    end

    id = job.uuid
    if in(id, js.pending)
        lock(js.lock) do
            delete!(js.pending, job.uuid)
            delete!(js.jobs, job.uuid)
            job.status = CANCELLED
        end
        return true
    else
        @warn "Job $(job.uuid) status unknown!"
        return false
    end
end
cancel!(job::Job) = cancel!(job, JS[])

"""
$(SIGNATURES)

Start scheduler mainloop task, i.e. `JS[].mainloop`.
"""
function start_scheduler()
    @info "Starting scheduler..."
    if isassigned(JS) && !istaskdone(JS[].mainloop)
        @warn "Scheduler is already running!"
        return nothing
    end
    JS[] = JobScheduler()
    SHUTDOWN[] = Channel{Bool}(1)
    t = scheduler_main(JS[], SHUTDOWN[])
    JS[].mainloop = t
    return t
end

# TODO is this needed?
"""
$(SIGNATURES)

Stop the passed scheduler.
"""
function stop_scheduler(js::JobScheduler, shutdown::Channel{Bool})
    if !isalive(js)
        @info "Scheduler already stopped."
        return
    end
    @info "Stopping scheduler..."
    put!(shutdown, true)
    wait(js.mainloop)
end

"""
$(SIGNATURES)

Stop the main scheduler task, i.e. `JS[].mainloop`.
"""
function stop_scheduler()
    if isassigned(JS) && isassigned(SHUTDOWN)
        stop_scheduler(JS[], SHUTDOWN[])
    else
        @info "Scheduler never started."
    end
end



function Graphs.add_vertex!(js::JobScheduler, uuid::UUID)
    try
        add_vertex!(js.g)
        node = nv(js.g)
        js.node2id[node] = uuid
        js.id2node[uuid] = node
        return true
    catch
        return false
    end
end

# return nothing if job is not runnable
function resolve_args!(job::Job, js::JobScheduler)::Union{Nothing,Vector{UUID}}
    @debug "resolving denpendecies for job: $(job.name), uuid: $(job.uuid)"
    new_args = Any[]
    depends_on = UUID[]
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
            @error "job $(job.uuid) dependencies errored, stop scheduler!"
        end
    end
    @debug "resolved arguments: $new_args"
    job.task.args = Tuple(new_args)
    return depends_on
end

function scheduler_main(js::JobScheduler, shutdown::Channel{Bool}; sleep_time=0.01)
    t = @async begin
        while true
            if isready(shutdown)
                @info "Scheduler shut down!"
                break
            end
            if allcomplete(js)
                sleep(sleep_time)
                continue
            end
            # task submission
            for uuid in js.pending
                job = js.jobs[uuid]
                # TODO how to check DAG?
                depends_on = resolve_args!(job, js)
                # dependencies not fully fullyfilled
                if depends_on === nothing
                    continue
                end
                # job ready to run
                execute_job!(js, uuid, depends_on)
            end
            # check results
            for uuid in js.running
                job = js.jobs[uuid]
                if istasksuccess(job)
                    # only place to write output, so no lock needed
                    job.status = COMPLETED
                    job.output.result = SuccessResult(fetch(job))
                    lock(js.lock) do
                        delete!(js.running, uuid)
                        push!(js.completed, uuid)
                    end
                elseif istaskfailed(job)
                    @warn "Failed job: $(job.name) (id: $(job.uuid))"
                    job.status = FAILED
                    job.output.result = FailResult(fetch(job))
                    lock(js.lock) do
                        delete!(js.running, uuid)
                        push!(js.completed, uuid)
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


function execute_job!(js::JobScheduler, uuid::UUID, depends_on)
    job = js.jobs[uuid]
    try
        lock(js.lock) do
            delete!(js.pending, uuid)
            push!(js.running, uuid)
            job.status = RUNNING
            add_vertex!(js, uuid)
            # update dependency graph
            for id in depends_on
                add_edge!(js.g, js.id2node[id], js.id2node[job.uuid])
            end
            # context records the job dependency
            # child_ids are not used now
            ctx = context(job)
            @assert ctx.curr_id == uuid
            if !isnothing(ctx.parent_id) && ctx.parent_id != uuid
                add_edge!(js.g, js.id2node[ctx.parent_id], js.id2node[job.uuid])
            end
        end
        @debug "Running job: $(job.name), uuid: $(job.uuid)"
        run!(job)
    catch e
        job.status = FAILED
        job.output.result = FailResult(e)
        @warn "Failed job: $(job.name) (id: $(job.uuid))"
        lock(js.lock) do
            delete!(js.running, uuid)
            push!(js.completed, uuid)
        end
    end
end

function Base.show(io::IO, ::MIME"text/plain", js::JobScheduler)
    # Print summary information
    println(io, "JobScheduler with $(length(js.jobs)) jobs:")
    println(io, "  Pending: $(length(js.pending))")
    println(io, "  Running: $(length(js.running))")
    println(io, "  Done: $(length(js.completed))")

    # If there are jobs, create a table with job details
    if !isempty(js.jobs)
        # Prepare data for the table
        names = String[]
        uuids = String[]
        statuses = String[]

        for (uuid, job) in js.jobs
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


function Base.show(io::IO, js::JobScheduler)
    print(io, "JobScheduler($(length(js.jobs)) jobs)")
end
