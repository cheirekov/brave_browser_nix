#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
metadata="$repo_root/nix/sources.json"
check_only=false
requested_version=

while (($#)); do
  case $1 in
    --check) check_only=true ;;
    --version)
      shift
      requested_version=${1:?--version requires a value}
      ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

for command in curl git jq nix python3; do
  command -v "$command" >/dev/null || { printf 'missing command: %s\n' "$command" >&2; exit 1; }
done

current=$(jq -r .version "$metadata")
channel=$(jq -r '.channel // empty' "$metadata")
[[ $channel == stable ]] || {
  printf 'refusing update: source metadata channel is %s, expected stable\n' "${channel:-unset}" >&2
  exit 1
}

stable=$(curl -fsSL https://versions.brave.com/latest/release-linux-x64.version)
[[ $stable =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'invalid Brave Stable endpoint response: %s\n' "$stable" >&2
  exit 1
}

if [[ -n $requested_version && $requested_version != "$stable" ]]; then
  printf 'refusing requested version %s: official Linux Stable is %s\n' \
    "$requested_version" "$stable" >&2
  exit 1
fi
latest=${requested_version:-$stable}

version_is_newer() {
  local candidate=$1 installed=$2 candidate_major candidate_minor candidate_patch
  local installed_major installed_minor installed_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r installed_major installed_minor installed_patch <<<"$installed"
  ((10#$candidate_major > 10#$installed_major)) && return 0
  ((10#$candidate_major < 10#$installed_major)) && return 1
  ((10#$candidate_minor > 10#$installed_minor)) && return 0
  ((10#$candidate_minor < 10#$installed_minor)) && return 1
  ((10#$candidate_patch > 10#$installed_patch))
}

if [[ $latest == "$current" ]]; then
  printf 'update_available=false\nchannel=stable\nstable_version=%s\n' "$stable"
  [[ -n ${GITHUB_OUTPUT:-} ]] &&
    printf 'update_available=false\nchannel=stable\nstable_version=%s\n' "$stable" >> "$GITHUB_OUTPUT"
  exit 0
fi

version_is_newer "$latest" "$current" || {
  printf 'refusing Brave Stable downgrade: current=%s upstream=%s\n' "$current" "$latest" >&2
  exit 1
}

printf 'update_available=true\nchannel=stable\nold_version=%s\nnew_version=%s\n' "$current" "$latest"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'update_available=true\nchannel=stable\nold_version=%s\nnew_version=%s\n' \
    "$current" "$latest" >> "$GITHUB_OUTPUT"
fi
$check_only && exit 0

temporary=$(mktemp -d)
cp "$metadata" "$temporary/sources.json"
cp "$repo_root/flake.lock" "$temporary/flake.lock"
restore() {
  cp "$temporary/sources.json" "$metadata"
  cp "$temporary/flake.lock" "$repo_root/flake.lock"
}
restore_on_exit() {
  exit_status=$?
  if ((exit_status)); then
    restore
  fi
  trap - EXIT
  exit "$exit_status"
}
trap restore_on_exit EXIT

core_json=$(nix store prefetch-file --json --unpack \
  "https://github.com/brave/brave-core/archive/refs/tags/v${latest}.tar.gz")
core_path=$(jq -r .storePath <<<"$core_json")
core_hash=$(jq -r .hash <<<"$core_json")
chromium_version=$(python3 "$repo_root/scripts/update_sources.py" \
  --version "$latest" --core "$core_path" --core-hash "$core_hash" --output "$metadata")

(cd "$repo_root" && nix flake update nixpkgs)
pinned_chromium=$(cd "$repo_root" && nix eval --impure --raw --expr \
  'let f = builtins.getFlake (toString ./.); in (import f.inputs.nixpkgs { system = "x86_64-linux"; }).chromium.version')
if [[ $pinned_chromium != "$chromium_version" ]]; then
  printf 'nixpkgs Chromium is %s, but Brave requires %s; retry after nixpkgs updates\n' \
    "$pinned_chromium" "$chromium_version" >&2
  exit 1
fi

core_npm_log="$temporary/core-npm.log"
if ! (cd "$repo_root" && nix build --no-link --impure --expr \
  'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).coreNodeModules') \
  >"$core_npm_log" 2>&1; then
  got=$(sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^[:space:]]*\)$/\1/p' "$core_npm_log" | tail -1)
  [[ -n $got ]] || { cat "$core_npm_log" >&2; exit 1; }
  jq --arg hash "$got" '.coreNodeModulesHash = $hash' "$metadata" > "$temporary/sources.updated.json"
  cp "$temporary/sources.updated.json" "$metadata"
  (cd "$repo_root" && nix build --no-link --impure --expr \
    'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).coreNodeModules')
fi

leo_log="$temporary/leo.log"
if ! (cd "$repo_root" && nix build --no-link --impure --expr \
  'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).leoArtifacts') \
  >"$leo_log" 2>&1; then
  got=$(sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^[:space:]]*\)$/\1/p' "$leo_log" | tail -1)
  [[ -n $got ]] || { cat "$leo_log" >&2; exit 1; }
  jq --arg hash "$got" '.leoNpmDepsHash = $hash' "$metadata" > "$temporary/sources.updated.json"
  cp "$temporary/sources.updated.json" "$metadata"
  (cd "$repo_root" && nix build --no-link --impure --expr \
    'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).leoArtifacts')
fi

wdp_log="$temporary/wdp.log"
if ! (cd "$repo_root" && nix build --no-link --impure --expr \
  'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).wdpNodeModules') \
  >"$wdp_log" 2>&1; then
  got=$(sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[^[:space:]]*\)$/\1/p' "$wdp_log" | tail -1)
  [[ -n $got ]] || { cat "$wdp_log" >&2; exit 1; }
  jq --arg hash "$got" '.wdpNodeModulesHash = $hash' "$metadata" > "$temporary/sources.updated.json"
  cp "$temporary/sources.updated.json" "$metadata"
  (cd "$repo_root" && nix build --no-link --impure --expr \
    'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = "x86_64-linux"; }; in (import ./nix/source.nix { inherit pkgs; }).wdpNodeModules')
fi

(cd "$repo_root" && nix flake check && ./scripts/verify.sh --source . && git diff --check)
printf 'updated Brave %s -> %s (Chromium %s)\n' "$current" "$latest" "$chromium_version"
