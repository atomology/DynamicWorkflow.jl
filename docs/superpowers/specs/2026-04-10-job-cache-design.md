# Job Cache System Design

## Overview

Add a persistent cache system to the scheduler that stores job metadata (id, name, status, creation time, finish time, JobContext, input arguments, and output) to disk using JLD2. The cache accumulates across scheduler sessions and supports result reuse in new sessions.

## Data Types

### JobRecord

Immutable snapshot of a completed/failed job:

```julia
struct JobRecord
    uuid::UUID
    name::String
    status::JobState
    created_at::DateTime
    finished_at::Union{Nothing,DateTime}
    context::JobContext
    args::Tuple          # raw args (excluding JobContext)
    output::Any          # result value, error, or nothing
end
```

- `context` preserves the full `JobContext` (curr_id, parent_id, child_ids) for DAG reconstruction.
- `args` stores raw arguments before `OutputRef` resolution, preserving dependency structure. `JobContext` is excluded since it's stored separately.
- `output` stores the result value for successful jobs, the error for failed jobs, or `nothing` for cancelled/pending jobs that never ran.

### JobCache

Mutable container linking in-memory records to a disk file:

```julia
mutable struct JobCache
    records::Dict{UUID,JobRecord}
    path::String
end
```

## Timestamp Integration

Add `created_at::DateTime` field to `Job` struct, set to `now()` in both the `Job` constructor and `@job` macro. `finished_at` is recorded at the moment the scheduler transitions a job to completed or failed state.

## Cache Lifecycle

### start_scheduler(; cache_path="workflow_cache.jld2")

- If JLD2 file exists at `cache_path`, load existing records into `JobCache` (accumulation mode).
- If no file exists, create an empty `JobCache`.
- Store `JobCache` as a new field on `JobQueue`.

### On job completion/failure (in scheduler_main)

- Create a `JobRecord` snapshot from the `Job`.
- Add to `cache.records`.
- Incrementally write the single record to the JLD2 file, keyed by `string(uuid)`.

### On stop_scheduler()

- Full save of all records to disk for consistency.

### clear_cache!()

- Empties `cache.records` dict.
- Deletes the JLD2 file from disk.

### from_cache(uuid::UUID)

- Looks up a `JobRecord` by UUID from the loaded cache.
- Returns the stored output value, which can be used as input to new jobs in a new scheduler session.

## File Organization

### New file: src/cache.jl

Contains: `JobRecord`, `JobCache`, constructors, `clear_cache!`, `from_cache`, serialization helpers (load/save to JLD2).

### Include order in DynamicWorkflow.jl

```julia
include("util.jl")
include("job.jl")
include("cache.jl")   # new — after job.jl, before scheduler.jl
include("scheduler.jl")
include("plot.jl")
```

### New exports

`JobRecord`, `JobCache`, `from_cache`, `clear_cache!`

### New dependency

`JLD2` added to both `Project.toml` and `test/Project.toml`.

## Modified Files

| File | Changes |
|------|---------|
| `src/DynamicWorkflow.jl` | Add `using JLD2`, add `include("cache.jl")` |
| `src/job.jl` | Add `created_at::DateTime` field to `Job`, set in constructor and macro |
| `src/cache.jl` | New file with all cache types and functions |
| `src/scheduler.jl` | Add `cache::JobCache` to `JobQueue`, update `start_scheduler` with `cache_path` kwarg, write records on job completion/failure, full save on shutdown |
| `Project.toml` | Add JLD2 dependency |
| `test/Project.toml` | Add JLD2 dependency |
| `test/runtests.jl` | New cache test set |

**Unchanged:** `src/plot.jl`, `src/util.jl`

## JLD2 Storage Format

Each `JobRecord` is stored as a top-level key in the JLD2 file, keyed by `string(uuid)`. This allows incremental writes (add/overwrite one key) without rewriting the entire file.

## Testing Plan

New `@testset "cache"` block in `test/runtests.jl`:

1. **Basic caching** — run jobs, verify `JobRecord` fields (uuid, name, status, timestamps, args, output, context) are correctly populated.
2. **Disk persistence** — run jobs, stop scheduler, verify JLD2 file exists, restart scheduler with same `cache_path`, confirm records are loaded.
3. **Accumulation** — run jobs across two scheduler sessions with same cache path, verify all records from both sessions are present.
4. **from_cache** — retrieve a cached output and use it as input to a new job.
5. **clear_cache!** — verify records are emptied and file is deleted.
6. **Failed/cancelled jobs** — verify cache records capture correct status and `nothing` output for incomplete jobs.

Tests use `mktempdir()` for cache paths to avoid polluting the working directory.
