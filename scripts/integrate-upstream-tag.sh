#!/usr/bin/env bash
# Integrate the cube fork's SQL-API database-meta feature onto a new upstream tag.
#
# Usage: scripts/integrate-upstream-tag.sh <upstream-tag> [fork-branch]
#   e.g. scripts/integrate-upstream-tag.sh v1.8.9
#
# Creates branch integrate/<tag>-database-meta from the tag and 3-way applies
# the *net* diff of the fork branch vs its merge-base with the fork's recorded
# base tag (BASE_TAG below). Deterministic only: conflict resolution, build,
# and testing stay manual — see the skill/memory notes for the procedure.
#
# Never commits. Leaves the working tree ready for conflict resolution.

set -euo pipefail

TAG="${1:?usage: $0 <upstream-tag> [fork-branch]}"
FORK_BRANCH="${2:-feat/sql-api-database-meta}"
# The tag the fork branch was last known to be based on. Update this after a
# successful integration so the next run diffs fork-vs-integrate branch.
BASE_TAG="${BASE_TAG:-v1.8.8}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PATCH_FILE="$(mktemp -t database-meta-patch).diff"
trap 'rm -f "$PATCH_FILE"' EXIT

echo "==> Fetching upstream tag $TAG"
git fetch upstream "refs/tags/$TAG:refs/tags/$TAG"

# Prefer the previous integration branch as the diff source when it exists:
# it is the cleanest, conflict-resolved form of the feature.
if git rev-parse --verify --quiet "integrate/${BASE_TAG}-database-meta" >/dev/null; then
  SOURCE="integrate/${BASE_TAG}-database-meta"
  BASE="$(git rev-parse "$BASE_TAG")"
  echo "==> Extracting net diff: $SOURCE vs $BASE_TAG"
else
  SOURCE="$FORK_BRANCH"
  BASE="$(git merge-base "$FORK_BRANCH" "$BASE_TAG")"
  echo "==> Extracting net diff: $FORK_BRANCH vs merge-base $BASE"
fi

git diff "$BASE" "$SOURCE" -- packages/cubejs-backend-native rust/cubesql > "$PATCH_FILE"
if [ ! -s "$PATCH_FILE" ]; then
  echo "!! Empty patch — did the fork already land upstream, or is BASE_TAG wrong?" >&2
  exit 1
fi
git diff --stat "$BASE" "$SOURCE" -- packages/cubejs-backend-native rust/cubesql

BRANCH="integrate/${TAG}-database-meta"
if git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
  echo "!! Branch $BRANCH already exists; delete it first if you want to redo." >&2
  exit 1
fi

echo "==> Checking whether upstream already implements the feature (should print nothing)"
git grep -n "pub database" "$TAG" -- rust/cubesql/cubesql/src/sql/auth_service.rs || true

echo "==> Creating $BRANCH from $TAG"
git switch -c "$BRANCH" "$TAG"

echo "==> 3-way applying patch"
if git apply --3way "$PATCH_FILE"; then
  echo "==> Applied cleanly. Verify, then build+test:"
else
  echo "==> Conflicts (expected where upstream drifted). Resolve, then run:"
fi
cat <<'INSTRUCTIONS'
    Resolve conflicts (likely rust/cubesql/cubesql/src/transport/service.rs:
    keep upstream's new fields AND database), then:

    cd rust/cubesql
    CARGO_PROFILE_DEV_DEBUG=0 cargo build
    cargo test -p cubesql test_database_meta && cargo test -p cubesql --lib
    cd ../packages/cubejs-backend-native
    PATH=/Users/hesse/src/cube-native-sandbox/node_modules/.bin:$PATH \
      CARGO_TARGET_DIR=../../rust/cubesql/target CARGO_PROFILE_DEV_DEBUG=0 \
      cargo-cp-artifact -a cdylib cubejs-native index.node -- \
      cargo build --message-format=json-render-diagnostics
    /Users/hesse/src/cube-native-sandbox/node_modules/.bin/tsc -p .
    CUBEJS_NATIVE_INTERNAL_DEBUG=true CUBESQL_LOG_LEVEL=error \
      /Users/hesse/src/cube-native-sandbox/node_modules/.bin/jest \
      --rootDir=. --config jest.config.js --coverage=false --forceExit \
      --moduleNameMapper='{"^uuid$":"/Users/hesse/src/cube-native-sandbox/node_modules/uuid/dist/cjs/index.js"}' \
      'sql\.test\.js$'

    Any failures: first re-run them on a CLEAN checkout of the tag (build a
    baseline native binary) to prove they are not caused by the patch.
    Restore jest-deleted snapshots before committing:
      git checkout -- packages/cubejs-backend-native/test/__snapshots__/
    Then commit on this branch and update BASE_TAG in this script to $TAG.
INSTRUCTIONS
