@testitem "initialization" begin
    using DynamicWorkflow
    @test !isqueuealive()
    @test !allcomplete()
end

@testitem "scheduler lifecycle" begin
    using DynamicWorkflow
    using DynamicWorkflow: Q
    start_scheduler()
    sleep(1)
    t = Q[].mainloop
    @test istaskstarted(t)
    stop_scheduler()
    sleep(1)
    @test istaskdone(t)
end
