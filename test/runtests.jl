using DynamicWorkflow
using DynamicWorkflow: context, Q, task_args
using DynamicWorkflow: PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
using Test
# using TestItems
# using TestItemRunner

# @run_package_tests

function my_add(x, y)
    x + y
end

function my_sleep(n::Int)
    sleep(n)
    return n
end

function bad_job()
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

        uuids = map(j->j.uuid, jobs)
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

@testset "spawning jobs level 2" begin
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

        uuids = map(j->j.uuid, jobs)
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

@testset "visualization helpers" begin
    using Makie: Point2f
    @testset "hierarchical_layout" begin
        # empty graph
        g0 = SimpleDiGraph(0)
        @test DynamicWorkflow.hierarchical_layout(g0) == Point2f[]

        # single node — layer 0, y == 0
        g1 = SimpleDiGraph(1)
        pos1 = DynamicWorkflow.hierarchical_layout(g1)
        @test length(pos1) == 1
        @test pos1[1][2] == 0.0f0
        @test pos1[1][1] == 0.5f0   # single node centered at x=0.5

        # linear chain: 1 → 2 → 3 (y strictly decreasing top-down)
        g3 = SimpleDiGraph(3)
        add_edge!(g3, 1, 2); add_edge!(g3, 2, 3)
        pos3 = DynamicWorkflow.hierarchical_layout(g3)
        @test pos3[1][2] > pos3[2][2] > pos3[3][2]

        # diamond DAG: 1→2, 1→3, 2→4, 3→4
        gd = SimpleDiGraph(4)
        add_edge!(gd, 1, 2); add_edge!(gd, 1, 3)
        add_edge!(gd, 2, 4); add_edge!(gd, 3, 4)
        posd = DynamicWorkflow.hierarchical_layout(gd)
        @test posd[1][2] == 0.0f0    # source at top (layer 0)
        @test posd[2][2] == -1.0f0   # layer 1
        @test posd[3][2] == -1.0f0   # layer 1 (same as node 2)
        @test posd[4][2] == -2.0f0   # sink at bottom (layer 2)
        @test posd[2][1] < 0.5f0    # left node in layer 1
        @test posd[3][1] > 0.5f0    # right node in layer 1

        # longest-path wins: 1→3 (direct, depth 1) AND 1→2→3 (via 2, depth 2)
        # node 3 must end up at layer 2, not 1
        g_lp = SimpleDiGraph(3)
        add_edge!(g_lp, 1, 3)
        add_edge!(g_lp, 1, 2)
        add_edge!(g_lp, 2, 3)
        pos_lp = DynamicWorkflow.hierarchical_layout(g_lp)
        @test pos_lp[3][2] == -2.0f0
    end

    @testset "status_color and status_text_color" begin
        @test DynamicWorkflow.status_color(PENDING)   == "#CCCCCC"
        @test DynamicWorkflow.status_color(RUNNING)   == "#0072B2"
        @test DynamicWorkflow.status_color(COMPLETED) == "#009E73"
        @test DynamicWorkflow.status_color(FAILED)    == "#D55E00"
        @test DynamicWorkflow.status_color(CANCELLED) == "#CC79A7"

        @test DynamicWorkflow.status_text_color(PENDING)   == "#333333"
        @test DynamicWorkflow.status_text_color(RUNNING)   == "white"
        @test DynamicWorkflow.status_text_color(COMPLETED) == "white"
        @test DynamicWorkflow.status_text_color(FAILED)    == "white"
        @test DynamicWorkflow.status_text_color(CANCELLED) == "white"
    end

    @testset "node_width" begin
        # Short labels hit the minimum width (NODE_MIN_WIDTH = 60)
        @test DynamicWorkflow.node_width("hi\nab") == 60

        # Long labels exceed minimum (CHAR_WIDTH = 10)
        long_label = "a_very_long_function_name\nab12f"
        @test DynamicWorkflow.node_width(long_label) == length("a_very_long_function_name") * 10
    end
end

@testset "draw_graph" begin
    using Makie: Figure

    @testset "empty graph" begin
        start_scheduler()
        try
            f = draw_graph(Q[])
            @test f isa Figure
        finally
            stop_scheduler()
        end
    end

    @testset "graph with completed jobs" begin
        start_scheduler()
        try
            j1 = @job my_add(1, 2)
            j2 = @job my_add(3, 2)
            j3 = @job my_add(j1, j2)
            @test fetch(j3) == 8
            sleep(1)
            @test allcomplete()

            f = draw_graph(Q[])
            @test f isa Figure

            # verify node labels contain function names
            g = Q[].g
            @test nv(g) == 3
            jobs = [Q[].jobs[Q[].node2id[i]] for i in 1:nv(g)]
            labels = map(DynamicWorkflow.node_label, jobs)
            @test all(l -> contains(l, "my_add"), labels)
            @test all(l -> contains(l, "\n"), labels)

            # verify all completed jobs get the right color
            colors = map(j -> DynamicWorkflow.status_color(j.status), jobs)
            @test all(c -> c == "#009E73", colors)
        finally
            stop_scheduler()
        end
    end

    @testset "graph with mixed statuses" begin
        start_scheduler()
        try
            j1 = @job my_add(1, 2)
            j2 = @job my_sleep(3)
            sleep(1)
            # j1 should be completed, j2 still running
            @test status(j1) == COMPLETED
            @test status(j2) == RUNNING

            f = draw_graph(Q[])
            @test f isa Figure

            jobs = [Q[].jobs[Q[].node2id[i]] for i in 1:nv(Q[].g)]
            colors = map(j -> DynamicWorkflow.status_color(j.status), jobs)
            @test "#009E73" in colors  # at least one COMPLETED (green)
            @test "#0072B2" in colors  # at least one RUNNING (blue)

            sleep(3)
        finally
            stop_scheduler()
        end
    end

    @testset "convenience overload" begin
        start_scheduler()
        try
            j1 = @job my_add(1, 2)
            fetch(j1)
            sleep(1)
            f = draw_graph()
            @test f isa Figure
        finally
            stop_scheduler()
        end
    end
end

# function get_st()
#     return stacktrace()
# end
