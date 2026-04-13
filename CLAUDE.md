# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DynamicWorkflow.jl is a Julia package for dynamic job scheduling and workflow management. It wraps functions into jobs, automatically resolves dependencies via `OutputRef` futures, and executes them in parallel using Julia's threading. Jobs can spawn child jobs during execution, enabling dynamic DAG construction with native Julia control flow (`for`, `while`, `if`).

## Development
- Use the latest stable Julia release.
- From the repo root, instantiate once with `julia --project -e 'using Pkg; Pkg.instantiate()'`.
- After dependency changes, keep the environment in sync with `julia --project -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'`.
- This repo uses separate projects for `test` and `docs`; use the matching `--project` flag when needed.
- Don't commit Manifest.toml

## Testing
- Run the full package test suite from the repo root with `julia --project -e 'using Pkg; Pkg.test()'`.
- If you change docs content or public APIs, also verify the docs build with `julia --project=docs docs/make.jl`.
- In tests, call non-exported APIs with module qualification, for example `DynamicWorkflow.context()`.
- Use `-t 2` when testing — the scheduler relies on multithreading.

## Code Style
- Use 4 spaces for indentation.
- Keep implementations small and type-stable where practical.
- Prefer explicit, readable linear algebra.
- Update docstrings and docs pages when changing public APIs in `src/`.
- Add or update tests for behavior changes.
- If a local variable has the same name as a keyword argument, Julia lets you omit the keyword name in the call, for example `foo(x; y)`.

## PR checklist
- Recommended PR title format: `<short summary>`
- Ensure CI-equivalent checks pass locally:
  - Package tests
  - Docs build when docs/public APIs changed
- Keep changes focused; avoid unrelated refactors in the same PR.
- Summarize user-visible API changes in PR description and update README/docs examples when relevant.
- Confirm examples and snippets still run when changing user-facing API behavior.

## Common Commands
```bash
# Run tests (uses separate test project)
julia --project=test -t 2 test/runtests.jl

# Build documentation (uses separate docs project)
julia --project=docs docs/make.jl

# Start a Julia REPL with the package loaded
julia --project -t 2 -e 'using DynamicWorkflow'
```

## Architecture

**Source files** (`src/`):
- `DynamicWorkflow.jl` — Module entry, imports, includes
- `job.jl` — Core types (`Job`, `WTask`, `OutputRef`, `JobContext`, `JobState` enum) and execution logic
- `scheduler.jl` — `JobQueue` struct, global scheduler state (`Q`, `SHUTDOWN`), main event loop, dependency resolution (`resolve_args!`), graph construction
- `plot.jl` — Workflow DAG visualization via GraphMakie
- `util.jl` — Small helpers

**Key abstractions**:
- `Job` holds a `WTask` (function + args), a `JobContext`, an `OutputRef` (future for result), and a `JobState`
- `OutputRef` is the dependency mechanism — when a job's argument is an `OutputRef`, the scheduler waits for it to resolve before running that job
- `JobContext` is stored on the `Job` struct and propagated via task-local storage; it tracks parent/child relationships automatically when jobs spawn child jobs — user functions don't need a context parameter
- `JobQueue` is the global scheduler state, protected by a `ReentrantLock`, with `pending`/`running`/`completed` sets and a `SimpleDiGraph` for the dependency graph
- `@job` macro evaluates in caller scope, auto-converts `Job` arguments to their `OutputRef`, and reads parent context from TLS for automatic parent-child tracking

**Execution flow**: `start_scheduler()` → scheduler main loop polls pending jobs → `resolve_args!` checks if all `OutputRef` deps are ready → ready jobs get `@spawn`ed → results stored in `OutputRef` → dependent jobs unblocked → `stop_scheduler()`.

## Testing

Tests are in `test/runtests.jl` — a single file with `@testset` blocks covering: initialization, scheduler lifecycle, basic jobs (macro and constructor syntax), job status/cancellation/failure, child job spawning (1 and 2 levels deep), and dynamic control flow (loops, conditionals). Tests use `sleep()` for synchronization with the async scheduler.

## CI

GitHub Actions runs tests on Julia 1.x / Ubuntu x64. Documentation deploys via Documenter.yml after CI passes.
