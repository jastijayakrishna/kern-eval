#!/usr/bin/env bash
set -uo pipefail

REPO="$1"
OLD="$2"
NEW="$3"
OUT="$4"
INSTALL_SECS="${INSTALL_SECS:-1200}"
BUILD_SECS="${BUILD_SECS:-1200}"
W="$RUNNER_TEMP/w"
TOOLS="$RUNNER_TEMP/tools"
BASE_PATH="$PATH"
LOGS="$OUT/logs"
rm -rf "$W" && mkdir -p "$W" "$LOGS" "$TOOLS"
START=$(date +%s)
STEPS="$OUT/steps.jsonl"
: > "$STEPS"

export CI=true HUSKY=0 DO_NOT_TRACK=1 NEXT_TELEMETRY_DISABLED=1 ASTRO_TELEMETRY_DISABLED=1 NUXT_TELEMETRY_DISABLED=1 \
  TURBO_TELEMETRY_DISABLED=1 NG_CLI_ANALYTICS=false STORYBOOK_DISABLE_TELEMETRY=1 GATSBY_TELEMETRY_DISABLED=1 \
  COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_DEFAULT_TO_LATEST=0 COREPACK_ENABLE_STRICT=0 \
  NODE_OPTIONS="--max-old-space-size=6144" npm_config_audit=false npm_config_fund=false npm_config_update_notifier=false
unset GITHUB_TOKEN GH_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL

finish() {
  local verdict="$1" reason="$2"
  jq -n --arg repo "$REPO" --arg old "$OLD" --arg new "$NEW" --arg verdict "$verdict" --arg reason "$reason" \
    --arg manifest "${MANIFEST_CHANGED:-0}" --argjson seconds "$(( $(date +%s) - START ))" \
    --slurpfile steps "$STEPS" \
    '{repo:$repo, old_sha:$old, head_sha:$new, verdict:$verdict, reason:$reason, manifest_changed:($manifest=="1"), seconds:$seconds, steps:$steps}' \
    > "$OUT/result.json"
  echo "build parity: $verdict ($reason)"
  exit 0
}

step() {
  local side="$1" name="$2" secs="$3" dir="$4"
  shift 4
  local log="$LOGS/$side-$name-$(date +%s%N).log" t0=$(date +%s) code
  ( cd "$dir" && timeout --kill-after=30 "$secs" "$@" ) > "$log" 2>&1
  code=$?
  pkill -9 -f "$dir" > /dev/null 2>&1 || true
  if [ "$(stat -c %s "$log")" -gt 400000 ]; then { head -c 100000 "$log"; echo; echo "[... cut ...]"; tail -c 250000 "$log"; } > "$log.cut" && mv "$log.cut" "$log"; fi
  jq -nc --arg side "$side" --arg name "$name" --argjson code "$code" --argjson seconds "$(( $(date +%s) - t0 ))" --arg log "$(basename "$log")" \
    '{side:$side, name:$name, code:$code, timed_out:($code==124 or $code==137), seconds:$seconds, log:$log}' >> "$STEPS"
  return $code
}

use_node() {
  local major="$1" d="$TOOLS/node-$1" v
  if [ ! -x "$d/bin/node" ]; then
    v=$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json | jq -r --arg p "v$major." '[.[] | select(.version | startswith($p))][0].version')
    [ -n "$v" ] && [ "$v" != null ] || return 1
    curl -fsSL --retry 3 "https://nodejs.org/dist/$v/node-$v-linux-x64.tar.xz" | tar -xJ -C "$TOOLS" || return 1
    mv "$TOOLS/node-$v-linux-x64" "$d" || return 1
    PATH="$d/bin:$BASE_PATH" npm install -g --silent corepack@0.36.0 > /dev/null 2>&1 || true
    PATH="$d/bin:$BASE_PATH" corepack enable --install-directory "$d/bin" > /dev/null 2>&1 || true
  fi
  export PATH="$d/bin:$BASE_PATH"
  COREPACK_VERSION=$(corepack --version 2>/dev/null || echo none)
  case "$COREPACK_VERSION" in 0.3[6-9]*|0.[4-9]*) unset COREPACK_INTEGRITY_KEYS ;; *) export COREPACK_INTEGRITY_KEYS=0 ;; esac
  jq -nc --arg node "$(node --version)" --arg corepack "$COREPACK_VERSION" '{name:"node", node:$node, corepack:$corepack}' >> "$STEPS"
}

plan_side() {
  local dir="$1" pmf name ver lockv
  NODE_MAJOR=$(SEMVER_PATH="$TOOLS/node_modules/semver" node "$HARNESS/bin/node-major.cjs" "$dir")
  HAS_BUILD=$(jq -r 'if (.scripts.build // "") != "" then "1" else "0" end' "$dir/package.json" 2>/dev/null || echo 0)
  pmf=$(jq -r '.packageManager // empty' "$dir/package.json" 2>/dev/null)
  PM_SOURCE=lockfile
  if [ -n "$pmf" ]; then
    name="${pmf%%@*}"; ver="${pmf#*@}"; ver="${ver%%+*}"; PM_SOURCE=packageManager
  elif [ -f "$dir/pnpm-lock.yaml" ]; then
    name=pnpm; lockv=$(grep -m1 -oE "^lockfileVersion: *'?[0-9.]+" "$dir/pnpm-lock.yaml" | grep -oE '[0-9.]+$')
    case "$lockv" in 9*) ver=9 ;; 6*) ver=8 ;; 5.4*) ver=7 ;; 5*) ver=6 ;; *) ver=9 ;; esac
  elif [ -f "$dir/yarn.lock" ]; then
    name=yarn; if grep -q '^__metadata:' "$dir/yarn.lock"; then ver=4; else ver=1; fi
  elif [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; then
    name=bun; ver=
  else
    name=npm; ver=
  fi
  PM="$name"; PM_VERSION="$ver"
  local yarnpath
  yarnpath=$( [ -f "$dir/.yarnrc.yml" ] && grep -m1 -E '^yarnPath:' "$dir/.yarnrc.yml" | sed -E 's/^yarnPath: *//; s/["'"'"']//g')
  case "$name" in
    npm)
      PMRUN=(npm)
      if [ -f "$dir/package-lock.json" ] || [ -f "$dir/npm-shrinkwrap.json" ]; then INSTALL=(npm ci); else INSTALL=(npm install); fi ;;
    pnpm)
      if [ "$PM_SOURCE" = packageManager ]; then PMRUN=(pnpm); else PMRUN=(npx --yes "pnpm@$ver"); fi
      INSTALL=("${PMRUN[@]}" install --frozen-lockfile) ;;
    yarn)
      if [ -n "$yarnpath" ] && [ -f "$dir/$yarnpath" ]; then PMRUN=(node "$dir/$yarnpath");
      elif [ "$PM_SOURCE" = packageManager ]; then PMRUN=(yarn);
      elif [ "$ver" = 1 ]; then PMRUN=(npx --yes yarn@1.22.22);
      else PMRUN=(corepack yarn@4.5.3); fi
      if [ "${ver%%.*}" = 1 ]; then INSTALL=("${PMRUN[@]}" install --frozen-lockfile --non-interactive); else INSTALL=("${PMRUN[@]}" install --immutable); fi ;;
    *)
      PMRUN=(); INSTALL=() ;;
  esac
  jq -nc --arg side "$2" --arg node "$NODE_MAJOR" --arg pm "$PM" --arg pmv "$PM_VERSION" --arg src "$PM_SOURCE" --arg build "$HAS_BUILD" \
    '{side:$side, name:"plan", node:$node, pm:$pm, pm_version:$pmv, pm_source:$src, has_build:($build=="1")}' >> "$STEPS"
}

install_side() {
  local side="$1" dir="$2"
  git -C "$dir" clean -xdfq > /dev/null 2>&1
  git -C "$dir" checkout -q -- . > /dev/null 2>&1
  plan_side "$dir" "$side"
  use_node "$NODE_MAJOR" || return 2
  [ "${#INSTALL[@]}" -gt 0 ] || return 3
  step "$side" install "$INSTALL_SECS" "$dir" "${INSTALL[@]}"
}

build_side() {
  local side="$1" dir="$2"
  step "$side" build "$BUILD_SECS" "$dir" "${PMRUN[@]}" run build
}

npm install --prefix "$TOOLS" --silent semver@7.6.3 > /dev/null 2>&1 || finish unverified "harness could not install semver"

git init -q "$W/src" && git -C "$W/src" remote add origin "${REPO_URL:-https://github.com/$REPO.git}"
for s in "$OLD" "$NEW"; do
  git -C "$W/src" fetch -q --depth=1 origin "$s" >> "$LOGS/fetch.log" 2>&1 || finish unverified "could not fetch $s"
done
git -C "$W/src" diff --name-only "$OLD" "$NEW" > "$OUT/changed.txt" 2>> "$LOGS/fetch.log"
MANIFEST_CHANGED=0
grep -qE '(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|bun\.lockb?|\.yarnrc\.yml|\.npmrc|\.pnpmfile\.cjs)$' "$OUT/changed.txt" && MANIFEST_CHANGED=1
git -C "$W/src" worktree add -q --detach "$W/old" "$OLD" >> "$LOGS/fetch.log" 2>&1 || finish unverified "could not check out old"
git -C "$W/src" worktree add -q --detach "$W/new" "$NEW" >> "$LOGS/fetch.log" 2>&1 || finish unverified "could not check out new"

plan_side "$W/old" old; OLD_BUILD="$HAS_BUILD"; OLD_PM="$PM"
plan_side "$W/new" new; NEW_BUILD="$HAS_BUILD"; NEW_PM="$PM"
[ "$OLD_BUILD" = 1 ] || [ "$NEW_BUILD" = 1 ] || finish n/a "no root build script"
[ "$OLD_BUILD" = 1 ] || finish n/a "the change adds the root build script"
[ "$NEW_BUILD" = 1 ] || finish unverified "the change removes the root build script"
[ "$OLD_PM" != bun ] && [ "$NEW_PM" != bun ] || finish unverified "bun is not supported by this harness"

install_side old "$W/old"; c=$?
[ $c -eq 2 ] && finish unverified "could not install Node $NODE_MAJOR for old"
[ $c -eq 0 ] || finish unverified "old install failed"
build_side old "$W/old"; c=$?
[ $c -eq 124 ] || [ $c -eq 137 ] && finish unverified "old build timed out"
[ $c -eq 0 ] || finish n/a "old build already fails"
git -C "$W/old" clean -xdfq > /dev/null 2>&1

install_side new "$W/new"; c=$?
[ $c -eq 2 ] && finish unverified "could not install Node $NODE_MAJOR for new"
if [ $c -ne 0 ]; then
  [ "$MANIFEST_CHANGED" = 1 ] || finish unverified "new install failed and the change does not touch a manifest or lockfile"
  install_side old "$W/old"; o=$?
  git -C "$W/old" clean -xdfq > /dev/null 2>&1
  install_side new "$W/new"; n=$?
  [ $o -eq 0 ] && [ $n -ne 0 ] && [ $n -ne 2 ] && [ $n -ne 124 ] && [ $n -ne 137 ] && finish install-broke "old installs 2 of 2, new fails 2 of 2, and the change touches a manifest or lockfile"
  finish unverified "new install failed once but the confirmation did not hold"
fi
build_side new "$W/new"; c=$?
[ $c -eq 124 ] || [ $c -eq 137 ] && finish unverified "new build timed out"
[ $c -eq 0 ] && finish pass "old and new both build"
git -C "$W/new" clean -xdfq > /dev/null 2>&1

install_side old "$W/old"; o=$?
[ $o -eq 0 ] || finish unverified "confirmation: old install failed"
build_side old "$W/old"; ob=$?
git -C "$W/old" clean -xdfq > /dev/null 2>&1
install_side new "$W/new"; n=$?
[ $n -eq 0 ] || finish unverified "confirmation: new install failed"
build_side new "$W/new"; nb=$?
[ $ob -eq 0 ] && [ $nb -ne 0 ] && [ $nb -ne 124 ] && [ $nb -ne 137 ] && finish build-broke "old builds 2 of 2, new fails 2 of 2"
finish unverified "new build failed once but the confirmation did not hold"
