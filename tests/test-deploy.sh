#!/usr/bin/env bash
#
# Simulates the server on this machine: a bare "origin" repo, a clone playing the server checkout, and deploy.sh
# called exactly as sshd calls it through the pinned key (SSH_ORIGINAL_COMMAND + the build on stdin).
#
#   bash tests/test-deploy.sh
#
# Works with bash 3.2 (macOS) and GNU/BSD tar.
#
# check() evaluates its condition after each deploy, so the single quotes are deliberate:
# shellcheck disable=SC2016,SC2034

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zdd-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@t

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────────────────────────
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/dev" 2>/dev/null
mkdir -p "$work/dev/scripts"
cp "$here/scripts/deploy.sh" "$work/dev/scripts/"
cat > "$work/dev/scripts/post-deploy.sh" <<'EOF'
#!/usr/bin/env bash
git rev-parse HEAD > .post-deploy-ran
EOF
chmod +x "$work/dev/scripts/post-deploy.sh"
echo v1 > "$work/dev/version.txt"
git -C "$work/dev" add -A && git -C "$work/dev" commit -qm v1 && git -C "$work/dev" push -q origin main
sha1="$(git -C "$work/dev" rev-parse HEAD)"

git clone -q "$work/origin.git" "$work/server"

echo v2 > "$work/dev/version.txt"
git -C "$work/dev" commit -qam v2 && git -C "$work/dev" push -q origin main
sha2="$(git -C "$work/dev" rev-parse HEAD)"

git -C "$work/dev" checkout -qb experiment
echo nope > "$work/dev/version.txt"
git -C "$work/dev" commit -qam experiment && git -C "$work/dev" push -q origin experiment
sha_other="$(git -C "$work/dev" rev-parse HEAD)"

make_build() {   # make_build <label> <out.tgz> [no-marker]
  local dir="$work/build-$1"
  mkdir -p "$dir/assets"
  echo "console.log('$1')" > "$dir/assets/app-$1.js"
  if [ "${3:-}" != "no-marker" ]; then
    mkdir -p "$dir/.vite"
    echo "{\"label\":\"$1\"}" > "$dir/.vite/manifest.json"
  fi
  COPYFILE_DISABLE=1 tar czf "$2" -C "$dir" .
}

deploy() {   # deploy "<ssh command>" <tgz> [env…]  → exit code in $code
  set +e
  (cd "$work/server" && env "${@:3}" SSH_ORIGINAL_COMMAND="$1" bash scripts/deploy.sh < "$2") > "$work/last.log" 2>&1
  code=$?
  set -e
}

live_label() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["label"])' "$work/server/public/build/manifest.json" 2>/dev/null || echo none; }

make_build one "$work/one.tgz"
make_build two "$work/two.tgz"
make_build broken "$work/broken.tgz" no-marker

# ── tests ───────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "first deploy"
deploy "deploy-build $sha1" "$work/one.tgz"
check "exits 0" '[ "$code" = 0 ]'
check "code is at the built commit" '[ "$(git -C "$work/server" rev-parse HEAD)" = "$sha1" ]'
check "build is live" '[ "$(live_label)" = one ]'
check "manifest.json → .vite/manifest.json symlink" '[ -L "$work/server/public/build/manifest.json" ]'
check "post-deploy hook ran" '[ "$(cat "$work/server/.post-deploy-ran")" = "$sha1" ]'
check "no leftovers" '[ ! -e "$work/server/public/build.new" ] && [ ! -e "$work/server/public/build.old" ]'

echo "second deploy (forward)"
deploy "deploy-build $sha2" "$work/two.tgz"
check "exits 0" '[ "$code" = 0 ]'
check "new build replaced the old one" '[ "$(live_label)" = two ] && [ ! -e "$work/server/public/build/assets/app-one.js" ]'
check "code moved forward" '[ "$(cat "$work/server/version.txt")" = v2 ]'

echo "refused commands (the key can do nothing else)"
for cmd in "rm -rf /" "deploy-build" "deploy-build abc123" "deploy-build $sha2 extra" "deploy-build $sha2; reboot" "bash -i" ""; do
  deploy "$cmd" "$work/one.tgz"
  check "refuses '$cmd'" '[ "$code" = 64 ] && [ "$(live_label)" = two ]'
done

echo "commit not on the deploy branch"
deploy "deploy-build $sha_other" "$work/one.tgz"
check "refused with 65" '[ "$code" = 65 ]'
check "code untouched" '[ "$(cat "$work/server/version.txt")" = v2 ]'

echo "going backwards"
deploy "deploy-build $sha1" "$work/one.tgz"
check "refused with 65" '[ "$code" = 65 ]'
check "code and build stay on the newer version" '[ "$(git -C "$work/server" rev-parse HEAD)" = "$sha2" ] && [ "$(live_label)" = two ]'

echo "broken build"
deploy "deploy-build $sha2" "$work/broken.tgz"
check "refused with 67" '[ "$code" = 67 ]'
check "live build untouched" '[ "$(live_label)" = two ]'
check "half-unpacked build removed" '[ ! -e "$work/server/public/build.new" ]'

echo "malicious archive"
python3 - "$work/evil.tgz" <<'EOF'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name in (".vite/manifest.json", "../../escaped.txt"):
        data = b'{"label":"evil"}'
        info = tarfile.TarInfo(name); info.size = len(data)
        t.addfile(info, io.BytesIO(data))
EOF
deploy "deploy-build $sha2" "$work/evil.tgz"
check "refused with 66" '[ "$code" = 66 ]'
check "nothing written outside" '[ ! -e "$work/escaped.txt" ] && [ ! -e "$work/server/escaped.txt" ]'
check "live build untouched" '[ "$(live_label)" = two ]'

echo "oversized upload"
head -c 2200000 /dev/urandom > "$work/big.bin"
deploy "deploy-build $sha2" "$work/big.bin" MAX_BUILD_MB=1
check "refused with 66" '[ "$code" = 66 ]'
check "live build untouched" '[ "$(live_label)" = two ]'

echo "live directory never disappears during a swap"
(
  # Hammer the live path while 5 deploys swap it
  missing=0
  for _ in $(seq 1 2000); do [ -e "$work/server/public/build/.vite/manifest.json" ] || missing=$((missing + 1)); done
  echo "$missing" > "$work/missing"
) &
watcher=$!
for _ in 1 2 3 4 5; do deploy "deploy-build $sha2" "$work/two.tgz"; done
wait "$watcher"
check "at most a handful of misses in 2000 probes (the gap between two renames)" '[ "$(cat "$work/missing")" -le 5 ]'

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$pass"
else
  printf '\033[31m%d failed\033[0m, %d passed — last log:\n' "$fail" "$pass"
  cat "$work/last.log"
  exit 1
fi
