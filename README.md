# DynamicWorkflow.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://atomology.github.io/DynamicWorkflow.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://atomology.github.io/DynamicWorkflow.jl/dev/)
[![CI](https://github.com/atomology/DynamicWorkflow.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/atomology/DynamicWorkflow.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/atomology/DynamicWorkflow.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/atomology/DynamicWorkflow.jl)

**A flexible, lightweight scheduler for dynamic workflows in Julia.**

DynamicWorkflow.jl provides a powerful and intuitive way to create and manage dynamic
workflows in Julia. It allows you to wrap functions into jobs, resolve data dependencies
automatically and execute jobs in parallel using Julia's threading capabilities.

## Installation

```julia
using Pkg
Pkg.add("DynamicWorkflow")
```

## Features

- Simple job scheduling by wrapping functions with `@job`.
- Dynamic workflow based on local_task_storage using native Julia control flow.
- Job status tracking, workflow graph visualization.


## Quick Start

```julia
using DynamicWorkflow

# Define a job function
function my_add(x, y)
    x + y
end

# Start the scheduler
start_scheduler()

# Create and schedule jobs
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
j3 = @job my_add(j1, j2)  # j3 depends on j1 and j2

# Monitor and get results
status(j3)  # check job status
result(j3)  # get result (non-blocking call)
fetch(j3)   # get result (blocking call)

```

Dynamic workflow
```julia

function create_parallel_jobs(v)
    [@job my_add(e, 1) for e in v]
end

v = [1,2,3]
master_job = @job create_parallel_jobs(v)
spawned_jobs = fetch(master_job)

new_v = [fetch(j) for j in spawned_jobs]

```

The workflow graph can be visualized by adding a Makie backend.
```julia
# Use any compatible Makie backend like CairoMakie or GLMakie
using GLMakie
draw_graph()

# Exit scheduler
stop_scheduler()
```

See the `examples/` directory for more workflow examples.


## License

This project is licensed under the GNU v3 License.
