# br

`br` is a Nix-packaged downstream build of Brave Browser compiled from
upstream source with Brave's Tor functionality disabled.

This project is unofficial, is not affiliated with or endorsed by Brave
Software, and is not an official Brave distribution. The neutral `BR` desktop
icon is used to avoid presenting the downstream package as an official build.
It is built in Brave's community/source mode because the private service keys
required by official builds are not distributed with the public source tree.

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

The exact Brave Stable and Chromium versions are recorded in
[`nix/sources.json`](nix/sources.json). `brave-core` and every unconditional
Linux dependency in its `DEPS` file are fixed-output sources with hashes in
[`nix/sources.json`](nix/sources.json). Chromium's much larger recursive source
graph is taken from the locked nixpkgs Chromium expression at exactly the same
Chromium version. nixpkgs assembles that graph from individually hashed Gitiles
sources; no `gclient` download or other network access occurs in the browser
build.

The metadata records Brave core's dependency manager. Releases through the
1.93 line use the root `package-lock.json`; their dependencies and separate
`@brave/leo` build remain compatible with the existing fixed-output npm path.
Newer releases use `pnpm-lock.yaml`. They are fetched with pnpm 11,
`fetchPnpmDeps`, and fetcher version 4, then installed offline with scripts
disabled. The browser derivation runs only the lifecycle scripts authorized by
upstream `allowBuilds`, so the workspace owns the `@brave/leo` preparation.
The Chromium/Brave compilation consumes the resulting immutable node tree
offline in both cases.

The Web Discovery dependency is handled by its own fixed-output derivation.
Both its npm tree and the patched generated `modules` tree are copied into the
writable build source before Brave's patch and build phases.

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

## Graphics runtime

The `br` wrapper includes Mesa in its runtime closure. On NixOS it selects
`/run/opengl-driver`; on other Linux distributions it uses the packaged Mesa
runtime. It exports the matching GLX/EGL, DRI, VA-API, and Vulkan search paths
without adding experimental Chromium flags. The existing X11/Wayland choice
and the profile at `~/.config/br` are unchanged.

On non-NixOS systems with the proprietary NVIDIA driver, launch `br` through a
system driver wrapper such as NixGL so the userspace libraries match the loaded
kernel driver. That configuration is outside the packaged Mesa fallback.

## Updating

Check the official Linux Stable channel without changing files:

```console
./scripts/update.sh --check
```

Apply an update locally:

```console
./scripts/update.sh
```

The updater reads Brave's official Linux x64 Stable channel endpoint (not
GitHub's ambiguous `latest` release). It rejects beta, nightly, arbitrary
`--version` values, and downgrades. It fetches the tagged core, regenerates all
Brave DEPS hashes and dependency metadata, updates the nixpkgs lock, verifies
an exact Chromium version match, and runs the lightweight checks. If nixpkgs
has not yet packaged Brave's Chromium revision, the updater exits with the
temporary status `75` and restores both metadata files. The scheduled workflow
treats only this status as a successful deferred update, records the reason in
its job summary, and publishes no PR. Unsupported source formats, hash failures,
and test failures remain errors. Other Brave channels are never followed by
scheduled automation.

The scheduled GitHub workflow opens or updates an idempotent
`automation/brave-VERSION` pull request. Before updating an existing branch it
requires one unmerged automation commit, the GitHub Actions bot identity, the
expected commit subject, and changes confined to `flake.lock` and
`nix/sources.json`. Updates use an exact remote SHA lease; a foreign edit or
race fails closed. A closed PR is not silently replaced with a duplicate. The
workflow never merges and never starts the full browser build. After publishing
a new PR, it closes an older Stable PR only when the bot identity, expected
subject, one-commit ancestry, and metadata-only file list are all proven. It
retains the old remote branch.

The updater uses the ephemeral repository `GITHUB_TOKEN` with only
`contents: write` and `pull-requests: write`. Repository Settings → Actions →
General must enable [“Allow GitHub Actions to create and approve pull
requests”][actions-settings] for PR creation. The repository-wide switch also
makes approval available to any trusted workflow that explicitly requests
`pull-requests: write`; this repository's updater never requests or performs
approval. Keeping the default workflow permission at read and granting writes
only in the updater limits the effective capability. A dedicated GitHub App is
warranted instead if separate PR-triggered workflows must run automatically
from bot-created events, but it adds a private key and token-minting lifecycle.

GitHub [suppresses most new workflow runs][token-events] caused by
`GITHUB_TOKEN`; supported pull-request events may instead wait for a maintainer
to approve the workflow run. The updater therefore runs `nix flake check`,
source verification, and the automation tests itself before publishing the PR.
The PR records that result; it does not claim a full browser build.

[actions-settings]: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#configuring-the-default-github_token-permissions
[token-events]: https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow#triggering-a-workflow-from-a-workflow

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
enabled on ordinary GitHub-hosted runners. It is available only through the
`full Brave build` workflow's manual dispatch.

For the recommended release gate:

1. Review the Stable update PR and copy its head ref, exact 40-character head
   commit SHA, and Brave version from `nix/sources.json`.
2. Open Actions → `full Brave build`, select the same ref in “Use workflow
   from”, and enter that ref, Brave version, and commit SHA in the three
   confirmation inputs.
3. Confirm that the run title and `Confirmed full-build selection` summary show
   the intended ref, commit, Stable channel, and version. A mismatch stops
   before provisioning the large builder.
4. Merge only after that exact commit's full build and result verification
   succeed. If the PR head changes, run the manual build again for the new SHA.

## Licensing

The packaging and automation in this repository are MIT licensed. Brave core
is MPL-2.0 and Chromium plus third-party dependencies retain their own licenses
and notices. The build preserves upstream source notices and generated
third-party licensing resources. See [`LICENSES/UPSTREAM.md`](LICENSES/UPSTREAM.md).
