{
  pkgs,
}:
let
  metadata = builtins.fromJSON (builtins.readFile ./sources.json);
  fetch =
    value:
    pkgs.fetchzip {
      inherit (value) url hash;
      stripRoot = true;
  };
  deps = pkgs.lib.mapAttrs (_path: fetch) metadata.deps;
  core = fetch metadata.core;

  coreNodeModules = pkgs.stdenvNoCC.mkDerivation {
    pname = "br-core-node-modules";
    inherit (metadata) version;
    nativeBuildInputs = [
      pkgs.nodejs_24
      pkgs.cacert
    ];
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = metadata.coreNodeModulesHash;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    installPhase = ''
      runHook preInstall
      export HOME="$TMPDIR/home"
      workDir="$TMPDIR/brave-npm"
      mkdir -p "$workDir" "$HOME"
      cp ${core}/package.json ${core}/package-lock.json "$workDir/"
      cd "$workDir"
      export npm_config_cache="$TMPDIR/npm-cache"
      npm ci --ignore-scripts --no-audit --no-fund

      mkdir -p "$out"
      cp -a node_modules "$out/"
      rm -rf "$npm_config_cache/_logs"
      cp -a "$npm_config_cache" "$out/npm-cache"
      runHook postInstall
    '';
  };

  wdpNodeModules = pkgs.stdenvNoCC.mkDerivation {
    pname = "br-web-discovery-node-modules";
    inherit (metadata) version;
    src = deps."vendor/web-discovery-project";
    nativeBuildInputs = [
      pkgs.nodejs_24
      pkgs.cacert
    ];
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = metadata.wdpNodeModulesHash;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    installPhase = ''
      runHook preInstall
      export HOME="$TMPDIR/home"
      export npm_config_cache="$TMPDIR/npm-cache"
      npm ci --ignore-scripts --no-audit --no-fund
      node node_modules/patch-package/index.js
      mkdir -p "$out"
      cp -a node_modules modules "$out/"
      runHook postInstall
    '';
  };
in
metadata
// {
  inherit
    core
    coreNodeModules
    deps
    wdpNodeModules
    ;
}
