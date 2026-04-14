@testitem "spawning child jobs" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: context, JS
    t = start_scheduler()
    try
        function spawn_jobs()
            jobs = Job[]
            for i in 1:3
                j = @job my_add(1, i)
                push!(jobs, j)
            end
            return jobs
        end

        w = @job spawn_jobs()
        jobs = fetch(w)
        sleep(1)

        uuids = map(j -> j.uuid, jobs)
        @test w.uuid == context(w).curr_id
        @test isnothing(context(w).parent_id)
        @test uuids == context(w).child_ids
        @test all([context(j).parent_id == w.uuid for j in jobs])

        add_jobs(a, b, c) = a + b + c
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

@testitem "spawning jobs level 2" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: context, JS
    t = start_scheduler()
    try
        function spawn_jobs1()
            @job spawn_jobs2()
        end

        function spawn_jobs2()
            jobs = Job[]
            for i in 1:3
                j = @job my_add(1, i)
                push!(jobs, j)
            end
            return jobs
        end

        w1 = @job spawn_jobs1()
        wait(w1)

        w2 = result(w1)
        jobs = result(w2)

        uuids = map(j -> j.uuid, jobs)
        @test w1.uuid == context(w1).curr_id
        @test w2.uuid == context(w2).curr_id
        @test isnothing(context(w1).parent_id)
        @test context(w1).child_ids[1] == w2.uuid
        @test length(context(w1).child_ids) == 1
        @test context(w2).parent_id == w1.uuid
        @test uuids == context(w2).child_ids
        @test all([context(j).parent_id == w2.uuid for j in jobs])

        add_jobs(a, b, c) = a + b + c
        j = @job add_jobs(jobs[1], jobs[2], jobs[3])
        wait(j)
        @test fetch(j) == 9
        @test allcomplete()
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end
