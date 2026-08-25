from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


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

    def test_automation_branch_update_is_exact_lease_and_owned(self) -> None:
        self.assertIn("existing branch is not owned by github-actions[bot]", self.publisher)
        self.assertIn("--force-with-lease=refs/heads/${branch}:${existing_sha}", self.publisher)
        self.assertNotIn("git switch -C", self.publisher)
        self.assertIn("refusing to create a duplicate", self.publisher)

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
            "  'api --method') printf '[]\\n' ;;\n"
            "  'pr create') printf 'https://example.invalid/pr/1\\n' ;;\n"
            "  'pr edit') exit 0 ;;\n"
            "  'pr view') printf 'https://example.invalid/pr/1\\n' ;;\n"
            "  *) printf 'unexpected fake gh arguments: %s\\n' \"$*\" >&2; exit 2 ;;\n"
            "esac\n"
        )
        fake_gh.chmod(0o755)

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


if __name__ == "__main__":
    unittest.main()
