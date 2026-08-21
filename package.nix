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
  braveVersionParts = lib.splitString "." sources.version;
  braveGnImports = lib.concatStringsSep " " [
    ''import("//brave/build/args/brave_defaults.gni")''
    ''import("//brave/build/args/blink_platform_defaults.gni")''
    ''import("//brave/build/args/branding_defaults.gni")''
    ''import("//brave/build/args/desktop_defaults.gni")''
  ];
  redirectCC = pkgs.writeShellScript "brave-redirect-cc" (builtins.readFile ./nix/redirect-cc.sh);

  unwrappedBase = chromium.passthru.mkDerivation (base: {
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
      mkdir -p "$TMPDIR/br-npm-cache"
      (
        cd brave
        patchShebangs node_modules
        npm_config_cache="$TMPDIR/br-npm-cache" \
          npm rebuild --offline --no-audit --no-fund
        patchShebangs node_modules
      )
      # @brave/leo is a Git dependency whose generated artifacts are normally
      # produced by its prepare script. Build those with their own pinned npm
      # dependency graph and install the prepared package here.
      rm -rf brave/node_modules/@brave/leo
      cp -a ${sources.leoArtifacts} brave/node_modules/@brave/leo
      chmod -R u+w brave/node_modules/@brave/leo
      mkdir -p brave/vendor/web-discovery-project/node_modules
      cp -a ${sources.wdpNodeModules}/node_modules/. \
        brave/vendor/web-discovery-project/node_modules/
      rm -rf brave/vendor/web-discovery-project/modules
      cp -a ${sources.wdpNodeModules}/modules \
        brave/vendor/web-discovery-project/modules
      chmod -R u+w \
        brave/vendor/web-discovery-project/node_modules \
        brave/vendor/web-discovery-project/modules

      # Brave 1.93.137 accidentally unpacks os.walk() as a two-tuple in its
      # legacy patch driver.  Fix the pinned helper before asking it to apply
      # Brave's own Chromium patch series.
      patch -p1 < ${./patches/0000-fix-brave-patch-walker.patch}
      python3 brave/script/apply-patches.py
      patch -p1 < ${./patches/0001-use-br-user-data-directory.patch}
      patch -p1 < ${./patches/0002-allow-linux-installer-without-sysroot.patch}
      substituteInPlace brave/components/common/rust_to_wasm.gni \
        --replace-fail \
          '    response_file_contents = [ "PATH=./" + host_path_sep +' \
          '    response_file_contents = [
      "CARGO_HOME=" +
          rebase_path("//brave/third_party/wasm/cargo-home"),
      "PATH=./" + host_path_sep +'

      # The upstream build command copies Brave's branding files into their
      # Chromium destinations immediately before GN generation.
      node --input-type=module <<'EOF'
      import config from './brave/build/commands/lib/config.ts'
      import branding from './brave/build/commands/lib/branding.js'
      config.channel = ""
      branding.update()
      EOF

      cp chrome/VERSION chrome/VERSION.chromium
      sed -i \
        -e 's/^MINOR=.*/MINOR=${builtins.elemAt braveVersionParts 0}/' \
        -e 's/^BUILD=.*/BUILD=${builtins.elemAt braveVersionParts 1}/' \
        -e 's/^PATCH=.*/PATCH=${builtins.elemAt braveVersionParts 2}/' \
        chrome/VERSION

      # nixpkgs' Chromium postPatch normalizes every executable file and then
      # runs patchShebangs over the complete tree. Keep Cargo's immutable
      # vendored sources out of that pass: changing even an unused test script
      # invalidates its .cargo-checksum.json, while touching an executable WASM
      # fixture can corrupt it.
      mv brave/tools/crates/vendor "$TMPDIR/brave-tools-crates-vendor"
      mv brave/third_party/wasm/vendor "$TMPDIR/brave-wasm-vendor"
    ''
    + base.postPatch
    + ''
      mv "$TMPDIR/brave-tools-crates-vendor" brave/tools/crates/vendor
      mv "$TMPDIR/brave-wasm-vendor" brave/third_party/wasm/vendor

      # wasm-pack runs cargo metadata before forwarding its explicit Cargo
      # arguments. Give that subprocess a dedicated Cargo home whose source
      # replacement is independent of Ninja's working directory.
      mkdir -p brave/third_party/wasm/cargo-home
      cat > brave/third_party/wasm/cargo-home/config.toml <<EOF
      [source.crates-io]
      replace-with = "vendored-sources"

      [source.vendored-sources]
      directory = "$(pwd)/brave/third_party/wasm/vendor"

      [net]
      offline = true
      EOF

      # Brave builds additional Rust/WASM tools which need Cargo alongside the
      # rustc link already installed by nixpkgs' Chromium postPatch.
      ln -s ${pkgs.buildPackages.cargo}/bin/cargo \
        third_party/rust-toolchain/bin/cargo
      # DevTools requires its exact platform-specific esbuild binary at a CIPD
      # path. The generic npm graph omits this optional platform package.
      mkdir -p third_party/devtools-frontend/src/third_party/esbuild
      ln -s ${sources.devtoolsEsbuild}/bin/esbuild \
        third_party/devtools-frontend/src/third_party/esbuild/esbuild
      python3 brave/build/util/version.py gen chrome/VERSION
    '';

    # Brave's command wrapper normally supplies these source-tree Python
    # paths. Ninja actions patched by Brave import brave_chromium_utils and
    # must inherit the same environment when built through nixpkgs Chromium.
    preBuild = (base.preBuild or "") + ''
      export PYTHONPATH="$(pwd)/brave/script:$(pwd)/tools/grit/grit/extern:$(pwd)/brave/vendor/requests:$(pwd)/brave/third_party/cryptography:$(pwd)/brave/third_party/macholib:$(pwd)/build:$(pwd)/third_party/depot_tools''${PYTHONPATH:+:$PYTHONPATH}"
      export PYTHONUNBUFFERED=1
      export CARGO_NET_OFFLINE=true
    '';

    gnFlags = {
      # This upstream GN argument generates BUILDFLAG(ENABLE_TOR).
      enable_tor = false;
      brave_channel = "";
      # Official Brave builds require private service keys which are not part
      # of the public source tree. Build the supported community/source variant.
      is_official_build = false;
      # Chromium otherwise derives both of these as true from a non-official
      # build. Keep the community build in release/static mode: component debug
      # libraries do not carry the final Rust allocator dependency closure.
      is_debug = false;
      is_component_build = false;
      # Chromium defaults community Linux builds to its downloaded CIPD mold.
      # Nixpkgs already supplies lld through the system LLVM toolchain.
      use_mold = false;
      # Brave normally redirects Chromium compilation units through Siso so
      # matching brave/chromium_src wrappers are compiled instead. Nixpkgs
      # builds with Ninja, so provide the equivalent compiler wrapper.
      cc_wrapper = "${redirectCC}";
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

  # Brave's own build command imports these defaults before adding individual
  # GN arguments. chromium.passthru.mkDerivation accepts only key/value flags,
  # so prepend the imports to the generated --args string afterwards.
  unwrapped = unwrappedBase.overrideAttrs (old: {
    configurePhase =
      builtins.replaceStrings [ "gn gen --args='" ] [ "gn gen --args='${braveGnImports} " ]
        old.configurePhase;
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
