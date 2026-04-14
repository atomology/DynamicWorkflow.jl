@testitem "job status" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: JS, PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
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
        @test isalive(JS[])
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end
