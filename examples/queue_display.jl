using DynamicWorkflow
import DynamicWorkflow: Q
# Test the JobQueue display functionality with different job statuses
start_scheduler()

# Create a simple job function
function test_func(ctx::JobContext, x, y)
    return x + y
end

function long_running_func(ctx::JobContext, x)
    sleep(10)
    return x
end

# Create a job that will fail
function failing_func(ctx::JobContext, x)
    error("This job is designed to fail")
end

# Create a job that will complete successfully
j1 = @job test_func(1, 2) # completed
j2 = @job long_running_func(1) # running
j3 = @job test_func(j1, j2) # pending
j4 = @job failing_func(1) # failed

sleep(1)

# Display the JobQueue
println("JobQueue display:")
display(Q[])

stop_scheduler()
