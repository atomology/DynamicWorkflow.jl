# DynamicWorkflow.jl

A flexible, lightweight scheduler for dynamic workflows in Julia.

[DynamicWorkflow.jl](https://github.com/atomology/DynamicWorkflow.jl) wraps functions into jobs, automatically resolves dependencies, and executes them in parallel using Julia's threading.
Jobs can spawn child jobs during execution, enabling dynamic job scheduling with native Julia control flow.

## Examples

See [examples](https://github.com/atomology/DynamicWorkflow.jl/tree/main/examples) directory.
