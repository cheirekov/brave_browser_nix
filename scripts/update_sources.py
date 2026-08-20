#!/usr/bin/env python3
"""Regenerate fixed-output Brave source metadata from an unpacked release."""

from __future__ import annotations

import argparse
import ast
import concurrent.futures
import json
import pathlib
import re
import subprocess
import sys
import warnings


def run(*argv: str) -> str:
    result = subprocess.run(argv, check=True, text=True, capture_output=True)
    return result.stdout


def prefetch(url: str) -> str:
    data = json.loads(run("nix", "store", "prefetch-file", "--json", "--unpack", url))
    return data["hash"]


def deps_from_file(path: pathlib.Path) -> dict[str, str]:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", SyntaxWarning)
        tree = ast.parse(path.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "deps" for target in node.targets
        ):
            raw = ast.literal_eval(node.value)
            break
    else:
        raise RuntimeError("DEPS has no literal deps assignment")

    result: dict[str, str] = {}
    for destination, value in raw.items():
        if isinstance(value, dict):
            if value.get("condition"):
                continue
            value = value["url"]
        if not isinstance(value, str) or not value.startswith("https://github.com/"):
            raise RuntimeError(f"unsupported Brave DEP: {destination}={value!r}")
        url, revision = value.rsplit("@", 1)
        url = url.removesuffix(".git")
        result[destination] = f"{url}/archive/{revision}.tar.gz"
    return result


def npm_hash(lockfile: pathlib.Path) -> str:
    output = run(
        "nix", "shell", "nixpkgs#prefetch-npm-deps", "-c",
        "prefetch-npm-deps", str(lockfile),
    )
    hashes = re.findall(r"sha256-[A-Za-z0-9+/]{43}=", output)
    if not hashes:
        raise RuntimeError("prefetch-npm-deps did not return a hash")
    return hashes[-1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--core", type=pathlib.Path, required=True)
    parser.add_argument("--core-hash", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()

    package = json.loads((args.core / "package.json").read_text())
    if package["version"] != args.version:
        raise RuntimeError("requested version does not match brave-core package.json")
    chromium_version = package["config"]["projects"]["chrome"]["tag"]
    urls = deps_from_file(args.core / "DEPS")

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        hashes = dict(zip(urls, pool.map(prefetch, urls.values()), strict=True))

    old = json.loads(args.output.read_text()) if args.output.exists() else {}
    old_wdp = old.get("deps", {}).get("vendor/web-discovery-project", {}).get("url")
    new_wdp = urls.get("vendor/web-discovery-project")
    wdp_hash = old.get("wdpNodeModulesHash") if old_wdp == new_wdp else None

    metadata = {
        "version": args.version,
        "tag": f"v{args.version}",
        "chromiumVersion": chromium_version,
        "core": {
            "url": f"https://github.com/brave/brave-core/archive/refs/tags/v{args.version}.tar.gz",
            "hash": args.core_hash,
        },
        "npmHash": npm_hash(args.core / "package-lock.json"),
        "wdpNodeModulesHash": wdp_hash or "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "deps": {
            destination: {"url": url, "hash": hashes[destination]}
            for destination, url in sorted(urls.items())
        },
    }
    temporary = args.output.with_suffix(".json.new")
    temporary.write_text(json.dumps(metadata, indent=2) + "\n")
    temporary.replace(args.output)
    print(chromium_version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
