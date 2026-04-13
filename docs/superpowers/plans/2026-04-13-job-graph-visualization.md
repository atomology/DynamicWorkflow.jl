# Job Graph Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the force-directed graph layout in `src/plot.jl` with a top-down hierarchical layout, compact rectangle nodes sized to their label, and Okabe-Ito status colors.

**Architecture:** All changes are in `src/plot.jl`. Three new pure helper functions (`hierarchical_layout`, `status_color`/`status_text_color`, `node_label`/`node_width`) are added and tested independently, then wired into a rewritten `draw_graph`. Unit tests for pure functions are added to `test/runtests.jl`.

**Tech Stack:** Julia, GraphMakie 0.x, Makie 0.22, Graphs.jl, NetworkLayout (already in use)

---

## File Map

| File | Change |
|------|--------|
| `src/plot.jl` | Rewrite: add `hierarchical_layout`, color/label helpers, rewrite `draw_graph` |
| `test/runtests.jl` | Add `@testset "visualization helpers"` block for pure function unit tests |

---

### Task 1: Add `hierarchical_layout` + tests

**Files:**
- Modify: `src/plot.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

  Append to `test/runtests.jl` (before the final comment block):

  ```julia
  @testset "visualization helpers" begin
      using Graphs: SimpleDiGraph, add_edge!
      import DynamicWorkflow

      @testset "hierarchical_layout" begin
          # empty graph
          g0 = SimpleDiGraph(0)
          @test DynamicWorkflow.hierarchical_layout(g0) == Point2f[]

          # single node — layer 0, y == 0
          g1 = SimpleDiGraph(1)
          pos1 = DynamicWorkflow.hierarchical_layout(g1)
          @test length(pos1) == 1
          @test pos1[1][2] == 0.0f0

          # linear chain: 1 → 2 → 3 (y strictly decreasing top-down)
          g3 = SimpleDiGraph(3)
          add_edge!(g3, 1, 2); add_edge!(g3, 2, 3)
          pos3 = DynamicWorkflow.hierarchical_layout(g3)
          @test pos3[1][2] > pos3[2][2] > pos3[3][2]

          # diamond DAG: 1→2, 1→3, 2→4, 3→4
          gd = SimpleDiGraph(4)
          add_edge!(gd, 1, 2); add_edge!(gd, 1, 3)
          add_edge!(gd, 2, 4); add_edge!(gd, 3, 4)
          posd = DynamicWorkflow.hierarchical_layout(gd)
          @test posd[1][2] == 0.0f0    # source at top (layer 0)
          @test posd[2][2] == -1.0f0   # layer 1
          @test posd[3][2] == -1.0f0   # layer 1 (same as node 2)
          @test posd[4][2] == -2.0f0   # sink at bottom (layer 2)
      end
  end
  ```

  Note: `Point2f` comes from Makie, which is re-exported by GraphMakie. Add `using GraphMakie: Point2f` at the top of the testset if needed.

- [ ] **Step 2: Run to confirm failure**

  ```bash
  cd /path/to/feature-visualization
  julia --project=. test/runtests.jl
  ```

  Expected: error — `DynamicWorkflow.hierarchical_layout` is not defined.

- [ ] **Step 3: Implement `hierarchical_layout` in `src/plot.jl`**

  Add after the `using` block (before `job_name`):

  ```julia
  """
  Compute top-down hierarchical positions for a DAG.
  Each node's layer equals its longest path from any source.
  Nodes within the same layer are evenly spaced on the x-axis.
  Returns a `Vector{Point2f}` suitable for `graphplot(layout=...)`.
  """
  function hierarchical_layout(g::AbstractGraph)
      n = nv(g)
      n == 0 && return Point2f[]

      # Assign each node to the deepest layer reachable from a source.
      # topological_sort_by_dfs returns vertices in reverse topological order,
      # so we reverse it to process parents before children.
      layers = zeros(Int, n)
      for v in reverse(topological_sort_by_dfs(g))
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
          y = Float32(-(li - 1))
          for (i, v) in enumerate(nodes)
              x = Float32(i) / Float32(length(nodes) + 1)
              positions[v] = Point2f(x, y)
          end
      end

      return positions
  end
  ```

  Update the export line to include `hierarchical_layout`:
  ```julia
  export draw_graph, hierarchical_layout, Buchheim, SFDP
  ```

- [ ] **Step 4: Run tests to confirm they pass**

  ```bash
  julia --project=. test/runtests.jl
  ```

  Expected: `Test Summary: visualization helpers/hierarchical_layout | Pass  7`

- [ ] **Step 5: Commit**

  ```bash
  git add src/plot.jl test/runtests.jl
  git commit -m "feat: add hierarchical_layout for top-down DAG positioning"
  ```

---

### Task 2: Add color and label helpers + tests

**Files:**
- Modify: `src/plot.jl`
- Modify: `test/runtests.jl`

- [ ] **Step 1: Write the failing tests**

  Inside the `@testset "visualization helpers"` block, after the `hierarchical_layout` testset, add:

  ```julia
  @testset "status_color and status_text_color" begin
      @test DynamicWorkflow.status_color(PENDING)   == "#CCCCCC"
      @test DynamicWorkflow.status_color(RUNNING)   == "#0072B2"
      @test DynamicWorkflow.status_color(COMPLETED) == "#009E73"
      @test DynamicWorkflow.status_color(FAILED)    == "#D55E00"
      @test DynamicWorkflow.status_color(CANCELLED) == "#CC79A7"

      @test DynamicWorkflow.status_text_color(PENDING)   == "#333333"
      @test DynamicWorkflow.status_text_color(RUNNING)   == "white"
      @test DynamicWorkflow.status_text_color(COMPLETED) == "white"
      @test DynamicWorkflow.status_text_color(FAILED)    == "white"
      @test DynamicWorkflow.status_text_color(CANCELLED) == "white"
  end

  @testset "node_width" begin
      # Short labels hit the minimum width
      @test DynamicWorkflow.node_width("hi\nab") == DynamicWorkflow.NODE_MIN_WIDTH

      # Long labels exceed minimum
      long_label = "a_very_long_function_name\nab12f"
      expected = max(DynamicWorkflow.NODE_MIN_WIDTH,
                     length("a_very_long_function_name") * DynamicWorkflow.CHAR_WIDTH)
      @test DynamicWorkflow.node_width(long_label) == expected
  end
  ```

- [ ] **Step 2: Run to confirm failure**

  ```bash
  julia --project=. test/runtests.jl
  ```

  Expected: error — `DynamicWorkflow.status_color` is not defined.

- [ ] **Step 3: Implement helpers in `src/plot.jl`**

  Add after `hierarchical_layout`, before `job_name`:

  ```julia
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

  const NODE_HEIGHT  = 30
  const NODE_MIN_WIDTH = 60
  const CHAR_WIDTH   = 7   # approximate pixels per monospace character

  """Two-line node label: function name on line 1, last 5 chars of UUID on line 2."""
  function node_label(j::Job)
      short_id = string(j.uuid)[end-4:end]
      return "$(j.name)\n$(short_id)"
  end

  """Rectangle width sized to the longest line in the label."""
  function node_width(label::String)
      max_chars = maximum(length(line) for line in split(label, '\n'))
      return max(NODE_MIN_WIDTH, max_chars * CHAR_WIDTH)
  end
  ```

- [ ] **Step 4: Run tests to confirm they pass**

  ```bash
  julia --project=. test/runtests.jl
  ```

  Expected: `Test Summary: visualization helpers | Pass  17` (7 layout + 10 color/label)

- [ ] **Step 5: Commit**

  ```bash
  git add src/plot.jl test/runtests.jl
  git commit -m "feat: add status color palette and node label helpers"
  ```

---

### Task 3: Rewrite `draw_graph`

**Files:**
- Modify: `src/plot.jl`

No new unit tests — rendering requires a display. Visual verification is in Task 4.

- [ ] **Step 1: Replace `job_name` and `draw_graph` in `src/plot.jl`**

  Remove the old `job_name` function and both `draw_graph` methods. Replace with:

  ```julia
  function draw_graph(q::JobQueue; layout=hierarchical_layout)
      g = q.g
      n = nv(g)
      n == 0 && return Figure()

      jobs    = [q.jobs[q.node2id[i]] for i in 1:n]
      labels  = map(node_label, jobs)
      colors  = map(j -> status_color(j.status), jobs)
      tcolors = map(j -> status_text_color(j.status), jobs)
      widths  = map(node_width, labels)
      sizes   = map(w -> Vec2f(w, NODE_HEIGHT), widths)

      f, ax, p = graphplot(g;
          layout       = layout,
          edge_width   = [2 for _ in 1:ne(g)],
          node_size    = sizes,
          node_marker  = Rect,
          node_color   = colors,
          nlabels      = labels,
          nlabels_align   = (:center, :center),
          nlabels_color   = tcolors,
          nlabels_distance = 0,
          arrow_size   = 12,
          edge_color   = :gray,
      )
      deregister_interaction!(ax, :rectanglezoom)
      register_interaction!(ax, :nhover, NodeHoverHighlight(p))
      register_interaction!(ax, :ehover, EdgeHoverHighlight(p))
      register_interaction!(ax, :ndrag, NodeDrag(p))
      hidedecorations!(ax)
      hidespines!(ax)
      ax.title  = "JobQueue Graph"
      ax.aspect = DataAspect()
      return f
  end

  draw_graph(; layout=hierarchical_layout) = draw_graph(Q[]; layout=layout)
  ```

  The complete `src/plot.jl` after both tasks should look like:

  ```julia
  using Printf
  using GraphMakie
  using NetworkLayout
  using Makie

  export draw_graph, hierarchical_layout, Buchheim, SFDP

  function hierarchical_layout(g::AbstractGraph)
      n = nv(g)
      n == 0 && return Point2f[]
      layers = zeros(Int, n)
      for v in reverse(topological_sort_by_dfs(g))
          for u in inneighbors(g, v)
              layers[v] = max(layers[v], layers[u] + 1)
          end
      end
      max_layer = maximum(layers; init=0)
      layer_nodes = [Int[] for _ in 0:max_layer]
      for v in 1:n
          push!(layer_nodes[layers[v] + 1], v)
      end
      positions = Vector{Point2f}(undef, n)
      for (li, nodes) in enumerate(layer_nodes)
          y = Float32(-(li - 1))
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

  status_color(s::JobState) = STATUS_COLORS[s][1]
  status_text_color(s::JobState) = STATUS_COLORS[s][2]

  const NODE_HEIGHT    = 30
  const NODE_MIN_WIDTH = 60
  const CHAR_WIDTH     = 7

  function node_label(j::Job)
      short_id = string(j.uuid)[end-4:end]
      return "$(j.name)\n$(short_id)"
  end

  function node_width(label::String)
      max_chars = maximum(length(line) for line in split(label, '\n'))
      return max(NODE_MIN_WIDTH, max_chars * CHAR_WIDTH)
  end

  function draw_graph(q::JobQueue; layout=hierarchical_layout)
      g = q.g
      n = nv(g)
      n == 0 && return Figure()

      jobs    = [q.jobs[q.node2id[i]] for i in 1:n]
      labels  = map(node_label, jobs)
      colors  = map(j -> status_color(j.status), jobs)
      tcolors = map(j -> status_text_color(j.status), jobs)
      widths  = map(node_width, labels)
      sizes   = map(w -> Vec2f(w, NODE_HEIGHT), widths)

      f, ax, p = graphplot(g;
          layout          = layout,
          edge_width      = [2 for _ in 1:ne(g)],
          node_size       = sizes,
          node_marker     = Rect,
          node_color      = colors,
          nlabels         = labels,
          nlabels_align   = (:center, :center),
          nlabels_color   = tcolors,
          nlabels_distance = 0,
          arrow_size      = 12,
          edge_color      = :gray,
      )
      deregister_interaction!(ax, :rectanglezoom)
      register_interaction!(ax, :nhover, NodeHoverHighlight(p))
      register_interaction!(ax, :ehover, EdgeHoverHighlight(p))
      register_interaction!(ax, :ndrag, NodeDrag(p))
      hidedecorations!(ax)
      hidespines!(ax)
      ax.title  = "JobQueue Graph"
      ax.aspect = DataAspect()
      return f
  end

  draw_graph(; layout=hierarchical_layout) = draw_graph(Q[]; layout=layout)
  ```

- [ ] **Step 2: Run unit tests to confirm nothing is broken**

  ```bash
  julia --project=. test/runtests.jl
  ```

  Expected: all `visualization helpers` tests pass; all other testsets pass.

- [ ] **Step 3: Commit**

  ```bash
  git add src/plot.jl
  git commit -m "feat: rewrite draw_graph with hierarchical layout, rect nodes, and status colors"
  ```

---

### Task 4: Visual verification

**Files:** None (read-only, observation only)

- [ ] **Step 1: Run an example workflow and call `draw_graph`**

  In a Julia REPL with GLMakie available:

  ```julia
  cd("/path/to/feature-visualization/examples")
  using Pkg; Pkg.activate(".")
  using DynamicWorkflow, GLMakie

  function my_add(ctx::JobContext, x, y); x + y; end
  function spawn_jobs(ctx::JobContext)
      jobs = Job[]
      for i in 1:3
          j = @job my_add(ctx, 1, i)
          push!(jobs, j)
      end
      return jobs
  end
  function add_jobs(ctx::JobContext, a, b, c); a + b + c; end

  start_scheduler()
  w = @job spawn_jobs()
  jobs = fetch(w)
  j = @job add_jobs(jobs[1], jobs[2], jobs[3])
  sleep(1)

  draw_graph()   # should open a window
  ```

- [ ] **Step 2: Verify the three requirements**

  Check visually:
  1. **Hierarchy** — `spawn_jobs` appears at the top, `my_add` nodes in the middle row, `add_jobs` at the bottom. No overlapping nodes.
  2. **Rectangle labels** — each node is a rectangle with the function name on line 1 and a short UUID on line 2. Rectangles fit the text without excessive padding.
  3. **Status colors** — all nodes green (`#009E73`) since all jobs completed. If you call `draw_graph()` during execution (before `sleep(1)`), running jobs should be blue and pending jobs gray.

- [ ] **Step 3: Adjust `CHAR_WIDTH` or `nlabels_distance` if needed**

  If label text overflows or is misaligned with rectangles, tune the constants in `src/plot.jl`:

  - Text overflows the rect: increase `CHAR_WIDTH` (try 8 or 9)
  - Text doesn't reach rect edges: decrease `CHAR_WIDTH` (try 6)
  - Text is offset from center: adjust `nlabels_distance` (try `-5` or `5`)

  Re-run `draw_graph()` after each change until the layout looks correct. No commit needed unless constants changed.

- [ ] **Step 4: Commit constant adjustments if any were made**

  Only if Step 3 resulted in changes:

  ```bash
  git add src/plot.jl
  git commit -m "fix: tune node sizing constants for correct label fit"
  ```

  If no changes were needed, skip this step.

---

## Self-Review

**Spec coverage:**
- [x] Top-down hierarchy: `hierarchical_layout` via longest-path layer assignment — Task 1
- [x] Rectangle nodes sized to fit content: `node_marker=Rect`, `node_size=Vec2f(width, height)` — Task 3
- [x] Two-line label (name + short UUID): `node_label`, displayed via `nlabels` — Task 2 + 3
- [x] Status colors (Okabe-Ito, 5 states): `STATUS_COLORS` dict, `status_color`/`status_text_color` — Task 2
- [x] Snapshot only (no live update): no reactive/observable wiring added — Task 3
- [x] No signature change to `draw_graph` — Task 3
- [x] All changes in `src/plot.jl` only — all tasks

**Placeholder scan:** No TBDs or incomplete sections. Step 3 of Task 4 gives specific numeric guidance for tuning.

**Type consistency:**
- `hierarchical_layout` returns `Vector{Point2f}` — matches what `graphplot(layout=...)` expects (GraphMakie passes layout result directly to node positions)
- `node_width` returns `Int` — `Vec2f(w, NODE_HEIGHT)` promotes correctly
- `status_color`/`status_text_color` return `String` — GraphMakie accepts CSS color strings for `node_color` and `nlabels_color`
- `node_label` returns `String` with `\n` — `nlabels` accepts a vector of strings
