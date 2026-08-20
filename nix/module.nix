{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.br;
in
{
  options.programs.br = {
    enable = lib.mkEnableOption "the br browser";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.br;
      defaultText = lib.literalExpression "inputs.br.packages.${pkgs.system}.br";
      description = "The br package to install.";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    security.wrappers.br-sandbox = {
      source = "${cfg.package.sandbox}/bin/${cfg.package.sandboxExecutableName}";
      owner = "root";
      group = "root";
      setuid = true;
    };
  };
}
