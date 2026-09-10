#!/usr/bin/env bash

# Applies this fork's "extra local networks" changes on top of an upstream
# Mullvad release tag, in the current working tree.
#
# Usage:
#   ci/apply-extra-lan-patch.sh <upstream-tag>     # e.g. 2026.4
#
# Run it from a clean checkout of this fork's default branch that has full
# history (`git clone` without --depth, or `fetch-depth: 0` in Actions).
# Afterwards HEAD is detached at the release plus one commit holding the
# fork's changes, ready to build with ./build.sh.
#
# The fork's changes are applied as a single three-way merge of the net diff
# rather than by rebasing each commit, so this works whether the release is
# older or newer than the commit the fork is based on.

set -euo pipefail

UPSTREAM_URL="https://github.com/mullvad/mullvadvpn-app.git"

tag=${1-}
if [ -z "$tag" ]; then
    echo "usage: $0 <upstream-tag>" >&2
    exit 2
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is not clean; commit or stash first" >&2
    exit 1
fi

# The upstream remote may already exist (repeat runs, or a local clone).
if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
fi

echo "Fetching upstream main and tag $tag..."
git fetch --quiet --no-tags upstream main
git fetch --quiet --no-tags upstream "+refs/tags/$tag:refs/remotes/upstream-tags/$tag"

target="refs/remotes/upstream-tags/$tag"
if ! git rev-parse --verify --quiet "$target" >/dev/null; then
    echo "error: upstream tag '$tag' not found" >&2
    exit 1
fi

# Everything on this branch that is not in upstream's main is the fork's own work.
base=$(git merge-base HEAD upstream/main)
head=$(git rev-parse HEAD)

echo "Fork commits to carry over (squashed into one):"
git log --oneline "$base..$head"
echo "Files changed by the fork:"
git diff --stat "$base" "$head"

# CI checkouts have no committer identity configured.
git config user.name >/dev/null 2>&1 || git config user.name "extra-lan-patch"
git config user.email >/dev/null 2>&1 || git config user.email "extra-lan-patch@localhost"

echo "Checking out $tag and applying the patch..."
git checkout --quiet --detach "$target"

if ! git diff --binary "$base" "$head" | git apply -3 --index; then
    echo "error: the fork's changes do not apply cleanly onto $tag." >&2
    echo "Conflicting files:" >&2
    git diff --name-only --diff-filter=U >&2 || true
    echo "Resolve the conflicts by hand, then commit." >&2
    exit 1
fi

git commit --quiet -m "Apply extra local networks patch onto $tag" \
    -m "Squashed from fork commits $base..$head."

# Editing extra-lan-networks.txt is meant to be enough, so refresh the generated
# constant here rather than making every user remember to run the generator.
echo "Regenerating the extra networks constant..."
cargo run --locked --quiet -p talpid-types --bin generate-extra-lan-nets
if ! git diff --quiet -- talpid-types/src/net/extra_lan_nets.rs; then
    echo "extra_lan_nets.rs was out of date; folding the regenerated file in"
    git add talpid-types/src/net/extra_lan_nets.rs
    git commit --quiet --amend --no-edit
fi

echo
echo "Done. HEAD is now $tag plus the fork's changes:"
git log --oneline -1
git diff --stat "$target" HEAD
