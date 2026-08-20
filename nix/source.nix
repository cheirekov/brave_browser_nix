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
  inherit core deps wdpNodeModules;
  npmDeps = pkgs.fetchNpmDeps {
    src = core;
    hash = metadata.npmHash;
  };
}
