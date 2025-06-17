using DynamicWorkflow
using GLMakie

# Define some simple job functions
function add(ctx::JobContext, x, y)
    println("Adding $x and $y")
    x + y
end

function multiply(ctx::JobContext, x, y)
    println("Multiplying $x and $y")
    x * y
end

# Start the scheduler
start_scheduler()

# Create a simple workflow: (2 + 3) * (4 + 5)
j1 = @job add(2, 3)
j2 = @job add(4, 5)
j3 = @job multiply(j1, j2)

# Wait for completion and get result
result = fetch(j3)
println("Final result: ", result)

# Visualize the workflow
draw_graph()

# Clean up
stop_scheduler()