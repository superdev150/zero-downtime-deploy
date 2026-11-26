#!/usr/bin/env bash
#
# Server side of the deploy. Two ways in:
#
# 1. From CI (normal). The runner builds the frontend and opens ONE SSH connection that runs
#      deploy-build <40-char sha>      with the build as a .tar.gz on stdin.
#    The SSH key used for that is pinned to this script in authorized_keys (`command="…"`), so whatever the client
#    asks for arrives in $SSH_ORIGINAL_COMMAND and is parsed here. Nothing else can run with that key.
#
#    Steps: fetch → fast-forward the code to exactly the commit that was built → unpack the build next to the live one
#    → verify it → swap with two renames on the same filesystem → post-deploy hook.
#
# 2. By hand on the server (emergency, e.g. CI is down):  bash scripts/deploy.sh
#    pull → build here → hook. Slow on a small VM, but it works without the CI machine.
#
# Settings (environment, all optional): DEPLOY_BRANCH (main), BUILD_DIR (public/build), MAX_BUILD_MB (200),
# BUILD_MARKER (.vite/manifest.json: a file every good build has).

# Everything is inside main(): bash reads the whole function before running it, so `git merge` may rewrite this very
# file without corrupting the run in progress.
main() {
  set -euo pipefail
  umask 027
  cd "$(dirname "${BASH_SOURCE[0]}")/.."

  local branch="${DEPLOY_BRANCH:-main}"
  local build="${BUILD_DIR:-public/build}"
  local marker="${BUILD_MARKER:-.vite/manifest.json}"
  local max_mb="${MAX_BUILD_MB:-200}"

  if [ -n "${SSH_ORIGINAL_COMMAND+x}" ]; then
    # Called through the pinned key: accept exactly one shape, reject everything else.
    local mode="" sha="" extra=""
    read -r mode sha extra <<< "$SSH_ORIGINAL_COMMAND" || true
    if [ "$mode" != "deploy-build" ] || [ -n "$extra" ] || ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "✗ refused: expected 'deploy-build <40-char sha>'" >&2
      exit 64
    fi
    deploy_build "$sha" "$branch" "$build" "$marker" "$max_mb"
  else
    deploy_manual "$branch" "$build"
  fi

  if [ -x scripts/post-deploy.sh ]; then
    echo "▶ post-deploy"
    scripts/post-deploy.sh
  fi
  echo "✓ deployed $(git log --oneline -1)"
}

deploy_build() {
  local sha="$1" branch="$2" build="$3" marker="$4" max_mb="$5"

  echo "▶ code → $sha"
  git fetch --quiet origin "$branch"
  # Only commits that are on the deploy branch, and only forward: no rollbacks to arbitrary history through this door
  if ! git merge-base --is-ancestor "$sha" "origin/$branch"; then
    echo "✗ $sha is not on origin/$branch" >&2
    exit 65
  fi
  # …and never behind what is live: the merge would be a no-op but the old frontend would still be swapped in
  if ! git merge-base --is-ancestor HEAD "$sha"; then
    echo "✗ $sha is older than the live commit $(git rev-parse --short HEAD)" >&2
    exit 65
  fi
  git merge --ff-only --quiet "$sha"

  echo "▶ build (from stdin)"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/build.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'; rm -rf '$build.new'" EXIT

  # Size cap: never fill the disk because of a bad upload
  head -c "$((max_mb * 1024 * 1024 + 1))" > "$tmp"
  if [ "$(wc -c < "$tmp")" -gt "$((max_mb * 1024 * 1024))" ]; then
    echo "✗ build larger than ${max_mb} MB" >&2
    exit 66
  fi
  # No absolute paths and no '..' segments in the archive: it must not write outside the new build directory
  if tar tzf "$tmp" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "✗ archive has unsafe paths" >&2
    exit 66
  fi

  rm -rf "$build.new" "$build.old"
  mkdir -p "$build.new"
  tar xzf "$tmp" -C "$build.new"
  if [ ! -e "$build.new/$marker" ]; then
    echo "✗ build has no $marker: live build left untouched" >&2
    exit 67
  fi
  # Laravel looks for public/build/manifest.json; Vite 5+ writes it to .vite/
  if [ -e "$build.new/.vite/manifest.json" ] && [ ! -e "$build.new/manifest.json" ]; then
    ln -s .vite/manifest.json "$build.new/manifest.json"
  fi

  # The swap: two renames on the same filesystem. The live directory is never missing for more than the gap between
  # two syscalls, and never half-written. Old asset URLs disappear with it, so the SPA reloads once on a missing chunk.
  if [ -e "$build" ]; then mv "$build" "$build.old"; fi
  mv "$build.new" "$build"
  rm -rf "$build.old"
}

deploy_manual() {
  local branch="$1" build="$2"
  # Non-interactive SSH does not load .bashrc: load nvm if Node comes from it
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"; fi

  echo "▶ git pull"
  git pull --ff-only origin "$branch"
  echo "▶ npm run build (on this machine)"
  npm run build
  if [ -e "$build/.vite/manifest.json" ] && [ ! -e "$build/manifest.json" ]; then
    ln -s .vite/manifest.json "$build/manifest.json"
  fi
}

main "$@"
