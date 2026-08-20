# br

`br` is a Nix-packaged downstream build of Brave Browser compiled from
upstream source with Brave's Tor functionality disabled.

This project is unofficial, is not affiliated with or endorsed by Brave
Software, and is not an official Brave distribution. The neutral `BR` desktop
icon is used to avoid presenting the downstream package as an official build.

## Installation

Replace `OWNER` with the GitHub owner of your fork:

```console
nix profile install github:OWNER/br#br
```

Building locally requires substantial disk, memory, and time:

```console
nix build github:OWNER/br#br
```

Only `x86_64-linux` is currently exposed. Chromium and Brave have upstream
arm64 support, but this package does not claim it until the complete downstream
build has been verified there.

## NixOS flake usage

Add the input:

```nix
inputs.br.url = "github:OWNER/br";
```

Consume the package directly:

```nix
environment.systemPackages = [
  inputs.br.packages.${pkgs.system}.br
];
```

Or use the overlay:

```nix
nixpkgs.overlays = [ inputs.br.overlays.default ];
environment.systemPackages = [ pkgs.br ];
```

The optional module installs the package and configures its setuid sandbox:

```nix
imports = [ inputs.br.nixosModules.default ];
programs.br.enable = true;
```

The package and overlay do not depend on the module. Home Manager users can
install `inputs.br.packages.${pkgs.system}.br` in `home.packages`; the browser
can use unprivileged user namespaces when the NixOS setuid wrapper is absent.

## Design

```text
Upstream Brave
      │
      ▼
Pinned source
      │
      ▼
Nix build
      │
      ├── Tor disabled at compile time
      ├── minimal downstream naming
      └── isolated profile
      │
      ▼
     br
```

The pinned release is Brave `1.93.137`, based on Chromium
`151.0.7922.169`. `brave-core` and every unconditional Linux dependency in its
`DEPS` file are fixed-output sources with hashes in
[`nix/sources.json`](nix/sources.json). Chromium's much larger recursive source
graph is taken from the locked nixpkgs Chromium expression at exactly the same
Chromium version. nixpkgs assembles that graph from individually hashed Gitiles
sources; no `gclient` download or other network access occurs in the browser
build.

Brave currently declares `enable_tor` in
`components/tor/buildflags/buildflags.gni`. Its buildflag target maps that GN
argument to `BUILDFLAG(ENABLE_TOR)`, which guards the Tor services, commands,
and UI call sites. The package passes `enable_tor=false` to GN. No policy,
runtime preference, or binary removal is used to disable Tor.

The executable and desktop file are named `br`. Most source-level Brave branding is
left intact to minimize trademark and maintenance risk. The wrapper always
passes `--user-data-dir="${XDG_CONFIG_HOME:-$HOME/.config}/br"`, so it does not
share upstream Brave's Linux profile at
`${XDG_CONFIG_HOME:-$HOME/.config}/BraveSoftware/Brave-Browser`.
A small downstream patch changes the compiled Linux default to the same `br`
path, preventing subsystems which bypass the command-line override from
recreating the upstream directory. Chromium consequently maps the cache to
`${XDG_CACHE_HOME:-$HOME/.cache}/br`.

All downstream modifications are described in this README and
[`patches/README.md`](patches/README.md): the GN argument, output packaging,
neutral icon, executable/desktop naming, and profile-selecting wrapper.

## Updating

Check the official Linux Stable channel without changing files:

```console
./scripts/update.sh --check
```

Apply an update locally:

```console
./scripts/update.sh
```

The updater reads Brave's official Stable channel endpoint (not GitHub's
ambiguous `latest` release), fetches the tagged core, regenerates all Brave
DEPS hashes and npm metadata, updates the nixpkgs lock, verifies an exact
Chromium version match, and runs the lightweight checks. If nixpkgs has not yet
packaged Brave's Chromium revision, the update fails and restores both metadata
files; retry after nixpkgs catches up.

The scheduled GitHub workflow opens or updates an idempotent
`automation/brave-VERSION` pull request. It never merges automatically.

## Verification

Lightweight evaluation and source-policy checks:

```console
nix flake check
./scripts/verify.sh --source .
```

Full verification after the resource-intensive build:

```console
nix build .#br
./scripts/verify.sh ./result
```

The full verifier checks `/bin/br`, `--version`, the desktop entry, runtime
resource links, the isolated-profile wrapper, and the installed `args.gn` for
`enable_tor=false`. The recorded GN configuration is stronger evidence than
searching binary strings; upstream compile guards then exclude the Tor UI and
implementation. A full build belongs on a large self-hosted runner and is not
enabled on ordinary GitHub-hosted runners.

## Licensing

The packaging and automation in this repository are MIT licensed. Brave core
is MPL-2.0 and Chromium plus third-party dependencies retain their own licenses
and notices. The build preserves upstream source notices and generated
third-party licensing resources. See [`LICENSES/UPSTREAM.md`](LICENSES/UPSTREAM.md).
