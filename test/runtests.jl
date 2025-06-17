using DynamicWorkflow
using DynamicWorkflow: context, Q
using DynamicWorkflow: PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
using Test
# using TestItems
# using TestItemRunner

# @run_package_tests

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

@testset "initialization" begin
    @test !isqueuealive()
    @test !allcomplete()
end

@testset "scheduler" begin
    start_scheduler()
    sleep(1)
    t = Q[].mainloop
    @test istaskstarted(t)
    stop_scheduler()
    sleep(1)
    @test istaskdone(t)
end

@testset "basics: job macros" begin
    t = start_scheduler()
    try
        j1 = @job my_add(1, 2)
        j2 = @job my_add(3, 2)
        j3 = @job my_add(j1, j2)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        # wait for main cycle
        sleep(2)
        @test length(Q[].pending) == 0
        @test length(Q[].running) == 0
        @test allcomplete()
        @test length(Q[].completed) == 3
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

@testset "basics: job function" begin
    t = start_scheduler()
    try
        j1 = Job(my_add, 1, 2)
        j2 = Job(my_add, 3, 2)
        j3 = Job(my_add, j1.output, j2.output)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        # wait for main cycle
        sleep(2)
        @test length(Q[].pending) == 0
        @test length(Q[].running) == 0
        @test allcomplete()
        @test length(Q[].completed) == 3
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

@testset "job status" begin
    t = start_scheduler()
    try
        j1 = @job my_add(1, 2)
        j2 = @job my_sleep(3)
        j3 = @job my_add(1, j2)
        sleep(1)
        @test status(j1) == COMPLETED
        @test status(j2) == RUNNING
        @test status(j3) == PENDING
        cancel!(j3)
        @test status(j3) == CANCELLED
        sleep(3)
        @test allcomplete()

        j1 = @job bad_job()
        sleep(1)
        @test status(j1) == FAILED
        @test isqueuealive(Q[])
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

@testset "spawning child jobs" begin
    t = start_scheduler()
    try
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
        # FIXME
        sleep(1)

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
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

@testset "dynamics 1: for loop and conditional" begin
    t = start_scheduler()
    try
        function workflow()
            j1 = @job my_add(1, 2)
            jobs = []
            for i in 1:4
                push!(jobs, @job my_add(j1, i))
            end
            if fetch(jobs[3]) > 4
                j2 = @job my_add(jobs[1], jobs[3])
            else
                j2 = @job my_add(jobs[3], jobs[4])
            end
            return fetch(j2)
        end
        @test workflow() == 10
        sleep(1)
        @test length(Q[].pending) == 0
        @test length(Q[].running) == 0
        @test allcomplete()
        @test length(Q[].completed) == 6
        @test nv(Q[].g) == 6
        @test ne(Q[].g) == 6
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end


@testset "dynamics 2: while loop" begin
    t = start_scheduler()
    try
        function workflow()
            j = @job my_add(1, 1)
            while true
                j = @job my_add(j.output, 1)
                if fetch(j) > 3
                    break
                end
            end
            return fetch(j)
        end
        @test workflow() == 4
        sleep(1)
        @test length(Q[].pending) == 0
        @test length(Q[].running) == 0
        @test allcomplete()
        @test length(Q[].completed) == 3
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

# function get_st()
#     return stacktrace()
# end
