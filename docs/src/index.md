# DynamicWorkflow.jl

A flexible, lightweight scheduler for dynamic workflows in Julia.

## Overview

DynamicWorkflow.jl provides a powerful and intuitive way to create and manage dynamic workflows in Julia. It allows you to wrap functions into jobs, manage dependencies between them, and execute them efficiently using Julia's threading capabilities.

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

# Clean up
stop_scheduler()
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

## Examples

See the [examples](https://github.com/atomology/DynamicWorkflow.jl/tree/main/examples) directory for more detailed examples of using DynamicWorkflow.jl. 