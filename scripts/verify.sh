#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'verify: %s\n' "$*" >&2
  exit 1
}

verify_source() {
  local root=$1
  local metadata="$root/nix/sources.json"
  [[ -f $metadata ]] || die "missing nix/sources.json"
  [[ $(jq -r .version "$metadata") =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Brave version"
  [[ $(jq -r .tag "$metadata") == "v$(jq -r .version "$metadata")" ]] || die "tag/version mismatch"
  [[ $(jq -r .core.hash "$metadata") == sha256-* ]] || die "core source is not hashed"
  jq -e '.deps | length > 0 and all(.[]; .hash | startswith("sha256-"))' "$metadata" >/dev/null \
    || die "a Brave DEPS source is missing its hash"
  grep -Eq 'enable_tor[[:space:]]*=[[:space:]]*false' "$root/package.nix" \
    || die "package does not set enable_tor=false"
  grep -Fq 'BUILDFLAG(ENABLE_TOR)' "$root/README.md" \
    || die "Tor build flag mapping is not documented"
  grep -Fq 'user-data-dir="$profile_root/br"' "$root/nix/br-wrapper.sh" \
    || die "wrapper does not isolate the profile"
  ! grep -R -Fq -- '--impure' "$root/package.nix" "$root/nix" \
    || die "normal package evaluation is impure"
  printf 'source policy: ok\n'
}

verify_result() {
  local result=${1%/}
  [[ -x $result/bin/br ]] || die "missing executable: $result/bin/br"
  [[ -f $result/share/applications/br.desktop ]] || die "missing br.desktop"
  [[ -f $result/share/br/build-args.gn ]] || die "missing recorded GN arguments"
  grep -Eq '^enable_tor[[:space:]]*=[[:space:]]*false$' "$result/share/br/build-args.gn" \
    || die "recorded GN arguments do not contain enable_tor=false"
  grep -Fq 'user-data-dir="$profile_root/br"' "$result/bin/br" \
    || die "installed wrapper does not isolate the profile"
  grep -Eq '^Name=BR$' "$result/share/applications/br.desktop" \
    || die "desktop name is not BR"
  grep -Eq '^Exec=br %U$' "$result/share/applications/br.desktop" \
    || die "desktop executable is not br"
  if command -v desktop-file-validate >/dev/null; then
    desktop-file-validate "$result/share/applications/br.desktop"
  fi
  if find -L "$result" -type l -print -quit | grep -q .; then
    die "package has dangling symlinks"
  fi
  "$result/bin/br" --version >/dev/null
  printf 'package verification: ok\n'
}

case ${1:-} in
  --source)
    [[ $# == 2 ]] || die "usage: verify.sh --source REPOSITORY"
    verify_source "$2"
    ;;
  "") die "usage: verify.sh RESULT | verify.sh --source REPOSITORY" ;;
  *)
    [[ $# == 1 ]] || die "usage: verify.sh RESULT"
    verify_result "$1"
    ;;
esac
