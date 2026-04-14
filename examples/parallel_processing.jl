using DynamicWorkflow
using GLMakie

function mean(v::Vector)
    return sum(v) / length(v)
end

function process_chunk(data_chunk)
    println("Processing chunk of size ", length(data_chunk))
    # Simulate some computation
    sleep(0.1)
    return mean(data_chunk)
end

function create_parallel_jobs(chunks)
    return [@job process_chunk(chunk) for chunk in chunks]
end

start_scheduler()

# Create some sample data
data = rand(1000);
chunk_size = 200
chunks = [data[i:(i + chunk_size - 1)] for i in 1:chunk_size:length(data)];

# Process chunks in parallel
# Create a job that spawns parallel processing jobs
j1 = @job create_parallel_jobs(chunks)
chunk_jobs = fetch(j1)

# Combine results
result = mean([fetch(j) for j in chunk_jobs])

println("Final result: ", result)
println("Expected result: ", mean(data))

# Visualize the workflow
draw_graph()

# Clean up
stop_scheduler()
