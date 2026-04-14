using DynamicWorkflow
using GLMakie


function my_add(x, y)
    return x + y
end

function sum_n(n)
    j = @job my_add(1, 2)
    if n < 3
        return j
    end
    for i in 3:n
        j = @job my_add(j, i)
    end
    return j
end

function fibonacci(n)
    if n <= 1
        return n
    end

    # Create new jobs dynamically
    j1 = @job fibonacci(n - 1)
    j2 = @job fibonacci(n - 2)

    # Wait for both jobs to complete and add their results
    return fetch(j1) + fetch(j2)
end


# Start the scheduler
start_scheduler()

n = 5
# 1. generate a series of jobs using while loop
j1 = sum_n(n)
println("sum of first $n positive integers: ", fetch(j1))

# 2. generate jobs recursively
j2 = @job fibonacci(n)
println("Fibonacci($n) = ", fetch(j2))

# Visualize the workflow
draw_graph()

stop_scheduler()
