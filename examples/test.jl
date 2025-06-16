using DataDep
using DataDep: scheduler_main, @job, JobQueue, Q, Job
using DataDep: draw_graph, wait, fetch
using Base: Threads
import Base.Threads: @spawn
using Test


# TODO
# - [x] test more dynamics
# - [x] fix applicable method maybe too new
# - [x] fix @job macro
# - [ ] hide Q[] scheduler_main from user
# - [ ] edge from job within a job is not linked

shutdown = Channel{Bool}(1)  # Single-item shutdown channel
Q[] = JobQueue()
t = scheduler_main(Q[], shutdown)

function add(x, y)
    @info "running on thread: $(Threads.threadid())"
    sleep(3)
    x + y
end

# test macro
j1 = @job add(1, 2)
j2 = @job add(3, 4)
j3 = @job add(j1, j2)

fetch(j3) == 10

# test 1
j1 = Job(add, 1, 2)
j2 = Job(add, j1.output, 3)
@test fetch(j2) == 6

# test 2
function t1()
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

@test t1() == 10

# test 3
function t2()
    j = Job(add, 1, 1)
    while true
        j = Job(add, j.output, 1)
        if fetch(j) > 3
            break
        end
    end
    return fetch(j)
end

t1 = @flow begin
    j1 = @job xxx
    j2 = @job xxx
end


j1 = Job(t1)
j2 = Job(t2)
j3 = Job(add, j1.output, j2.output)

@test fetch(j3) == 14

draw_graph(Q[])

put!(shutdown, true)  # Signal shutdown

resolve_args!(j1, Q[])


function f()
    sleep(2)
    Threads.threadid()
end

@info Threads.nthreads()

# multithreading with @spawn
ts = Task[]
for i in 1:4
    t = @spawn f()
    push!(ts, t)
end
map(fetch, ts)

# equivalent to @spawn
ts = Task[]
for i in 1:4
    t = Task(f, 0)
    t.sticky = false
    push!(ts, t)
    schedule(t)
    yield()
end
map(fetch, ts)



