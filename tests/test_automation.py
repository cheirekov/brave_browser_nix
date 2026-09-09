from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from scripts.update_sources import detect_package_manager


ROOT = pathlib.Path(__file__).resolve().parents[1]
CURRENT_VERSION = json.loads((ROOT / "nix/sources.json").read_text())["version"]


def bumped_version(version: str) -> str:
    major, minor, patch = map(int, version.split("."))
    return f"{major}.{minor}.{patch + 1}"


def older_version(version: str) -> str:
    major, minor, patch = map(int, version.split("."))
    if patch:
        return f"{major}.{minor}.{patch - 1}"
    if minor:
        return f"{major}.{minor - 1}.0"
    return f"{major - 1}.0.0"


class UpdateCheckTests(unittest.TestCase):
    def run_check(self, stable: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            fake_curl = pathlib.Path(temporary) / "curl"
            fake_curl.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$FAKE_STABLE_VERSION\"\n")
            fake_curl.chmod(0o755)
            environment = os.environ.copy()
            environment["FAKE_STABLE_VERSION"] = stable
            environment["PATH"] = f"{temporary}:{environment['PATH']}"
            return subprocess.run(
                [ROOT / "scripts/update.sh", "--check", *arguments],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_equal_stable_release_is_a_noop(self) -> None:
        result = self.run_check(CURRENT_VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("update_available=false", result.stdout)
        self.assertIn("channel=stable", result.stdout)

    def test_newer_stable_release_is_reported(self) -> None:
        newer = bumped_version(CURRENT_VERSION)
        result = self.run_check(newer)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("update_available=true", result.stdout)
        self.assertIn(f"new_version={newer}", result.stdout)

    def test_requested_version_must_equal_official_stable(self) -> None:
        stable = bumped_version(CURRENT_VERSION)
        result = self.run_check(stable, "--version", "99.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("official Linux Stable", result.stderr)

    def test_stable_endpoint_cannot_downgrade_metadata(self) -> None:
        result = self.run_check(older_version(CURRENT_VERSION))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing Brave Stable downgrade", result.stderr)

    def test_invalid_stable_endpoint_response_is_rejected(self) -> None:
        result = self.run_check("beta-channel")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Brave Stable endpoint response", result.stderr)


class PackageManagerDetectionTests(unittest.TestCase):
    def test_npm_lockfile_is_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "package-lock.json").touch()
            self.assertEqual(detect_package_manager(root), "npm")

    def test_pnpm_workspace_is_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "pnpm-lock.yaml").touch()
            (root / "pnpm-workspace.yaml").touch()
            self.assertEqual(detect_package_manager(root), "pnpm")

    def test_ambiguous_or_unknown_lockfiles_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                detect_package_manager(root)
            (root / "package-lock.json").touch()
            (root / "pnpm-lock.yaml").touch()
            (root / "pnpm-workspace.yaml").touch()
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                detect_package_manager(root)


class DeferredUpdateTests(unittest.TestCase):
    def test_chromium_mismatch_returns_75_and_restores_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            work = pathlib.Path(temporary) / "repo"
            fake_bin = pathlib.Path(temporary) / "bin"
            (work / "scripts").mkdir(parents=True)
            (work / "nix").mkdir()
            fake_bin.mkdir()
            shutil.copy2(ROOT / "scripts/update.sh", work / "scripts/update.sh")
            shutil.copy2(
                ROOT / "scripts/update_sources.py", work / "scripts/update_sources.py"
            )
            metadata = {
                "version": "1.0.0",
                "channel": "stable",
                "chromiumVersion": "1.0.0.0",
            }
            metadata_path = work / "nix/sources.json"
            metadata_path.write_text(json.dumps(metadata) + "\n")
            lock_path = work / "flake.lock"
            lock_path.write_text("original lock\n")

            fake_curl = fake_bin / "curl"
            fake_curl.write_text("#!/usr/bin/env bash\nprintf '1.0.1\\n'\n")
            fake_nix = fake_bin / "nix"
            fake_nix.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "if [[ $1 == store ]]; then\n"
                "  printf '{\"storePath\":\"/tmp/core\",\"hash\":\"sha256-core\"}\\n'\n"
                "elif [[ $1 == flake ]]; then\n"
                "  printf 'updated lock\\n' > flake.lock\n"
                "elif [[ $1 == eval ]]; then\n"
                "  printf '1.9.0.0'\n"
                "else\n"
                "  exit 2\n"
                "fi\n"
            )
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "output=\n"
                "while (($#)); do\n"
                "  if [[ $1 == --output ]]; then output=$2; shift; fi\n"
                "  shift\n"
                "done\n"
                "jq '.version=\"1.0.1\" | .chromiumVersion=\"2.0.0.0\"' \"$output\" > \"$output.new\"\n"
                "mv \"$output.new\" \"$output\"\n"
                "printf '2.0.0.0\\n'\n"
            )
            for executable in (fake_curl, fake_nix, fake_python):
                executable.chmod(0o755)

            before_metadata = metadata_path.read_bytes()
            before_lock = lock_path.read_bytes()
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            result = subprocess.run(
                [work / "scripts/update.sh"],
                cwd=work,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertEqual(metadata_path.read_bytes(), before_metadata)
            self.assertEqual(lock_path.read_bytes(), before_lock)


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.update_workflow = (ROOT / ".github/workflows/update-brave.yml").read_text()
        cls.build_workflow = (ROOT / ".github/workflows/full-build.yml").read_text()
        cls.publisher = (ROOT / "scripts/publish_update_pr.sh").read_text()
        cls.updater = (ROOT / "scripts/update.sh").read_text()

    def test_scheduled_updater_has_only_scoped_write_permissions(self) -> None:
        self.assertIn("contents: write", self.update_workflow)
        self.assertIn("pull-requests: write", self.update_workflow)
        self.assertNotIn("actions: write", self.update_workflow)
        self.assertNotIn("checks: write", self.update_workflow)
        self.assertIn("persist-credentials: false", self.update_workflow)

    def test_scheduled_path_never_invokes_full_browser_build(self) -> None:
        combined = self.update_workflow + self.updater + self.publisher
        self.assertNotIn("nix build .#br", combined)
        self.assertNotIn("full-build.yml", self.update_workflow)

    def test_chromium_lag_is_deferred_without_publishing(self) -> None:
        self.assertIn("NIXPKGS_CHROMIUM_DEFERRED=75", self.updater)
        self.assertIn("75)", self.update_workflow)
        self.assertIn("deferred=true", self.update_workflow)
        self.assertIn("steps.update.outputs.ready == 'true'", self.update_workflow)

    def test_updater_keeps_real_failures_red(self) -> None:
        self.assertIn('exit "$status"', self.update_workflow)
        self.assertIn("unsupported core package manager", self.updater)

    def test_automation_branch_update_is_exact_lease_and_owned(self) -> None:
        self.assertIn("existing branch is not owned by github-actions[bot]", self.publisher)
        self.assertIn("--force-with-lease=refs/heads/${branch}:${existing_sha}", self.publisher)
        self.assertNotIn("git switch -C", self.publisher)
        self.assertIn("refusing to create a duplicate", self.publisher)
        self.assertIn("Close only older Stable PRs", self.publisher)
        self.assertNotIn("--delete-branch", self.publisher)

    def test_full_build_is_manual_only_and_confirms_identity(self) -> None:
        self.assertIn("workflow_dispatch:", self.build_workflow)
        self.assertNotIn("schedule:", self.build_workflow)
        self.assertNotIn("pull_request:", self.build_workflow)
        self.assertNotIn("\n  push:", self.build_workflow)
        for required in ("build_ref:", "brave_version:", "expected_commit:"):
            self.assertIn(required, self.build_workflow)
        self.assertIn("EXPECTED_REF == \"$actual_ref\"", self.build_workflow)
        self.assertIn("EXPECTED_COMMIT == \"$actual_sha\"", self.build_workflow)
        self.assertIn("EXPECTED_VERSION == \"$actual_version\"", self.build_workflow)
        self.assertIn("needs: validate-selection", self.build_workflow)
        self.assertRegex(
            self.build_workflow,
            r"nix-build\.yml@[0-9a-f]{40}",
        )


class PublishBranchIntegrationTests(unittest.TestCase):
    OLD = "1.0.0"
    NEW = "1.0.1"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        temporary = pathlib.Path(self.temporary.name)
        self.work = temporary / "work"
        self.remote = temporary / "remote.git"
        self.fake_bin = temporary / "bin"
        (self.work / "scripts").mkdir(parents=True)
        (self.work / "nix").mkdir()
        self.fake_bin.mkdir()

        shutil.copy2(ROOT / "scripts/publish_update_pr.sh", self.work / "scripts")
        metadata = {
            "version": self.OLD,
            "tag": f"v{self.OLD}",
            "channel": "stable",
            "chromiumVersion": "1.0.0.0",
            "core": {
                "url": f"https://github.com/brave/brave-core/archive/refs/tags/v{self.OLD}.tar.gz",
                "hash": "sha256-old",
            },
        }
        (self.work / "nix/sources.json").write_text(json.dumps(metadata) + "\n")
        (self.work / "flake.lock").write_text('{"pin": 0}\n')
        fake_gh = self.fake_bin / "gh"
        fake_gh.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "case \"${1:-} ${2:-}\" in\n"
            "  'auth setup-git') exit 0 ;;\n"
            "  'api --method') if [[ \"$*\" == *'state=open'* && -n ${FAKE_OPEN_PRS:-} ]]; then cat \"$FAKE_OPEN_PRS\"; else printf '[]\\n'; fi ;;\n"
            "  'pr create') printf 'https://example.invalid/pr/1\\n' ;;\n"
            "  'pr edit') exit 0 ;;\n"
            "  'pr view') printf '{\"number\":1,\"url\":\"https://example.invalid/pr/1\"}\\n' ;;\n"
            "  'pr close') printf '%s\\n' \"$*\" >> \"$FAKE_CLOSE_LOG\" ;;\n"
            "  *) printf 'unexpected fake gh arguments: %s\\n' \"$*\" >&2; exit 2 ;;\n"
            "esac\n"
        )
        fake_gh.chmod(0o755)
        self.open_prs = temporary / "open-prs.json"
        self.close_log = temporary / "closed-prs.log"
        self.open_prs.write_text("[]\n")
        self.close_log.touch()

        self.git("init", "-b", "main", str(self.work), cwd=temporary)
        self.git("config", "user.name", "Repository Owner")
        self.git("config", "user.email", "owner@example.invalid")
        self.git("add", ".")
        self.git("commit", "-m", "initial")
        self.base_sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("init", "--bare", str(self.remote), cwd=temporary)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-u", "origin", "main")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(
        self, *arguments: str, cwd: pathlib.Path | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=cwd or self.work,
            text=True,
            capture_output=True,
            check=True,
        )

    def write_update(self) -> None:
        metadata_path = self.work / "nix/sources.json"
        metadata = json.loads(metadata_path.read_text())
        metadata.update(version=self.NEW, tag=f"v{self.NEW}")
        metadata["core"].update(
            url=f"https://github.com/brave/brave-core/archive/refs/tags/v{self.NEW}.tar.gz",
            hash="sha256-new",
        )
        metadata_path.write_text(json.dumps(metadata) + "\n")
        (self.work / "flake.lock").write_text('{"pin": 1}\n')

    def publish(self) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["GITHUB_REPOSITORY"] = "owner/repository"
        environment["FAKE_OPEN_PRS"] = str(self.open_prs)
        environment["FAKE_CLOSE_LOG"] = str(self.close_log)
        environment["PATH"] = f"{self.fake_bin}:{environment['PATH']}"
        return subprocess.run(
            [self.work / "scripts/publish_update_pr.sh", self.OLD, self.NEW],
            cwd=self.work,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_rerun_keeps_identical_owned_remote_tree(self) -> None:
        self.write_update()
        first = self.publish()
        self.assertEqual(first.returncode, 0, first.stderr)
        branch = f"refs/heads/automation/brave-{self.NEW}"
        first_sha = self.git("--git-dir", str(self.remote), "rev-parse", branch).stdout.strip()

        self.git("checkout", "--detach", self.base_sha)
        self.write_update()
        second = self.publish()
        self.assertEqual(second.returncode, 0, second.stderr)
        second_sha = self.git("--git-dir", str(self.remote), "rev-parse", branch).stdout.strip()
        self.assertEqual(first_sha, second_sha)
        self.assertIn("already has the desired tree", second.stdout)

    def test_foreign_branch_is_not_overwritten(self) -> None:
        branch = f"automation/brave-{self.NEW}"
        self.git("switch", "-c", branch)
        (self.work / "foreign.txt").write_text("do not overwrite\n")
        self.git("add", "foreign.txt")
        self.git("commit", "-m", "foreign work")
        self.git("push", "origin", branch)
        foreign_sha = self.git("rev-parse", "HEAD").stdout.strip()

        self.git("checkout", "--detach", self.base_sha)
        self.write_update()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not owned by github-actions[bot]", result.stderr)
        remote_sha = self.git(
            "--git-dir", str(self.remote), "rev-parse", f"refs/heads/{branch}"
        ).stdout.strip()
        self.assertEqual(foreign_sha, remote_sha)

    def test_verified_older_bot_pr_is_closed(self) -> None:
        older = "0.9.9"
        branch = f"automation/brave-{older}"
        self.git("switch", "-c", branch)
        (self.work / "flake.lock").write_text('{"pin": -1}\n')
        self.git("config", "user.name", "github-actions[bot]")
        self.git(
            "config",
            "user.email",
            "41898282+github-actions[bot]@users.noreply.github.com",
        )
        self.git("add", "flake.lock")
        self.git("commit", "-m", f"brave: update upstream to {older}")
        self.git("push", "origin", branch)
        candidate = [{
            "number": 2,
            "title": f"brave: update upstream to {older}",
            "user": {"login": "github-actions[bot]"},
            "head": {
                "ref": branch,
                "repo": {"full_name": "owner/repository"},
            },
        }]
        self.open_prs.write_text(json.dumps(candidate) + "\n")
        self.git("checkout", "--detach", self.base_sha)
        self.write_update()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr close 2", self.close_log.read_text())

    def test_older_bot_pr_with_extra_file_remains_open(self) -> None:
        older = "0.9.8"
        branch = f"automation/brave-{older}"
        self.git("switch", "-c", branch)
        (self.work / "unexpected.txt").write_text("outside metadata\n")
        self.git("config", "user.name", "github-actions[bot]")
        self.git(
            "config",
            "user.email",
            "41898282+github-actions[bot]@users.noreply.github.com",
        )
        self.git("add", "unexpected.txt")
        self.git("commit", "-m", f"brave: update upstream to {older}")
        self.git("push", "origin", branch)
        candidate = [{
            "number": 3,
            "title": f"brave: update upstream to {older}",
            "user": {"login": "github-actions[bot]"},
            "head": {
                "ref": branch,
                "repo": {"full_name": "owner/repository"},
            },
        }]
        self.open_prs.write_text(json.dumps(candidate) + "\n")
        self.git("checkout", "--detach", self.base_sha)
        self.write_update()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.close_log.read_text(), "")
        self.assertIn("outside update metadata", result.stdout)


if __name__ == "__main__":
    unittest.main()
