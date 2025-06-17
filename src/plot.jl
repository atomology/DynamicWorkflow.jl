using Printf
using GraphMakie
using NetworkLayout
using Makie

export draw_graph, Buchheim, SFDP

function job_name(j::Job)
    return @sprintf "%s %s" j.name string(j.uuid)[end-4:end]
end

function draw_graph(q::JobQueue; layout=SFDP)
    g = q.g
    labels = map(i -> job_name(q.jobs[q.node2id[i]]), 1:nv(g))

    f, ax, p = graphplot(g;
        edge_width=[3 for i in 1:ne(g)],
        node_size=[20 for i in 1:nv(g)],
        ilabels=labels,
        layout=layout(),
        arrow_size=15,
        edge_color=:gray,
    )
    deregister_interaction!(ax, :rectanglezoom)
    register_interaction!(ax, :nhover, NodeHoverHighlight(p))
    register_interaction!(ax, :ehover, EdgeHoverHighlight(p))
    register_interaction!(ax, :ndrag, NodeDrag(p))
    hidedecorations!(ax)
    hidespines!(ax)
    ax.title = "JobQueue Graph"
    ax.aspect = DataAspect()
    return f
end
draw_graph(;layout=SFDP) = draw_graph(Q[];layout=SFDP)
