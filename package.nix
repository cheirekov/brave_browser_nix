{
  lib,
  pkgs,
  stdenv,
  chromium,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  libva,
  pipewire,
  wayland,
  gtk3,
  gtk4,
  libkrb5,
  xdg-utils,
}:
let
  sources = import ./nix/source.nix { inherit pkgs; };

  unwrapped = chromium.passthru.mkDerivation (base: {
    name = "br-browser";
    version = sources.version;
    packageName = "br";
    buildTargets = [ "brave" ];
    outputs = [
      "out"
      "sandbox"
    ];

    postUnpack =
      (base.postUnpack or "")
      + ''
        cp -a ${sources.core} src/brave
        chmod -R u+w src/brave
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (path: source: ''
          mkdir -p "src/brave/${lib.dirOf path}"
          cp -a ${source} "src/brave/${path}"
          chmod -R u+w "src/brave/${path}"
        '') sources.deps
      )
      + ''
        mkdir -p src/brave/vendor/web-discovery-project/.git
        printf '%s\n' '${sources.deps."vendor/web-discovery-project"}' \
          > src/brave/vendor/web-discovery-project/.git/HEAD
      '';

    postPatch = ''
      export HOME="$TMPDIR/br-home"
      mkdir -p "$HOME"
      cp -a ${sources.coreNodeModules}/node_modules brave/
      chmod -R u+w brave/node_modules
      cp -a ${sources.coreNodeModules}/npm-cache "$TMPDIR/br-npm-cache"
      chmod -R u+w "$TMPDIR/br-npm-cache"
      (
        cd brave
        patchShebangs node_modules
        npm_config_cache="$TMPDIR/br-npm-cache" \
          npm rebuild --offline --no-audit --no-fund
        patchShebangs node_modules
      )
      mkdir -p brave/vendor/web-discovery-project/node_modules
      cp -a ${sources.wdpNodeModules}/node_modules/. \
        brave/vendor/web-discovery-project/node_modules/

      python3 brave/script/apply-patches.py
      patch -p1 < ${./patches/0001-use-br-user-data-directory.patch}
      python3 brave/build/util/version.py update chrome/VERSION \
        --brave-version ${sources.version}
    ''
    + base.postPatch
    + ''
      python3 brave/build/util/version.py gen chrome/VERSION
    '';

    gnFlags = {
      # This upstream GN argument generates BUILDFLAG(ENABLE_TOR).
      enable_tor = false;
      brave_channel = "";
      is_brave_release_build = true;
    };

    installPhase = ''
      runHook preInstall
      libExecPath="$out/libexec/br"
      mkdir -p "$libExecPath" "$sandbox/bin"
      cp -v "$buildPath/"*.so "$buildPath/"*.pak "$buildPath/"*.bin "$libExecPath/"
      cp -v "$buildPath/libvulkan.so.1" "$buildPath/vk_swiftshader_icd.json" "$libExecPath/"
      cp -v "$buildPath/icudtl.dat" "$buildPath/chrome_crashpad_handler" "$libExecPath/"
      cp -vLR "$buildPath/locales" "$buildPath/resources" "$libExecPath/"
      cp -v "$buildPath/brave" "$libExecPath/br"
      if find "$buildPath/swiftshader" -maxdepth 1 -name '*.so' -print -quit | grep -q .; then
        mkdir -p "$libExecPath/swiftshader"
        cp -v "$buildPath/swiftshader/"*.so "$libExecPath/swiftshader/"
      fi
      cp -v "$buildPath/brave_sandbox" "$sandbox/bin/br-sandbox"
      mkdir -p "$out/share/br"
      cp -v "$buildPath/args.gn" "$out/share/br/build-args.gn"
      runHook postInstall
    '';

    passthru = {
      inherit sources;
      sandboxExecutableName = "br-sandbox";
    };
    requiredSystemFeatures = [ "big-parallel" ];
    meta = {
      description = "Downstream Brave build compiled without Tor support";
      homepage = "https://github.com/brave/brave-core";
      license = lib.licenses.mpl20;
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.fromSource ];
    };
  });

  libPath = lib.makeLibraryPath [
    libva
    pipewire
    wayland
    gtk3
    gtk4
    libkrb5
  ];
  desktopItem = makeDesktopItem {
    name = "br";
    desktopName = "BR";
    genericName = "Web Browser";
    comment = "Browse the Web";
    exec = "br %U";
    icon = "br";
    terminal = false;
    startupNotify = true;
    startupWMClass = "Brave-browser";
    categories = [
      "Network"
      "WebBrowser"
    ];
    mimeTypes = [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ];
  };
in
stdenv.mkDerivation {
  pname = "br";
  inherit (sources) version;
  dontUnpack = true;
  nativeBuildInputs = [
    makeWrapper
    copyDesktopItems
  ];
  desktopItems = [ desktopItem ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/icons/hicolor/scalable/apps" "$out/share/br"
    install -m755 ${./nix/br-wrapper.sh} "$out/bin/br"
    substituteInPlace "$out/bin/br" \
      --replace-fail '@browser@' '${unwrapped}/libexec/br/br' \
      --replace-fail '@sandbox@' '${unwrapped.sandbox}/bin/br-sandbox' \
      --replace-fail '@libPath@' '${libPath}' \
      --replace-fail '@xdgUtils@' '${xdg-utils}/bin'
    install -m644 ${./assets/br.svg} "$out/share/icons/hicolor/scalable/apps/br.svg"
    ln -s ${unwrapped}/share/br/build-args.gn "$out/share/br/build-args.gn"
    runHook postInstall
  '';
  passthru = {
    inherit unwrapped;
    inherit (unwrapped) sandbox;
    inherit (unwrapped.passthru) sandboxExecutableName sources;
  };
  meta = unwrapped.meta // {
    mainProgram = "br";
  };
}
