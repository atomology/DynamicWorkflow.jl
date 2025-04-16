using DataDep
using DataDep: scheduler_main, @job, JobQueue, Q, Job
using DataDep: draw_graph, wait, fetch
using Base: Threads
import Base.Threads: @spawn


# TODO

# - [ ] test more dynamics
# - [ ] fix applicable method maybe too new
# - [ ] fix @job macro
# - [ ] hide Q[] scheduler_main from user

shutdown = Channel{Bool}(1)  # Single-item shutdown channel
Q[] = JobQueue()
t = scheduler_main(Q[], shutdown)

function add(x, y)
    @info "running on $(Threads.threadid())"
    sleep(3)
    x + y
end

function w()
    jobs = []
    j1 = Job(add, 1, 2)
    for i in 1:4
        push!(jobs, Job(add, j1.output, i))
    end
    if fetch(jobs[3]) > 4
        j = Job(add, jobs[1].output, jobs[3].output)
    else
        j = Job(add, jobs[3].out, jobs[4].output)
    end
    return fetch(j)
end

w()

draw_graph(Q[])

put!(shutdown, true)  # Signal shutdown

