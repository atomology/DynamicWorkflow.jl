using DataDep
using DataDep: scheduler_main, @job, JobQueue, Q, Job, wait, fetch
using DataDep: draw_graph
using Test


function add(x, y)
    x + y
end

@testset "macro" begin
    shutdown = Channel{Bool}(1)
    Q[] = JobQueue()
    t = scheduler_main(Q[], shutdown)
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
        @test length(Q[].running) == 0
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        # shutdown scheduler
        put!(shutdown, true)
    end
end

@testset "scheduler" begin
    shutdown = Channel{Bool}(1)
    Q[] = JobQueue()
    t = scheduler_main(Q[], shutdown)
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
        @test length(Q[].running) == 0
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        # shutdown scheduler
        put!(shutdown, true)
    end
end
    

@testset "workflow dynamics: for loop and conditional" begin
    shutdown = Channel{Bool}(1)
    Q[] = JobQueue()
    t = scheduler_main(Q[], shutdown)
    try
        function workflow()
            j1 = Job(add, 1, 2)
            jobs = []
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
        @test workflow() == 10
        sleep(2)
        @test length(Q[].queue) == 0
        @test length(Q[].running) == 0
        @test nv(Q[].g) == 6
        @test ne(Q[].g) == 6
    catch e
        throw(e)
    finally
        # shutdown scheduler
        put!(shutdown, true)
    end
end


@testset "workflow dynamics: while loop" begin
    shutdown = Channel{Bool}(1)
    Q[] = JobQueue()
    t = scheduler_main(Q[], shutdown)
    try
        function workflow()
            j = Job(add, 1, 1)
            while true
                j = Job(add, j.output, 1)
                if fetch(j) > 3
                    break
                end
            end
            return fetch(j)
        end
        @test workflow() == 4
        sleep(2)
        @test length(Q[].queue) == 0
        @test length(Q[].running) == 0
        @test nv(Q[].g) == 3
        @test ne(Q[].g) == 2
    catch e
        throw(e)
    finally
        # shutdown scheduler
        put!(shutdown, true)
    end
end
