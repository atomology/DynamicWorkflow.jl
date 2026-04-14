# API Reference

## Core Types

```@docs
DynamicWorkflow.Job
DynamicWorkflow.JobContext
DynamicWorkflow.JobState
DynamicWorkflow.OutputRef
DynamicWorkflow.WTask
DynamicWorkflow.JobScheduler
DynamicWorkflow.SuccessResult
DynamicWorkflow.FailResult
DynamicWorkflow.Unassigned
```

## Main Functions

```@docs
DynamicWorkflow.@job
DynamicWorkflow.start_scheduler
DynamicWorkflow.stop_scheduler
DynamicWorkflow.status
DynamicWorkflow.result
DynamicWorkflow.fetch
DynamicWorkflow.allcomplete
DynamicWorkflow.cancel!
DynamicWorkflow.istasksuccess
DynamicWorkflow.isalive
DynamicWorkflow.current_context
DynamicWorkflow.run!
DynamicWorkflow.head
DynamicWorkflow.task_args
DynamicWorkflow.context
```

## Visualization

```@docs
DynamicWorkflow.draw_graph
DynamicWorkflow.hierarchical_layout
DynamicWorkflow.status_color
DynamicWorkflow.status_text_color
DynamicWorkflow.node_label
DynamicWorkflow.node_width
```

## Internals

```@docs
DynamicWorkflow._make_context
```
