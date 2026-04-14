@testitem "initialization" begin
    using DynamicWorkflow
    stop_scheduler() # stop any running scheduler
    sleep(0.5)
    @test !isalive()
    start_scheduler()
    sleep(0.5)
    @test isalive()
    @test allcomplete() # new JobScheduler should be empty
    stop_scheduler()
    sleep(0.5)
    @test !isalive()
    @test allcomplete()
end

@testitem "scheduler lifecycle" begin
    using DynamicWorkflow
    using DynamicWorkflow: JS
    start_scheduler()
    sleep(1)
    t = JS[].mainloop
    @test istaskstarted(t)
    stop_scheduler()
    sleep(1)
    @test istaskdone(t)
end
