@testitem "dynamics 1: for loop and conditional" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: Q
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

@testitem "dynamics 2: while loop" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: Q
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
