function draw_graph(q::JobQueue)
    g = q.g
    labels = map(i -> string(q.node2id[i])[end-4:end], 1:nv(g))
    f, ax, p = graphplot(g;
        ilabels=labels,
        method=:spring,
        arrow_size=15,
        edge_color=:gray,
    )
    ax.title = "Job Graphs"
    hidedecorations!(ax)
    hidespines!(ax)
    ax.aspect = DataAspect()
    return f
end
