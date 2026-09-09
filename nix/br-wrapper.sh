#!/usr/bin/env bash
set -euo pipefail

profile_root="${XDG_CONFIG_HOME:-${HOME:?HOME is not set}/.config}"

if [[ -x /run/wrappers/bin/br-sandbox ]]; then
  export CHROME_DEVEL_SANDBOX=/run/wrappers/bin/br-sandbox
else
  export CHROME_DEVEL_SANDBOX=@sandbox@
fi

export CHROME_WRAPPER=br
if [[ -d /run/opengl-driver/lib ]]; then
  graphics_root=/run/opengl-driver
else
  graphics_root=@mesa@
fi
graphics_lib="$graphics_root/lib"
graphics_share="$graphics_root/share"

export LD_LIBRARY_PATH="$graphics_lib:@libPath@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$graphics_lib/dri${LIBGL_DRIVERS_PATH:+:$LIBGL_DRIVERS_PATH}"
export LIBVA_DRIVERS_PATH="$graphics_lib/dri${LIBVA_DRIVERS_PATH:+:$LIBVA_DRIVERS_PATH}"
export __EGL_VENDOR_LIBRARY_DIRS="$graphics_share/glvnd/egl_vendor.d${__EGL_VENDOR_LIBRARY_DIRS:+:$__EGL_VENDOR_LIBRARY_DIRS}"
vulkan_icds=()
for vulkan_icd in "$graphics_share"/vulkan/icd.d/*.json; do
  [[ -e $vulkan_icd ]] || continue
  vulkan_icds+=("$vulkan_icd")
done
if ((${#vulkan_icds[@]})); then
  IFS=:
  export VK_DRIVER_FILES="${vulkan_icds[*]}${VK_DRIVER_FILES:+:$VK_DRIVER_FILES}"
  unset IFS
fi
export PATH="$PATH:@xdgUtils@"

wayland_args=()
if [[ -n ${NIXOS_OZONE_WL:-} && -n ${WAYLAND_DISPLAY:-} ]]; then
  wayland_args+=(--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true)
fi

exec @browser@ --user-data-dir="$profile_root/br" "${wayland_args[@]}" "$@"
