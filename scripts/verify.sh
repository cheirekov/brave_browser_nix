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
  grep -Eq 'is_official_build[[:space:]]*=[[:space:]]*false' "$root/package.nix" \
    || die "package does not select the community/source build mode"
  grep -Eq 'use_mold[[:space:]]*=[[:space:]]*false' "$root/package.nix" \
    || die "package does not disable Chromium's unavailable CIPD mold linker"
  grep -Fq 'cc_wrapper = "${redirectCC}"' "$root/package.nix" \
    || die "package does not redirect Brave chromium_src compilation units"
  [[ -f $root/nix/redirect-cc.sh ]] \
    || die "Brave chromium_src compiler redirect wrapper is missing"
  for defaults in brave_defaults blink_platform_defaults branding_defaults desktop_defaults; do
    grep -Fq "//brave/build/args/$defaults.gni" "$root/package.nix" \
      || die "package does not import Brave's $defaults GN defaults"
  done
  grep -Fq 'BUILDFLAG(ENABLE_TOR)' "$root/README.md" \
    || die "Tor build flag mapping is not documented"
  grep -Fq 'user-data-dir="$profile_root/br"' "$root/nix/br-wrapper.sh" \
    || die "wrapper does not isolate the profile"
  grep -Fq 'config_dir.Append("br")' "$root/patches/0001-use-br-user-data-directory.patch" \
    || die "compiled default profile path is not patched to br"
  grep -Fq 'rebase_path(installer_sysroot, root_build_dir)' \
    "$root/patches/0002-allow-linux-installer-without-sysroot.patch" \
    || die "Linux installer targets do not support the distro build without a sysroot"
  grep -Fq "import branding from './brave/build/commands/lib/branding.js'" \
    "$root/package.nix" \
    || die "package does not run Brave's branding preparation step"
  grep -Fq 'third_party/rust-toolchain/bin/cargo' "$root/package.nix" \
    || die "package does not provide Cargo for Brave's Rust/WASM tools"
  grep -Fq 'third_party/devtools-frontend/src/third_party/esbuild/esbuild' \
    "$root/package.nix" \
    || die "package does not expose DevTools' pinned esbuild at its CIPD path"
  [[ $(jq -r .devtoolsEsbuild.hash "$metadata") == sha256-* ]] \
    || die "DevTools esbuild binary is not hash-pinned"
  grep -Fq 'old["devtoolsEsbuild"]' "$root/scripts/update_sources.py" \
    || die "source updater does not preserve the pinned DevTools esbuild binary"
  grep -Fq 'brave/script:$(pwd)/tools/grit/grit/extern' "$root/package.nix" \
    || die "package does not provide Brave's Python module search paths"
  [[ $(jq -r .leo.hash "$metadata") == sha256-* ]] \
    || die "@brave/leo source is not hash-pinned"
  [[ $(jq -r .leoNpmDepsHash "$metadata") == sha256-* ]] \
    || die "@brave/leo npm dependencies are not hash-pinned"
  grep -Fq 'package["dependencies"]["@brave/leo"]' "$root/scripts/update_sources.py" \
    || die "source updater does not track Brave's @brave/leo revision"
  grep -Fq ').leoArtifacts' "$root/scripts/update.sh" \
    || die "update script does not refresh @brave/leo npm dependencies"
  grep -Fq 'sources.leoArtifacts' "$root/package.nix" \
    || die "package does not install generated @brave/leo artifacts"
  [[ $(grep -Fc 'for root, _, files in' "$root/patches/0000-fix-brave-patch-walker.patch") == 2 ]] \
    || die "Brave patch walker compatibility fix is incomplete"
  [[ $(grep -nF '0000-fix-brave-patch-walker.patch' "$root/package.nix" | head -n1 | cut -d: -f1) \
      -lt $(grep -nF 'python3 brave/script/apply-patches.py' "$root/package.nix" | head -n1 | cut -d: -f1) ]] \
    || die "Brave patch walker fix is not applied before the patch driver"
  grep -Fq "PATCH = 'patch'" "$root/patches/0000-fix-brave-patch-walker.patch" \
    || die "Brave patch walker does not use the offset-aware patch backend"
  grep -Fq 'cp chrome/VERSION chrome/VERSION.chromium' "$root/package.nix" \
    || die "Chromium version sidecar is not generated for the Git-free source"
  [[ $(jq -r .coreNodeModulesHash "$metadata") == sha256-* ]] \
    || die "core node_modules output is not hash-pinned"
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
  grep -Eq '^is_official_build[[:space:]]*=[[:space:]]*false$' "$result/share/br/build-args.gn" \
    || die "recorded GN arguments do not select the community/source build mode"
  grep -Eq '^use_mold[[:space:]]*=[[:space:]]*false$' "$result/share/br/build-args.gn" \
    || die "recorded GN arguments do not disable the unavailable CIPD mold linker"
  grep -Eq '^cc_wrapper[[:space:]]*=' "$result/share/br/build-args.gn" \
    || die "recorded GN arguments do not enable chromium_src redirection"
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
