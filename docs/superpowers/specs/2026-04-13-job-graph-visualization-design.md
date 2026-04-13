# Job Graph Visualization — Design Spec

**Date:** 2026-04-13
**Scope:** `src/plot.jl` only

## Problem

The current `draw_graph` function has three visual deficiencies:

1. **Layout is random-looking** — uses SFDP (force-directed), which places nodes with no regard for execution order.
2. **Node labels are too large** — text is rendered inside oversized circles, with job name and UUID crammed together.
3. **No status differentiation** — all nodes look identical regardless of job state.

## Goals

- Top-down hierarchical layout reflecting the DAG execution order
- Compact rectangle nodes sized to fit their label
- Color-coded nodes by job status using an academically appropriate palette
- Snapshot visualization (no live update required)
- No changes outside `src/plot.jl`; `draw_graph` signature unchanged

## Design

### 1. Hierarchical Layout

Replace the `SFDP` default with a custom `hierarchical_layout` function defined in `plot.jl`.

**Algorithm:**
1. Compute node layers using longest-path-from-source via BFS on the topological order. Each source node gets layer 0; each other node gets `max(parent_layer + 1)` over all parents.
2. Within each layer, distribute nodes evenly on the x-axis (spacing = 1.0 / (nodes_in_layer + 1)).
3. Y position = `-layer` (negative so layer 0 is at the top in Makie's coordinate system).
4. Return a `Point2f` vector indexed by node number.

This is a pure function of the graph; no external packages required. It handles DAGs correctly (including diamond/fan-in shapes).

The `layout` parameter default in `draw_graph` changes from `SFDP` to `hierarchical_layout`.

### 2. Rectangle Nodes Sized to Content

**Label format:** Two-line string — function name on line 1, last-5 chars of UUID on line 2.

**Node rendering:**
- `node_marker = Rect` — rectangular node shape
- `node_size` — per-node vector of `(width, height)` where width = `max(min_width, char_count * char_width)` based on the longer of the two label lines; height is fixed.
- Remove `ilabels` (text inside circle). Use `nlabels` with `nlabels_align = (:center, :center)` and `nlabels_distance = 0` to center labels over the node.

**Constants:**
```
NODE_HEIGHT = 30
NODE_MIN_WIDTH = 60
CHAR_WIDTH = 7   # approximate px per character in monospace
```

### 3. Status Colors (Okabe-Ito Palette)

| JobState  | Color      | Hex       | Text color |
|-----------|------------|-----------|------------|
| PENDING   | Light gray | `#CCCCCC` | `#333333`  |
| RUNNING   | Blue       | `#0072B2` | `white`    |
| COMPLETED | Green      | `#009E73` | `white`    |
| FAILED    | Orange-red | `#D55E00` | `white`    |
| CANCELLED | Pink       | `#CC79A7` | `white`    |

`node_color` is built as a per-node vector by looking up `q.jobs[q.node2id[i]].status` for each graph node `i`.

`nlabels_color` mirrors this: white for all states except PENDING (dark gray).

### 4. API

`draw_graph` signature is unchanged:

```julia
draw_graph(q::JobQueue; layout=hierarchical_layout)
draw_graph(; layout=hierarchical_layout)  # uses global Q[]
```

Callers that previously passed `layout=Buchheim` or `layout=SFDP` still work.

## Files Changed

| File | Change |
|------|--------|
| `src/plot.jl` | Full rewrite of rendering logic; add `hierarchical_layout`, `status_color`, `node_label` helpers |

## Out of Scope

- Live/animated updates as jobs transition state
- Tooltip on hover showing full UUID
- Legend for status colors
- Any changes to `src/job.jl`, `src/scheduler.jl`, or examples
