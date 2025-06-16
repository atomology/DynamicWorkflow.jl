using DataDep
using DataDep: context, Q
using Test
# using TestItems
# using TestItemRunner

# @run_package_tests

function add(ctx::JobContext, x, y)
    x + y
end

@testset "scheduler" begin
    t = start_scheduler()
    sleep(1)
    @test istaskstarted(t)
    stop_scheduler()
    sleep(1)
    @test istaskdone(t)
end

@testset "basics: job macros" begin
    t = start_scheduler()
    try
        j1 = @job add(1, 2)
        j2 = @job add(3, 2)
        j3 = @job add(j1, j2)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        # wait for main cycle
        sleep(2)
        @test length(Q[].queue) == 0
        @test length(Q[].running_jobs) == 0
        @test length(Q[].completed_jobs) == 3
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
        j1 = Job(add, 1, 2)
        j2 = Job(add, 3, 2)
        j3 = Job(add, j1.output, j2.output)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        # wait for main cycle
        sleep(2)
        @test length(Q[].queue) == 0
        @test length(Q[].running_jobs) == 0
        @test length(Q[].completed_jobs) == 3
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
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
                j = @job add(ctx, 1, i)
                # sleep(1)
                push!(jobs, j)
            end
            return jobs
        end

        w = @job spawn_jobs()
        @test w.uuid == context(w).parent_id

        spawned_jobs = fetch(w)
        sleep(1)
        uuids = map(j->j.uuid, spawned_jobs)
        @test uuids == context(w).child_ids

        function add_jobs(ctx::JobContext, a, b, c)
            return a + b + c
        end
        jobs = fetch(w)
        j = @job add_jobs(jobs[1], jobs[2], jobs[3])
        @test fetch(j) == 9
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
            j1 = @job add(1, 2)
            jobs = []
            for i in 1:4
                push!(jobs, @job add(j1, i))
            end
            if fetch(jobs[3]) > 4
                j2 = @job add(jobs[1], jobs[3])
            else
                j2 = @job add(jobs[3], jobs[4])
            end
            return fetch(j2)
        end
        @test workflow() == 10
        sleep(1)
        @test length(Q[].queue) == 0
        @test length(Q[].running_jobs) == 0
        @test length(Q[].completed_jobs) == 6
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
            j = @job add(1, 1)
            while true
                j = @job add(j.output, 1)
                if fetch(j) > 3
                    break
                end
            end
            return fetch(j)
        end
        @test workflow() == 4
        sleep(1)
        @test length(Q[].queue) == 0
        @test length(Q[].running_jobs) == 0
        @test length(Q[].completed_jobs) == 3
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
