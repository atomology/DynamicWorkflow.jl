# Remove JobContext from User Function Signatures

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the requirement for users to include `ctx::JobContext` as the first argument in their job functions, using task-local storage (TLS) for implicit parent-child tracking.

**Architecture:** Move `JobContext` from being a hidden first function argument to being a field on the `Job` struct. The scheduler sets the current context in Julia's `task_local_storage` before executing each job. The `@job` macro reads the parent context from TLS when called inside a running job, establishing parent-child links automatically. A `current_context()` function is exposed for rare cases where users need to inspect context.

**Tech Stack:** Julia, UUIDs, task_local_storage (stdlib)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/job.jl` | Modify | Add `context` field to `Job`, rewrite constructor and `@job` macro to use TLS instead of arg injection |
| `src/scheduler.jl` | Modify | Wrap job execution in TLS scope, remove ctx handling from `resolve_args!` |
| `test/runtests.jl` | Modify | Update all test functions to remove `ctx` parameter, update context assertions |
| `examples/basic_workflow.jl` | Modify | Remove `ctx` from function signatures |
| `examples/dynamic_workflow.jl` | Modify | Remove `ctx` from function signatures, remove explicit `ctx` passing to `@job` |
| `examples/parallel_processing.jl` | Modify | Remove `ctx` from function signatures, remove explicit `ctx` passing to `@job` |

---

### Task 1: Add `context` field to `Job` struct and update `JobContext` constructor

**Files:**
- Modify: `src/job.jl:95-101` (Job struct)
- Modify: `src/job.jl:230-235` (JobContext)
- Modify: `src/job.jl:242` (context accessor)
- Modify: `src/job.jl:216-222` (task_args)

- [ ] **Step 1: Write the failing test — Job struct has a context field**

Add to `test/runtests.jl` after the imports (line 3), a new testset:

```julia
@testset "job has context field" begin
    start_scheduler()
    try
        my_fn(x, y) = x + y
        j = @job my_fn(1, 2)
        @test j.context isa JobContext
        @test j.context.curr_id == j.uuid
        @test isnothing(j.context.parent_id)
        @test isempty(j.context.child_ids)
    finally
        stop_scheduler()
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `Job` has no field `context`, and `my_fn` fails because it expects `ctx::JobContext` as first arg.

- [ ] **Step 3: Add `context` field to `Job` struct**

In `src/job.jl`, change the `Job` struct (lines 95-101) to:

```julia
mutable struct Job <: AbstractJob
    name::String
    uuid::UUID
    context::JobContext
    task::WTask
    output::OutputRef
    status::JobState
end
```

- [ ] **Step 4: Update `context()` accessor**

In `src/job.jl`, change line 242 from:

```julia
context(j::Job) = j.task.args[1]
```

to:

```julia
context(j::Job) = j.context
```

- [ ] **Step 5: Update `task_args()` to return all args**

In `src/job.jl`, change `task_args` (lines 216-222) from:

```julia
function task_args(j::Job)
    if !isempty(j.task.args)
        return j.task.args[2:end]
    else
        return j.task.args
    end
end
```

to:

```julia
function task_args(j::Job)
    return j.task.args
end
```

- [ ] **Step 6: Commit**

```bash
git add src/job.jl
git commit -m "add context field to Job struct, update accessors"
```

---

### Task 2: Add `current_context()` TLS helper and export it

**Files:**
- Modify: `src/job.jl` (add function after JobContext definition)
- Modify: `src/job.jl:3` (exports)

- [ ] **Step 1: Write the failing test — `current_context()` returns nothing outside a job**

Add to `test/runtests.jl`:

```julia
@testset "current_context outside job" begin
    @test current_context() === nothing
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `current_context` not defined.

- [ ] **Step 3: Implement `current_context()`**

In `src/job.jl`, after the `JobContext` definition (after line 235), add:

```julia
"""
    current_context() -> Union{Nothing, JobContext}

Return the `JobContext` of the currently executing job, or `nothing` if called outside a job.
Uses task-local storage for implicit context propagation.
"""
function current_context()
    return get(task_local_storage(), :job_context, nothing)
end
```

- [ ] **Step 4: Export `current_context`**

In `src/job.jl` line 3, change:

```julia
export Job, @job, Unassigned, SuccessResult, FailResult, JobState, JobContext
```

to:

```julia
export Job, @job, Unassigned, SuccessResult, FailResult, JobState, JobContext, current_context
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: The `current_context outside job` test PASSES. Other tests may still fail.

- [ ] **Step 6: Commit**

```bash
git add src/job.jl
git commit -m "add current_context() TLS helper"
```

---

### Task 3: Rewrite `Job` constructor to not inject `JobContext` into args

**Files:**
- Modify: `src/job.jl:103-126` (Job constructor)

- [ ] **Step 1: Write the failing test — plain functions work with Job constructor**

Add to `test/runtests.jl`:

```julia
@testset "Job constructor with plain functions" begin
    start_scheduler()
    try
        plain_add(x, y) = x + y
        j1 = Job(plain_add, 1, 2)
        j2 = Job(plain_add, 3, 4)
        j3 = Job(plain_add, j1.output, j2.output)
        @test fetch(j1) == 3
        @test fetch(j2) == 7
        @test fetch(j3) == 10
        @test j3.context.curr_id == j3.uuid
    finally
        stop_scheduler()
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — constructor still injects `JobContext` into args and calls `plain_add(ctx, 1, 2)` which errors.

- [ ] **Step 3: Rewrite the `Job` constructor**

Replace the `Job` function constructor (lines 103-126) with:

```julia
function Job(f::Function, args...)
    @debug "[$(now())] creating job with function: $f"
    uuid = UUIDs.uuid4()
    @debug "uuid $uuid"
    if !isassigned(Q)
        throw("JobQueue not initialized. Use start_scheduler().")
    end
    name = string(f)
    # Check TLS for parent context
    parent_ctx = current_context()
    if parent_ctx !== nothing
        push!(parent_ctx.child_ids, uuid)
        ctx = JobContext(uuid, parent_ctx.curr_id, UUID[])
    else
        ctx = JobContext(uuid)
    end
    args = map(a -> a isa Job ? a.output : a, args)
    t = WTask(f, args...)
    output = OutputRef(uuid, Unassigned())
    j = Job(name, uuid, ctx, t, output, PENDING)
    enqueue!(j, Q[])
    return j
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: `Job constructor with plain functions` test PASSES. Old tests using `ctx` signature will still fail — that's expected, we fix them in Task 6.

- [ ] **Step 5: Commit**

```bash
git add src/job.jl
git commit -m "rewrite Job constructor to use TLS for parent tracking"
```

---

### Task 4: Rewrite `@job` macro to not inject `JobContext` into args

**Files:**
- Modify: `src/job.jl:141-172` (@job macro)

- [ ] **Step 1: Write the failing test — @job macro with plain functions**

Add to `test/runtests.jl`:

```julia
@testset "@job macro with plain functions" begin
    start_scheduler()
    try
        plain_mul(x, y) = x * y
        j1 = @job plain_mul(3, 4)
        j2 = @job plain_mul(5, 6)
        j3 = @job plain_mul(j1, j2)
        @test fetch(j1) == 12
        @test fetch(j2) == 30
        @test fetch(j3) == 360
        @test j1.context.curr_id == j1.uuid
    finally
        stop_scheduler()
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — macro still injects `JobContext` as first arg.

- [ ] **Step 3: Rewrite the `@job` macro**

Replace the `@job` macro (lines 141-172) with:

```julia
macro job(expr)
    @debug "[$(now())] creating job with expression: $expr"
    name = string(expr.args[1])
    f = esc(expr.args[1])
    args = map(a -> esc(a), expr.args[2:end])
    return quote
        if !isassigned(Q)
            throw("JobQueue not initialized. Use start_scheduler().")
        end
        uuid = UUIDs.uuid4()
        outputref = OutputRef(uuid, Unassigned())
        eval_args = ($(args...),)
        parsed_args = map(a -> a isa Job ? a.output : a, eval_args)
        # Check TLS for parent context
        parent_ctx = current_context()
        if parent_ctx !== nothing
            push!(parent_ctx.child_ids, uuid)
            ctx = JobContext(uuid, parent_ctx.curr_id, UUID[])
        else
            ctx = JobContext(uuid)
        end
        job = Job($name, uuid, ctx, WTask($f, parsed_args...), outputref, PENDING)
        enqueue!(job, Q[])
        job
    end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: `@job macro with plain functions` test PASSES.

- [ ] **Step 5: Commit**

```bash
git add src/job.jl
git commit -m "rewrite @job macro to use TLS for parent tracking"
```

---

### Task 5: Update scheduler to set TLS before job execution and remove ctx from resolve_args

**Files:**
- Modify: `src/scheduler.jl:147-175` (resolve_args!)
- Modify: `src/job.jl:254-259` (run!)

- [ ] **Step 1: Write the failing test — TLS-based parent-child tracking**

Add to `test/runtests.jl`:

```julia
@testset "TLS parent-child tracking" begin
    start_scheduler()
    try
        function spawner()
            jobs = Job[]
            for i in 1:3
                plain_add(x, y) = x + y
                j = @job plain_add(1, i)
                push!(jobs, j)
            end
            return jobs
        end

        w = @job spawner()
        jobs = fetch(w)
        sleep(1)

        uuids = map(j -> j.uuid, jobs)
        @test w.context.curr_id == w.uuid
        @test isnothing(w.context.parent_id)
        @test uuids == w.context.child_ids
        @test all(j -> j.context.parent_id == w.uuid, jobs)
    finally
        stop_scheduler()
    end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: FAIL — `spawner` runs but `@job` inside it doesn't see a parent context because TLS isn't set by the scheduler yet.

- [ ] **Step 3: Update `run!` to set TLS before executing the job**

In `src/job.jl`, replace the `run!` function (lines 254-259) with:

```julia
function run!(job::Job)
    ctx = job.context
    original_f = job.task.f
    original_args = job.task.args
    # Wrap execution to set TLS context
    wrapped() = task_local_storage(:job_context, ctx) do
        invokelatest(original_f, original_args...)
    end
    job.task.task = Task(wrapped)
    job.task.task.sticky = false
    schedule(job.task.task)
    yield()
end
```

- [ ] **Step 4: Update `resolve_args!` to not prepend ctx**

In `src/scheduler.jl`, replace `resolve_args!` (lines 147-175) with:

```julia
function resolve_args!(job::Job, q::JobQueue)::Union{Nothing,Vector{UUID}}
    @debug "resolving dependencies for job: $(job.name), uuid: $(job.uuid)"
    new_args = Any[]
    depends_on = UUID[]
    for arg in task_args(job)
        if !(arg isa OutputRef)
            push!(new_args, arg)
            continue
        end

        if arg.result isa Unassigned
            @debug "job $(job.uuid) dependencies not fulfilled, will not run!"
            return
        elseif arg.result isa SuccessResult
            push!(new_args, result(arg))
            push!(depends_on, arg.uuid)
        else
            @error "job $(job.uuid) dependencies errored, stop queue!"
        end
    end
    @debug "resolved arguments: $new_args"
    job.task.args = Tuple(new_args)
    return depends_on
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: `TLS parent-child tracking` test PASSES.

- [ ] **Step 6: Commit**

```bash
git add src/job.jl src/scheduler.jl
git commit -m "set TLS context in scheduler, remove ctx from resolve_args"
```

---

### Task 6: Update existing tests to use plain functions

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Remove `ctx::JobContext` from all test helper functions**

Change the test helper functions at the top of `test/runtests.jl`:

From:
```julia
function my_add(ctx::JobContext, x, y)
    x + y
end

function my_sleep(ctx::JobContext, n::Int)
    sleep(n)
    return n
end

function bad_job(ctx::JobContext)
    a = []
    return a[1]
end
```

To:
```julia
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
```

- [ ] **Step 2: Update "spawning child jobs" testset**

Replace lines 113-148 with:

```julia
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
```

- [ ] **Step 3: Update "spawning jobs level 2" testset**

Replace lines 150-195 with:

```julia
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
```

- [ ] **Step 4: Run full test suite**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: ALL tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test/runtests.jl
git commit -m "update tests to use plain functions without JobContext arg"
```

---

### Task 7: Update examples

**Files:**
- Modify: `examples/basic_workflow.jl`
- Modify: `examples/dynamic_workflow.jl`
- Modify: `examples/parallel_processing.jl`

- [ ] **Step 1: Update `examples/basic_workflow.jl`**

Change:
```julia
function add(ctx::JobContext, x, y)
    println("Adding $x and $y")
    x + y
end

function multiply(ctx::JobContext, x, y)
    println("Multiplying $x and $y")
    x * y
end
```

To:
```julia
function add(x, y)
    println("Adding $x and $y")
    x + y
end

function multiply(x, y)
    println("Multiplying $x and $y")
    x * y
end
```

- [ ] **Step 2: Update `examples/dynamic_workflow.jl`**

Change `my_add`:
```julia
function my_add(x, y)
    x + y
end
```

Change `fibonacci`:
```julia
function fibonacci(n)
    if n <= 1
        return n
    end

    # Create new jobs dynamically
    j1 = @job fibonacci(n - 1)
    j2 = @job fibonacci(n - 2)

    # Wait for both jobs to complete and add their results
    fetch(j1) + fetch(j2)
end
```

- [ ] **Step 3: Update `examples/parallel_processing.jl`**

Change:
```julia
function process_chunk(ctx::JobContext, data_chunk)
    println("Processing chunk of size ", length(data_chunk))
    sleep(0.1)
    mean(data_chunk)
end

function create_parallel_jobs(ctx::JobContext, chunks)
    [@job process_chunk(ctx, chunk) for chunk in chunks]
end
```

To:
```julia
function process_chunk(data_chunk)
    println("Processing chunk of size ", length(data_chunk))
    sleep(0.1)
    mean(data_chunk)
end

function create_parallel_jobs(chunks)
    [@job process_chunk(chunk) for chunk in chunks]
end
```

- [ ] **Step 4: Commit**

```bash
git add examples/basic_workflow.jl examples/dynamic_workflow.jl examples/parallel_processing.jl
git commit -m "update examples to use plain functions without JobContext arg"
```

---

### Task 8: Update docstrings and macro documentation

**Files:**
- Modify: `src/job.jl` (docstrings for @job macro, Job constructor)

- [ ] **Step 1: Update @job macro docstring**

Replace the docstring above the `@job` macro with:

```julia
"""
    @job f(args...)

Wrap a function call and create a job which will be enqueued immediately to the global JobQueue.
Functions are plain Julia functions — no special first argument needed.

Parent-child relationships are tracked automatically via task-local storage when
`@job` is called inside a running job.

# Examples
```julia
my_add(x, y) = x + y
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
j3 = @job my_add(j1, j2)  # j3 depends on j1 and j2
```
"""
```

- [ ] **Step 2: Update Job struct docstring**

Update the docstring above the `Job` struct to mention the `context` field.

- [ ] **Step 3: Run full test suite one final time**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: ALL tests PASS.

- [ ] **Step 4: Commit**

```bash
git add src/job.jl
git commit -m "update docstrings for new context-free API"
```

---

### Task 9: Clean up — remove dead code paths for old JobContext-as-argument pattern

**Files:**
- Modify: `src/job.jl`

- [ ] **Step 1: Verify no remaining references to the old pattern**

Search for any remaining code that checks `isa(args[1], JobContext)` or similar patterns in `src/`. There should be none after Tasks 3-4.

Run: `grep -rn "JobContext" src/`
Expected: Only the struct definition, `current_context()`, export line, and `context()` accessor remain.

- [ ] **Step 2: Remove `dependencies()` function if unused elsewhere**

The `dependencies` function (job.jl:244-249) filters `AbstractResult` from `job.task.args`. Check if it's used anywhere:

Run: `grep -rn "dependencies" src/ test/`
Expected: Only the definition. If unused, remove it.

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/guoyuan/codes/projects/atomology/feature-context && julia --project -e 'using Pkg; Pkg.test()'`
Expected: ALL tests PASS.

- [ ] **Step 4: Commit**

```bash
git add src/job.jl
git commit -m "remove unused dependencies function"
```
