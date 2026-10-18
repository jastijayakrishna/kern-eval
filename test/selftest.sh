#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="${SELFTEST_DIR:-/tmp/kern-eval-selftest}"
rm -rf "$T/repos" "$T/runs" && mkdir -p "$T/repos" "$T/runs" "$T/runner"
export HARNESS="$HERE" RUNNER_TEMP="$T/runner"
FAIL=0

make_repo() {
  local name="$1" r="$T/repos/$1"
  git init -q -b main "$r"
  git -C "$r" config user.email selftest@example.invalid
  git -C "$r" config user.name selftest
  printf '22\n' > "$r/.nvmrc"
}

commit() {
  git -C "$1" add -A && git -C "$1" commit -q -m "$2" && git -C "$1" rev-parse HEAD
}

expect() {
  local name="$1" old="$2" new="$3" want="$4" reason="$5"
  local out="$T/runs/$name"
  mkdir -p "$out"
  REPO_URL="file://$T/repos/$name" bash "$HERE/bin/parity.sh" "selftest/$name" "$old" "$new" "$out" > "$out/stdout" 2>&1
  local got why
  got=$(jq -r .verdict "$out/result.json" 2>/dev/null || echo none)
  why=$(jq -r .reason "$out/result.json" 2>/dev/null)
  if [ "$got" = "$want" ] && [[ "$why" == *"$reason"* ]]; then echo "ok   $name: $got ($why)"; else echo "FAIL $name: want $want ($reason), got $got ($why)"; FAIL=1; fi
}

pkg() {
  local dir="$1" build="$2" deps="${3:-}"
  if [ -n "$build" ]; then
    printf '{"name":"t","version":"1.0.0","private":true,"scripts":{"build":"%s"}%s}\n' "$build" "$deps" > "$dir/package.json"
  else
    printf '{"name":"t","version":"1.0.0","private":true,"scripts":{"test":"node -e 0"}%s}\n' "$deps" > "$dir/package.json"
  fi
}

make_repo pass; r="$T/repos/pass"
pkg "$r" "node build.js"; echo 'require("fs").mkdirSync("dist",{recursive:true});require("fs").writeFileSync("dist/a","1")' > "$r/build.js"
(cd "$r" && npm install --package-lock-only --silent > /dev/null 2>&1); old=$(commit "$r" old)
echo 'require("fs").mkdirSync("dist",{recursive:true});require("fs").writeFileSync("dist/a","2")' > "$r/build.js"; new=$(commit "$r" new)
expect pass "$old" "$new" pass "old and new both build"

make_repo broke; r="$T/repos/broke"
pkg "$r" "node build.js"; echo 'console.log("built")' > "$r/build.js"; old=$(commit "$r" old)
echo 'throw new Error("not exported: CounterDO")' > "$r/build.js"; new=$(commit "$r" new)
expect broke "$old" "$new" build-broke "old builds 2 of 2, new fails 2 of 2"

make_repo oldfails; r="$T/repos/oldfails"
pkg "$r" "node build.js"; echo 'process.exit(1)' > "$r/build.js"; old=$(commit "$r" old)
echo 'process.exit(2)' > "$r/build.js"; new=$(commit "$r" new)
expect oldfails "$old" "$new" n/a "old build already fails"

make_repo nobuild; r="$T/repos/nobuild"
pkg "$r" ""; echo 1 > "$r/a.txt"; old=$(commit "$r" old)
echo 2 > "$r/a.txt"; new=$(commit "$r" new)
expect nobuild "$old" "$new" n/a "no root build script"

make_repo installbroke; r="$T/repos/installbroke"
pkg "$r" "node -e 0"; old=$(commit "$r" old)
pkg "$r" "node -e 0" ',"dependencies":{"kern-eval-selftest-no-such-package-zz9":"1.0.0"}'; new=$(commit "$r" new)
expect installbroke "$old" "$new" install-broke "old installs 2 of 2"

make_repo installnomanifest; r="$T/repos/installnomanifest"
printf '{"name":"t","version":"1.0.0","private":true,"scripts":{"build":"node -e 0","postinstall":"node post.js"}}
' > "$r/package.json"
echo 'console.log("post ok")' > "$r/post.js"; old=$(commit "$r" old)
echo 'process.exit(3)' > "$r/post.js"; new=$(commit "$r" new)
expect installnomanifest "$old" "$new" unverified "does not touch a manifest"

make_repo flaky; r="$T/repos/flaky"
pkg "$r" "node build.js"; echo 'console.log("ok")' > "$r/build.js"; old=$(commit "$r" old)
printf 'const f="%s/flaky.count";const fs=require("fs");const n=(fs.existsSync(f)?+fs.readFileSync(f,"utf8"):0)+1;fs.writeFileSync(f,String(n));if(n===1)process.exit(1);\n' "$T" > "$r/build.js"
rm -f "$T/flaky.count"; new=$(commit "$r" new)
expect flaky "$old" "$new" unverified "confirmation did not hold"

make_repo removed; r="$T/repos/removed"
pkg "$r" "node -e 0"; old=$(commit "$r" old)
pkg "$r" ""; new=$(commit "$r" new)
expect removed "$old" "$new" unverified "removes the root build script"

make_repo slow; r="$T/repos/slow"
pkg "$r" "node build.js"; echo 'console.log("ok")' > "$r/build.js"; old=$(commit "$r" old)
echo 'setTimeout(()=>{},60000)' > "$r/build.js"; new=$(commit "$r" new)
BUILD_SECS=5 expect slow "$old" "$new" unverified "new build timed out"

make_repo pnpmlock; r="$T/repos/pnpmlock"
pkg "$r" "node -e 0"; printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n  excludeLinksFromLockfile: false\n\nimporters:\n\n  .: {}\n" > "$r/pnpm-lock.yaml"; old=$(commit "$r" old)
echo 1 > "$r/a.txt"; new=$(commit "$r" new)
expect pnpmlock "$old" "$new" pass "old and new both build"

plan_is() {
  local name="$1" field="$2" want="$3" got
  got=$(jq -r --arg f "$field" '[.steps[] | select(.name=="plan" and .side=="new")][0][$f]' "$T/runs/$name/result.json" 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "ok   $name: plan $field = $got"; else echo "FAIL $name: plan $field want $want, got $got"; FAIL=1; fi
}

lock9() {
  printf "lockfileVersion: '9.0'\n\nsettings:\n  autoInstallPeers: true\n  excludeLinksFromLockfile: false\n\nimporters:\n\n  .: {}\n" > "$1/pnpm-lock.yaml"
}

make_repo pnpmci; r="$T/repos/pnpmci"; rm -f "$r/.nvmrc"
pkg "$r" "node -e 0"; lock9 "$r"; printf 'allowBuilds:\n  esbuild: true\n' > "$r/pnpm-workspace.yaml"
mkdir -p "$r/.github/workflows"; printf 'on: push\njobs:\n  d:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: pnpm/action-setup@v4\n        with: { version: 11 }\n      - uses: actions/setup-node@v4\n        with: { node-version: 22, cache: pnpm }\n      - run: pnpm install --frozen-lockfile\n' > "$r/.github/workflows/deploy.yml"
old=$(commit "$r" old); echo 1 > "$r/a.txt"; new=$(commit "$r" new)
expect pnpmci "$old" "$new" pass "old and new both build"
plan_is pnpmci pm_version 11; plan_is pnpmci pm_source ci; plan_is pnpmci node_source ci

make_repo pnpmnover; r="$T/repos/pnpmnover"; rm -f "$r/.nvmrc"
pkg "$r" "node -e 0"; lock9 "$r"
mkdir -p "$r/.github/workflows"; printf 'on: push\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: pnpm/action-setup@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n' > "$r/.github/workflows/ci.yml"
old=$(commit "$r" old); echo 1 > "$r/a.txt"; new=$(commit "$r" new)
expect pnpmnover "$old" "$new" pass "old and new both build"
plan_is pnpmnover pm_version 10; plan_is pnpmnover pm_source lockfile; plan_is pnpmnover node 20; plan_is pnpmnover node_source ci

make_repo leftover; r="$T/repos/leftover"
pkg "$r" "node build.js"; echo 'console.log("ok")' > "$r/build.js"; old=$(commit "$r" old)
echo 'require("child_process").spawn("sleep",["3001"],{stdio:"ignore"}).unref();console.log("spawned")' > "$r/build.js"; new=$(commit "$r" new)
expect leftover "$old" "$new" pass "old and new both build"
if pgrep -f "sleep 3001" > /dev/null; then echo "FAIL leftover: a process the build started is still running"; pkill -f "sleep 3001"; FAIL=1; else echo "ok   leftover: nothing the build started is still running"; fi

[ "$FAIL" = 0 ] && echo "selftest: all passed" || { echo "selftest: FAILED"; exit 1; }
