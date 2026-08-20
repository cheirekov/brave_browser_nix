#!/usr/bin/env bash
set -euo pipefail

profile_root="${XDG_CONFIG_HOME:-${HOME:?HOME is not set}/.config}"

if [[ -x /run/wrappers/bin/br-sandbox ]]; then
  export CHROME_DEVEL_SANDBOX=/run/wrappers/bin/br-sandbox
else
  export CHROME_DEVEL_SANDBOX=@sandbox@
fi

export CHROME_WRAPPER=br
export LD_LIBRARY_PATH="@libPath@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$PATH:@xdgUtils@"

wayland_args=()
if [[ -n ${NIXOS_OZONE_WL:-} && -n ${WAYLAND_DISPLAY:-} ]]; then
  wayland_args+=(--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true)
fi

exec @browser@ --user-data-dir="$profile_root/br" "${wayland_args[@]}" "$@"
