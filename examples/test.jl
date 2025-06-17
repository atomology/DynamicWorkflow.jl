using DataDep
using DataDep: context, Q
using DataDep: PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
using Test


# TODO
# - [x] test more dynamics
# - [x] fix applicable method maybe too new
# - [x] fix @job macro
# - [x] hide Q[] scheduler_main from user
# - [x] edge from job within a job is not linked
# - [ ] optimize graph plot
# - [ ] CI

function my_add(ctx::JobContext, x, y)
    x + y
end

function my_sleep(ctx::JobContext, n::Int)
    sleep(n)
    return n
end

function bad_job(ctx::JobContext)
    a = []
    return a[1]
end

t = start_scheduler()
function spawn_jobs(ctx::JobContext)
    jobs = Job[]
    for i in 1:3
        j = @job my_add(ctx, 1, i)
        # sleep(1)
        push!(jobs, j)
    end
    return jobs
end

w = @job spawn_jobs()
jobs = fetch(w)

uuids = map(j->j.uuid, jobs)
@test w.uuid == context(w).parent_id
@test uuids == context(w).child_ids

function add_jobs(ctx::JobContext, a, b, c)
    return a + b + c
end
j = @job add_jobs(jobs[1], jobs[2], jobs[3])
sleep(1)
@test fetch(j) == 9
@test allcomplete()
stop_scheduler()
