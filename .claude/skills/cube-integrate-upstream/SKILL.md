---
name: cube-integrate-upstream
description: Reintegrate the SaschaJohn/cube SQL-API database-meta fork onto a new upstream cube-js release tag — apply the net patch, resolve upstream drift, build and test Rust + native JS, and validate failures against a clean baseline. Use when asked to port/integrate/rebase the fork's database-meta feature onto a new cube version, or to refresh the custom build against the latest upstream tag.
---

# Cube fork → upstream tag integration

The fork (`origin` = SaschaJohn/cube, `upstream` = cube-js/cube, working copy `/Users/hesse/src/cube`) carries one feature upstream doesn't have: the Postgres startup-message database name threaded through SQL auth into `LoadRequestMeta`/JS `checkSqlAuth`. Each new upstream tag needs re-integration.

Read the memory file `cube-fork-reintegration-playbook` first — it holds pitfalls (disk, npm sandbox, CJS deps, jest snapshot deletion) verified on 2026-10-20 for the v1.6.52 → v1.8.8 integration.

## Procedure

1. **Run the deterministic part:** `scripts/integrate-upstream-tag.sh <tag>` (repo root). It fetches the tag, extracts the *net* diff from the previous integration branch if one exists (else from the fork branch vs its merge-base), checks upstream hasn't implemented the feature themselves, creates `integrate/<tag>-database-meta`, and 3-way applies. It prints build/test instructions.

2. **Resolve conflicts** where upstream drifted into the patch's files. The recurring one: `rust/cubesql/cubesql/src/transport/service.rs` — upstream keeps adding fields to `LoadRequestMeta` (`change_user`, `external_pre_aggregations`, …). ALWAYS keep upstream's new fields AND add `database` alongside them (field, init in `new()`, getter/setter, all with `#[serde(skip_serializing_if = "Option::is_none")]` on the field).

3. **Check test expectations against upstream serde drift.** Known case: since v1.8.8 upstream serializes `appName` always (`"appName": null`) — `packages/cubejs-backend-native/test/sql.test.ts` expectations must list `appName: null` next to `database: 'test'`. Grep the new tag's `transport/service.rs` for what serializes with vs without skip.

4. **Build and test** (commands the script prints): cubesql `cargo build` + `cargo test -p cubesql test_database_meta` + `cargo test -p cubesql --lib`; then the native module via `cargo-cp-artifact` with `CARGO_TARGET_DIR` shared, `tsc -p .`, jest with the uuid moduleNameMapper override. Use `CARGO_PROFILE_DEV_DEBUG=0` — this machine's disk cannot hold debuginfo builds (see playbook).

5. **Prove any failure is pre-existing:** stash the patch, rebuild the native binary clean, rerun jest. Only patch-caused regressions block the commit. (v1.8.8 baseline on this Mac: 2 env-dependent failures — timezone Date assertion, stream-schema test.)

6. **Before committing:** `git checkout -- packages/cubejs-backend-native/test/__snapshots__/` (jest globalSetup deletes snapshots it considers obsolete on every run).

7. **Commit on the integration branch** (conventional commit, `feat(cubesql):`), then update `BASE_TAG` at the top of `scripts/integrate-upstream-tag.sh` to the new tag so the next run diffs against this integration branch.

8. **Docker image:** push the integration branch, then run `.github/workflows/build-custom-image.yml` (manual `workflow_dispatch`) with `upstream_tag` and `branch` (the integration branch). It 3-way applies the branch's net patch onto the tag (never rebases the branch) and builds `ghcr.io/<owner>/cube:<tag>-database-meta` from `packages/cubejs-docker/dev.Dockerfile`.

## Guards

- NEVER `git rebase` the fork branch onto the tag — its history has duplicate/rebased and no-op commits; the net diff is the source of truth.
- Before applying, verify upstream still lacks the feature: `git grep -n "pub database" <tag> -- rust/cubesql/cubesql/src/sql/auth_service.rs` must come up empty; if upstream implemented it, stop and evaluate supersession instead.
- Watch free disk during builds (`df -h /`); at <2Gi free, stop and clean target dirs (playbook has the cleanup commands). ENOSPC first surfaces as cryptic linker/npm/jest failures — `errno=28` in the error is the tell.
