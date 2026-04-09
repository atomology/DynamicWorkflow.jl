# DynamicWorkflow.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://atomology.github.io/DynamicWorkflow.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://atomology.github.io/DynamicWorkflow.jl/dev/)

**A flexible, lightweight scheduler for dynamic workflows in Julia.**

DynamicWorkflow.jl provides a powerful and intuitive way to create and manage dynamic workflows in Julia. It allows you to wrap functions into jobs, manage dependencies between them, and execute them efficiently using Julia's threading capabilities.

## Installation

```julia
using Pkg
Pkg.add("DynamicWorkflow")
```

## Features

1. **Job Management**
   - Wrap any function into a `Job` for scheduling
   - Automatic dependency resolution between jobs
   - Support for dynamic job creation during execution
   - Job status tracking and result management

2. **Flexible Workflow Creation**
   - Use native Julia control flow (`while`, `if`, `for`)
   - Create new jobs from within existing jobs
   - Build complex dependency graphs automatically


## Quick Start

```julia
using DynamicWorkflow

# Define a job function
function my_add(ctx::JobContext, x, y)
    x + y
end

# Start the scheduler
start_scheduler()

# Create and schedule jobs
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
j3 = @job my_add(j1, j2)  # j3 depends on j1 and j2

# Monitor and get results
status(j3)  # Check job status
fetch(j3)   # Get result (blocking)
result(j3)  # Get result (non-blocking)

# Visualize the workflow
using GLMakie
draw_graph()
stop_scheduler() # exit scheulder
```

You can directly use jobs with corresponding outputs as arguments to build workflows.
```jl
j3 = @job my_add(j1, j2)
```

See the `examples/` directory for more detailed examples of using DynamicWorkflow.jl.


## License

This project is licensed under the GNU v3 License.
