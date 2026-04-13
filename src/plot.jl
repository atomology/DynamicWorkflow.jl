using Printf
using GraphMakie
using NetworkLayout
using Makie
using Makie: Point2f, Figure

export draw_graph

"""
Compute top-down hierarchical positions for a DAG similar to DOT.
Each node's layer equals its longest path from any source.
Nodes within the same layer are evenly spaced on the x-axis.
Returns a `Vector{Point2f}` suitable for `graphplot(layout=...)`.
"""
function hierarchical_layout(g::AbstractGraph)
    n = nv(g)
    n == 0 && return Point2f[]

    # Assign each node to the deepest layer reachable from a source.
    # topological_sort_by_dfs returns vertices in topological order
    # (sources first), so we process parents before children directly.
    layers = zeros(Int, n)
    for v in topological_sort_by_dfs(g)
        for u in inneighbors(g, v)
            layers[v] = max(layers[v], layers[u] + 1)
        end
    end

    # Group nodes by layer.
    max_layer = maximum(layers; init=0)
    layer_nodes = [Int[] for _ in 0:max_layer]
    for v in 1:n
        push!(layer_nodes[layers[v] + 1], v)
    end

    # Assign 2D positions: y decreases with depth (top = 0), x spread evenly.
    positions = Vector{Point2f}(undef, n)
    for (li, nodes) in enumerate(layer_nodes)
        y = Float32(-(li - 1)*0.05)
        for (i, v) in enumerate(nodes)
            x = Float32(i) / Float32(length(nodes) + 1)
            positions[v] = Point2f(x, y)
        end
    end

    return positions
end

const STATUS_COLORS = Dict{JobState,Tuple{String,String}}(
    PENDING   => ("#CCCCCC", "#333333"),
    RUNNING   => ("#0072B2", "white"),
    COMPLETED => ("#009E73", "white"),
    FAILED    => ("#D55E00", "white"),
    CANCELLED => ("#CC79A7", "white"),
)

"""Return the Okabe-Ito background hex color for a job status."""
status_color(s::JobState) = STATUS_COLORS[s][1]

"""Return the text hex color (or "white") for a job status."""
status_text_color(s::JobState) = STATUS_COLORS[s][2]


"""Two-line node label: function name on line 1, last 5 chars of UUID on line 2."""
function node_label(j::Job)
    short_id = string(j.uuid)[end-4:end]
    return "$(j.name)\n$(short_id)"
end

"""Rectangle width sized to the longest line in the label."""
function node_width(label::String)
    CHAR_WIDTH = 10
    NODE_MIN_WIDTH = 60

    max_chars = maximum(length(line) for line in split(label, '\n'))
    return max(NODE_MIN_WIDTH, max_chars * CHAR_WIDTH)
end

"""
    $(SIGNATURES)
Draw workflow graph. Default layout is hierarchical, can take layouts defined in
NetworkLayout.jl.
"""
function draw_graph(q::JobQueue; layout=hierarchical_layout)
    NODE_HEIGHT  = 30
    FIG_SIZE = (1200, 800)

    g = q.g
    n = nv(g)
    n == 0 && return Figure()

    jobs    = [q.jobs[q.node2id[i]] for i in 1:n]
    labels  = map(node_label, jobs)
    colors  = map(j -> status_color(j.status), jobs)
    tcolors = map(j -> status_text_color(j.status), jobs)
    widths  = map(node_width, labels)
    sizes   = map(w -> Vec2f(w, NODE_HEIGHT), widths)

    f = Figure(size=FIG_SIZE)
    ax = Axis(f[1, 1])
    p = graphplot!(ax, g;
        layout          = layout,
        edge_width      = [2 for _ in 1:ne(g)],
        node_size       = sizes,
        node_marker     = Rect,
        node_color      = colors,
        nlabels         = labels,
        nlabels_align   = (:center, :center),
        nlabels_color   = tcolors,
        nlabels_distance = 0,
        nlabels_fontsize = 14,
        arrow_size      = 12,
        edge_color      = :gray,
    )
    deregister_interaction!(ax, :rectanglezoom)
    register_interaction!(ax, :ehover, EdgeHoverHighlight(p))
    register_interaction!(ax, :ndrag, NodeDrag(p))
    hidedecorations!(ax)
    hidespines!(ax)
    ax.title  = "JobQueue Graph"
    ax.aspect = DataAspect()
    return f
end

draw_graph(; layout=hierarchical_layout) = draw_graph(Q[]; layout=layout)
