# DynamicWorkflow.jl

**A flexible, lighweight scheduler for dynamic workflows.**

## Features

1. Wrap (almost) any functions into a `Job` and schedule to run on available threads.
2. Easy dependency resolving, just use `Job` as the arguments.
3. Write workflow using native Julia control statements, i.e. `while`, `if`, `for`.
4. Create new jobs from within a job.

## Examples

Define your job in a function, which ideally should be [pure](https://en.wikipedia.org/wiki/Pure_function#:~:text=In%20computer%20programming%2C%20a%20pure,i.e.%2C%20referential%20transparency)%2C%20and).
The first argument should always be of type `JobContext`.
```jl
function my_add(ctx::JobContext, x, y)
    x + y
end
```

Start job scheduler.
```jl
start_scheduler()
```

Create and immediately enqueue the job by using `@job` macro.
```jl
j1 = @job my_add(1, 2)
j2 = @job my_add(3, 2)
```

You can directly use jobs with corresponding outputs as arguments to build workflows.
```jl
j3 = @job my_add(j1, j2)
```

Monitor jobs and fetch results.
```jl
status(j3) # one of PENDING, RUNNING, CANCELLED, COMPLETED, FAILED
fetch(j3)  # blocking call to get result
result(j3) # non-blocking, the result may not be ready, in which case Unassigned will be returned.
```

Monitor the whole workflow.
```jl
allcomplete()  # return true if no more jobs pending and all jobs completed

using GLMakie
draw_graph()   # draw the dependency graph using one of the Makies.jl backends.
```






