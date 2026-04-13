# TestItemRunner Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the monolithic `test/runtests.jl` to TestItemRunner.jl so individual test files can be run with `julia -t 2 --project=test test/runtests.jl <pattern>`.

**Architecture:** Split the single `@testset`-based file into focused `@testitem` files grouped by concern. A shared `@testsetup` module holds helper functions. `runtests.jl` becomes a thin runner that filters by `ARGS` pattern.

**Tech Stack:** Julia, TestItemRunner.jl, TestItems.jl (provides `@testitem`/`@testsetup`)

---

## File Structure

**Modified:**
- `test/Project.toml` — add TestItemRunner dependency
- `test/runtests.jl` — replace with `@run_package_tests` + ARGS filter

**Created:**
- `test/setup.jl` — `@testsetup module TestHelpers` (shared helper functions)
- `test/test_scheduler.jl` — scheduler initialization and lifecycle tests
- `test/test_basics.jl` — job macro and constructor tests
- `test/test_job_status.jl` — job status, cancel, and failure tests
- `test/test_child_jobs.jl` — child job spawning (levels 1 and 2)
- `test/test_dynamics.jl` — dynamic workflow tests (for loop, while loop)

---

## Task 1: Add TestItemRunner to test/Project.toml

**Files:**
- Modify: `test/Project.toml`

- [ ] **Step 1: Add TestItemRunner via Pkg from the test project**

```bash
julia --project=test -e 'using Pkg; Pkg.add("TestItemRunner")'
```

Expected output: resolves and installs TestItemRunner (and its TestItems.jl dependency).

- [ ] **Step 2: Verify test/Project.toml now has the dependency**

Open `test/Project.toml` and confirm a `[deps]` entry for `TestItemRunner` was added (UUID will be filled in automatically by Pkg).

- [ ] **Step 3: Commit**

```bash
git add test/Project.toml
git commit -m "test: add TestItemRunner dependency"
```

---

## Task 2: Replace test/runtests.jl with TestItemRunner runner

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Replace the entire file content**

```julia
using TestItemRunner

@run_package_tests filter = ti -> isempty(ARGS) || any(occursin(pat, ti.filename) for pat in ARGS)
```

`@run_package_tests` scans all `.jl` files in the package tree for `@testitem` macros and runs them. The `filter` function receives each `TestItem` (with `.filename` as the absolute path) and returns `true` to include it. When `ARGS` is empty (e.g. `Pkg.test()`), all tests run.

- [ ] **Step 2: Verify it runs with zero test items (vacuously passes)**

```bash
julia -t 2 --project=test test/runtests.jl
```

Expected output: "Test Summary: ... | 0 passed" or similar — no errors. This confirms TestItemRunner is wired up before any test files exist.

- [ ] **Step 3: Commit**

```bash
git add test/runtests.jl
git commit -m "test: switch runtests.jl to TestItemRunner"
```

---

## Task 3: Create test/setup.jl with shared helper functions

**Files:**
- Create: `test/setup.jl`

- [ ] **Step 1: Write the setup file**

```julia
@testsetup module TestHelpers
    export my_add, my_sleep, bad_job

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
end
```

`@testsetup` modules are evaluated once per test run and shared across any `@testitem` that declares `setup=[TestHelpers]`. No `using TestItems` is needed — TestItemRunner provides the macro when loading the file.

- [ ] **Step 2: Commit**

```bash
git add test/setup.jl
git commit -m "test: add shared TestHelpers testsetup"
```

---

## Task 4: Create test/test_scheduler.jl

**Files:**
- Create: `test/test_scheduler.jl`

- [ ] **Step 1: Write the file**

```julia
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
```

- [ ] **Step 2: Run to verify these two items pass**

```bash
julia -t 2 --project=test test/runtests.jl test_scheduler
```

Expected: 2 test items pass, no failures.

- [ ] **Step 3: Commit**

```bash
git add test/test_scheduler.jl
git commit -m "test: add scheduler testitem file"
```

---

## Task 5: Create test/test_basics.jl

**Files:**
- Create: `test/test_basics.jl`

- [ ] **Step 1: Write the file**

```julia
@testitem "basics: job macros" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: Q
    t = start_scheduler()
    try
        j1 = @job my_add(1, 2)
        j2 = @job my_add(3, 2)
        j3 = @job my_add(j1, j2)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
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

@testitem "basics: job function" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: Q
    t = start_scheduler()
    try
        j1 = Job(my_add, 1, 2)
        j2 = Job(my_add, 3, 2)
        j3 = Job(my_add, j1.output, j2.output)
        @test fetch(j1) == 3
        @test fetch(j2) == 5
        @test fetch(j3) == 8
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
```

- [ ] **Step 2: Run to verify**

```bash
julia -t 2 --project=test test/runtests.jl test_basics
```

Expected: 2 test items pass.

- [ ] **Step 3: Commit**

```bash
git add test/test_basics.jl
git commit -m "test: add basics testitem file"
```

---

## Task 6: Create test/test_job_status.jl

**Files:**
- Create: `test/test_job_status.jl`

- [ ] **Step 1: Write the file**

```julia
@testitem "job status" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: Q, PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
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
```

- [ ] **Step 2: Run to verify**

```bash
julia -t 2 --project=test test/runtests.jl test_job_status
```

Expected: 1 test item passes.

- [ ] **Step 3: Commit**

```bash
git add test/test_job_status.jl
git commit -m "test: add job status testitem file"
```

---

## Task 7: Create test/test_child_jobs.jl

**Files:**
- Create: `test/test_child_jobs.jl`

- [ ] **Step 1: Write the file**

```julia
@testitem "spawning child jobs" setup=[TestHelpers] begin
    using DynamicWorkflow
    using DynamicWorkflow: context, Q
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
    using DynamicWorkflow: context, Q
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
```

- [ ] **Step 2: Run to verify**

```bash
julia -t 2 --project=test test/runtests.jl test_child_jobs
```

Expected: 2 test items pass.

- [ ] **Step 3: Commit**

```bash
git add test/test_child_jobs.jl
git commit -m "test: add child jobs testitem file"
```

---

## Task 8: Create test/test_dynamics.jl

**Files:**
- Create: `test/test_dynamics.jl`

- [ ] **Step 1: Write the file**

```julia
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
```

- [ ] **Step 2: Run to verify**

```bash
julia -t 2 --project=test test/runtests.jl test_dynamics
```

Expected: 2 test items pass.

- [ ] **Step 3: Commit**

```bash
git add test/test_dynamics.jl
git commit -m "test: add dynamics testitem file"
```

---

## Task 9: Run full suite and verify Pkg.test still works

- [ ] **Step 1: Run all tests via the new runner**

```bash
julia -t 2 --project=test test/runtests.jl
```

Expected: all 9 test items pass (initialization, scheduler lifecycle, basics: job macros, basics: job function, job status, spawning child jobs, spawning jobs level 2, dynamics 1, dynamics 2).

- [ ] **Step 2: Verify Pkg.test still works (used by CI)**

```bash
julia --project -t 2 -e 'using Pkg; Pkg.test()'
```

Expected: same 9 test items pass. `Pkg.test()` runs `test/runtests.jl` with no ARGS, so the filter passes everything through.

- [ ] **Step 3: Verify focused test run by file pattern**

```bash
julia -t 2 --project=test test/runtests.jl test_basics
```

Expected: only 2 items run ("basics: job macros", "basics: job function"). Other test items are skipped.

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: complete TestItemRunner migration"
```

---

## Notes

- Always pass `-t 2` — the scheduler relies on multithreading and tests will hang without it.
- `@testitem` blocks get `@test`, `@testset`, etc. from `Test` automatically (TestItems imports `Test` by default via `default_imports=true`). No need to write `using Test` inside each block.
- `@testsetup` modules are loaded once per test session and shared, so helper functions are not re-evaluated for every test item.
- The `ARGS` filter matches against the absolute file path, so partial names like `dynamics`, `basics`, or `child` all work as patterns.
