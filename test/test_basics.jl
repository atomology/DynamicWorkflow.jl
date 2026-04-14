@testitem "basics: job macros" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: JS
    t = start_scheduler()
    try
        j1 = @job my_add(1, 2)
        j2 = @job my_add(3, 2)
        j3 = @job my_add(j1, j2)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        sleep(2)
        @test length(JS[].pending) == 0
        @test length(JS[].running) == 0
        @test allcomplete()
        @test length(JS[].completed) == 3
        @test nv(JS[].g) == 3
        @test ne(JS[].g) == 2
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end

@testitem "basics: job function" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: JS
    t = start_scheduler()
    try
        j1 = Job(my_add, 1, 2)
        j2 = Job(my_add, 3, 2)
        j3 = Job(my_add, j1.output, j2.output)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
        sleep(2)
        @test length(JS[].pending) == 0
        @test length(JS[].running) == 0
        @test allcomplete()
        @test length(JS[].completed) == 3
        @test nv(JS[].g) == 3
        @test ne(JS[].g) == 2
    catch e
        throw(e)
    finally
        stop_scheduler()
    end
end
