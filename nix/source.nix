{
  pkgs,
  metadataFile ? ./sources.json,
}:
let
  metadata = builtins.fromJSON (builtins.readFile metadataFile);
  fetch =
    value:
    pkgs.fetchzip {
      inherit (value) url hash;
      stripRoot = true;
    };
  deps = pkgs.lib.mapAttrs (_path: fetch) metadata.deps;
  core = fetch metadata.core;
  devtoolsEsbuild = fetch metadata.devtoolsEsbuild;
  corePackageManager = metadata.corePackageManager or "npm";
  isPnpm = corePackageManager == "pnpm";
  leo = if isPnpm then null else fetch metadata.leo;

  leoArtifacts =
    if isPnpm then
      null
    else
      pkgs.buildNpmPackage {
        pname = "br-leo-artifacts";
        inherit (metadata) version;
        src = leo;
        nodejs = pkgs.nodejs_24;
        npmDepsHash = metadata.leoNpmDepsHash;
        makeCacheWritable = true;
        npmBuildScript = "build";
        dontFixup = true;
        installPhase = ''
          runHook preInstall
          rm -rf node_modules
          mkdir -p "$out"
          cp -a . "$out/"
          runHook postInstall
        '';
      };

  corePnpmDeps =
    if isPnpm then
      pkgs.fetchPnpmDeps {
        pname = "br-core-pnpm-deps";
        inherit (metadata) version;
        src = core;
        pnpm = pkgs.pnpm_11;
        fetcherVersion = 4;
        hash = metadata.corePnpmDepsHash;
      }
    else
      null;

  npmCoreNodeModules = pkgs.stdenvNoCC.mkDerivation {
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
      runHook postInstall
    '';
  };

  pnpmCoreNodeModules = pkgs.stdenvNoCC.mkDerivation {
    pname = "br-core-node-modules";
    inherit (metadata) version;
    src = core;
    pnpmDeps = corePnpmDeps;
    nativeBuildInputs = [
      pkgs.nodejs_24
      pkgs.pnpm_11
      pkgs.pnpmConfigHook
    ];
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a node_modules "$out/"
      runHook postInstall
    '';
  };

  coreNodeModules = if isPnpm then pnpmCoreNodeModules else npmCoreNodeModules;

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
    corePackageManager
    coreNodeModules
    corePnpmDeps
    deps
    devtoolsEsbuild
    leo
    leoArtifacts
    wdpNodeModules
    ;
}
