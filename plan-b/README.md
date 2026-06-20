# plan-b — tart as an act execution backend

This directory holds **Plan B**: a real tart macOS-VM execution backend for
forgejo-runner, kept as a rebasable patch series (upstream won't merge tart —
it's not Free Software — so we maintain it as patches, not a permanent fork).

Full usage is at the top of the repo [README](../README.md). Contents:

| Path | What it is |
|---|---|
| `patches/` | The tart backend as a `git format-patch` series, based on upstream tag `v12.12.0`. The source of truth for the change. |
| `build.sh` | Clone an upstream tag → `git am` the patches (rebase forward) → `go build` → `dist/forgejo-runner-tart`. Used locally and by CI. |
| `e2e.sh` | Local smoke test: register a host runner with a `tart://` label and run one job in a fresh VM. |
| `.build/` | Transient upstream clone produced by `build.sh` (git-ignored). |

The CI that auto-rebases onto new upstream tags and publishes releases is
[`.github/workflows/sync-and-release.yml`](../.github/workflows/sync-and-release.yml).

What the patch changes (small, surgical — see the README "改动范围"):
`act/container/tart.go` (new) + small edits to `labels.go`, `run_context.go`,
`host_environment.go`.
