#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'publish-update-pr: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'publish-update-pr: %s\n' "$*"
}

version_is_older() {
  local candidate=$1 reference=$2 candidate_major candidate_minor candidate_patch
  local reference_major reference_minor reference_patch
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r reference_major reference_minor reference_patch <<<"$reference"
  ((10#$candidate_major < 10#$reference_major)) && return 0
  ((10#$candidate_major > 10#$reference_major)) && return 1
  ((10#$candidate_minor < 10#$reference_minor)) && return 0
  ((10#$candidate_minor > 10#$reference_minor)) && return 1
  ((10#$candidate_patch < 10#$reference_patch))
}

[[ $# == 2 ]] || die "usage: publish_update_pr.sh OLD_VERSION NEW_VERSION"
old_version=$1
new_version=$2
repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
base_branch=main
branch="automation/brave-${new_version}"
remote_ref="refs/remotes/origin/${branch}"
bot_email='41898282+github-actions[bot]@users.noreply.github.com'
subject="brave: update upstream to ${new_version}"

for command in gh git jq; do
  command -v "$command" >/dev/null || die "missing command: $command"
done
gh auth setup-git
[[ $old_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid old version: $old_version"
[[ $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid new version: $new_version"
[[ $old_version != "$new_version" ]] || die "old and new versions are identical"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
metadata=nix/sources.json

[[ $(jq -r .version "$metadata") == "$new_version" ]] \
  || die "metadata version does not match $new_version"
[[ $(jq -r '.channel // empty' "$metadata") == stable ]] \
  || die "metadata channel is not stable"
[[ $(jq -r .tag "$metadata") == "v${new_version}" ]] \
  || die "metadata tag does not match v${new_version}"
[[ $(jq -r .core.url "$metadata") == \
    "https://github.com/brave/brave-core/archive/refs/tags/v${new_version}.tar.gz" ]] \
  || die "brave-core URL does not match the Stable release tag"
[[ $(git show "HEAD:${metadata}" | jq -r .version) == "$old_version" ]] \
  || die "HEAD metadata version does not match updater output $old_version"

mapfile -t changed_files < <(
  { git diff --name-only; git ls-files --others --exclude-standard; } | sort -u
)
((${#changed_files[@]} > 0)) || die "updater produced no files to publish"
for path in "${changed_files[@]}"; do
  case $path in
    flake.lock|nix/sources.json) ;;
    *) die "updater changed unexpected path: $path" ;;
  esac
done
git diff --cached --quiet || die "refusing pre-staged changes"

git fetch --no-tags origin "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}"
base_sha=$(git rev-parse "refs/remotes/origin/${base_branch}")
[[ $(git rev-parse HEAD) == "$base_sha" ]] \
  || die "${base_branch} advanced during the update; rerun from the new head"

existing_sha=
if remote_line=$(git ls-remote --exit-code --heads origin "refs/heads/${branch}"); then
  existing_sha=${remote_line%%[[:space:]]*}
  git fetch --no-tags origin "+refs/heads/${branch}:${remote_ref}"
  [[ $(git rev-parse "$remote_ref") == "$existing_sha" ]] \
    || die "remote branch changed while it was fetched"

  [[ $(git show -s --format=%ae "$remote_ref") == "$bot_email" ]] \
    || die "existing branch is not owned by github-actions[bot]"
  [[ $(git show -s --format=%s "$remote_ref") == "$subject" ]] \
    || die "existing branch has an unexpected commit subject"
  [[ $(git rev-list --count "refs/remotes/origin/${base_branch}..${remote_ref}") == 1 ]] \
    || die "existing branch does not contain exactly one unmerged automation commit"

  merge_base=$(git merge-base "refs/remotes/origin/${base_branch}" "$remote_ref")
  mapfile -t remote_files < <(git diff --name-only "$merge_base" "$remote_ref")
  ((${#remote_files[@]} > 0)) || die "existing automation branch has no metadata changes"
  for path in "${remote_files[@]}"; do
    case $path in
      flake.lock|nix/sources.json) ;;
      *) die "existing automation branch changes unexpected path: $path" ;;
    esac
  done
else
  status=$?
  ((status == 2)) || die "failed to inspect remote branch (git status $status)"
fi

owner=${repository%%/*}
list_prs() {
  gh api --method GET "repos/${repository}/pulls" \
    -f state=all -f base="$base_branch" -f head="${owner}:${branch}" -f per_page=100
}

prs=$(list_prs)
pr_count=$(jq 'length' <<<"$prs")
((pr_count <= 1)) || die "multiple PRs already use ${branch}; refusing to choose one"
if ((pr_count == 1)); then
  pr_state=$(jq -r '.[0].state' <<<"$prs")
  pr_number=$(jq -r '.[0].number' <<<"$prs")
  [[ $pr_state == open ]] \
    || die "PR #${pr_number} for ${branch} is ${pr_state}; refusing to create a duplicate"
else
  pr_number=
fi

git config user.name github-actions[bot]
git config user.email "$bot_email"
git add flake.lock nix/sources.json
git diff --cached --quiet && die "metadata changes disappeared before commit"
git commit -m "$subject"
new_sha=$(git rev-parse HEAD)

if [[ -n $existing_sha ]] && git diff --quiet "$existing_sha" "$new_sha"; then
  published_sha=$existing_sha
  note "remote branch already has the desired tree at ${published_sha}"
else
  if [[ -n $existing_sha ]]; then
    note "updating owned branch ${branch} with exact lease ${existing_sha}"
    git push origin \
      "--force-with-lease=refs/heads/${branch}:${existing_sha}" \
      "HEAD:refs/heads/${branch}"
  else
    note "creating automation branch ${branch} without force"
    git push origin "HEAD:refs/heads/${branch}"
  fi
  published_sha=$new_sha
fi

chromium=$(jq -r .chromiumVersion "$metadata")
core_hash=$(jq -r .core.hash "$metadata")
body=$(mktemp)
trap 'rm -f "$body"' EXIT
printf '%s\n' \
  "Automated Brave Stable update." \
  "" \
  "- Channel: Stable (official Linux x64 endpoint)" \
  "- Previous Brave version: ${old_version}" \
  "- New Brave version: ${new_version}" \
  "- Upstream tag/revision: v${new_version}" \
  "- Chromium revision: ${chromium}" \
  "- brave-core source hash: ${core_hash}" \
  "- Automation commit: ${published_sha}" \
  "- Verification: nix flake check, source verification, and automation tests passed" \
  "- Full browser build performed: no (manual workflow_dispatch gate)" \
  > "$body"

if [[ -n $pr_number ]]; then
  gh pr edit "$pr_number" --repo "$repository" --title "$subject" --body-file "$body"
  action=updated
else
  if gh pr create --repo "$repository" --base "$base_branch" --head "$branch" \
      --title "$subject" --body-file "$body"; then
    action=created
  else
    note "PR creation raced or failed; checking once for an open matching PR"
    prs=$(list_prs)
    [[ $(jq 'length' <<<"$prs") == 1 && $(jq -r '.[0].state' <<<"$prs") == open ]] \
      || die "PR creation failed and no unique open matching PR exists"
    pr_number=$(jq -r '.[0].number' <<<"$prs")
    gh pr edit "$pr_number" --repo "$repository" --title "$subject" --body-file "$body"
    action=updated-after-race
  fi
fi

pr_json=$(gh pr view "$branch" --repo "$repository" --json number,url)
pr_number=$(jq -r .number <<<"$pr_json")
pr_url=$(jq -r .url <<<"$pr_json")
note "PR ${action}: ${pr_url}"

# Close only older Stable PRs whose GitHub identity, commit identity, subject,
# ancestry and changed paths all prove that they were produced by this script.
open_prs=$(gh api --method GET "repos/${repository}/pulls" \
  -f state=open -f base="$base_branch" -f per_page=100)
while IFS=$'\t' read -r candidate_number candidate_title candidate_user candidate_branch candidate_repo; do
  [[ -n $candidate_number && $candidate_number != "$pr_number" ]] || continue
  if [[ $candidate_branch =~ ^automation/brave-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    candidate_version=${BASH_REMATCH[1]}
  else
    continue
  fi
  version_is_older "$candidate_version" "$new_version" || continue
  expected_candidate_subject="brave: update upstream to ${candidate_version}"
  if [[ $candidate_user != 'github-actions[bot]' \
      || $candidate_repo != "$repository" \
      || $candidate_title != "$expected_candidate_subject" ]]; then
    note "leaving PR #${candidate_number} open: ownership or title is not provably automated"
    continue
  fi

  candidate_ref="refs/remotes/origin/${candidate_branch}"
  if ! candidate_line=$(git ls-remote --exit-code --heads origin "refs/heads/${candidate_branch}"); then
    note "leaving PR #${candidate_number} open: branch cannot be verified"
    continue
  fi
  candidate_sha=${candidate_line%%[[:space:]]*}
  if ! git fetch --no-tags origin \
      "+refs/heads/${candidate_branch}:${candidate_ref}" >/dev/null 2>&1 \
      || [[ $(git rev-parse "$candidate_ref") != "$candidate_sha" ]] \
      || [[ $(git show -s --format=%ae "$candidate_ref") != "$bot_email" ]] \
      || [[ $(git show -s --format=%s "$candidate_ref") != "$expected_candidate_subject" ]] \
      || [[ $(git rev-list --count "refs/remotes/origin/${base_branch}..${candidate_ref}") != 1 ]]; then
    note "leaving PR #${candidate_number} open: branch history is not provably automated"
    continue
  fi

  candidate_base=$(git merge-base "refs/remotes/origin/${base_branch}" "$candidate_ref")
  mapfile -t candidate_files < <(git diff --name-only "$candidate_base" "$candidate_ref")
  candidate_paths_safe=true
  ((${#candidate_files[@]} > 0)) || candidate_paths_safe=false
  for path in "${candidate_files[@]}"; do
    case $path in
      flake.lock|nix/sources.json) ;;
      *) candidate_paths_safe=false ;;
    esac
  done
  if [[ $candidate_paths_safe != true ]]; then
    note "leaving PR #${candidate_number} open: branch changes files outside update metadata"
    continue
  fi

  gh pr close "$candidate_number" --repo "$repository" \
    --comment "Superseded by ${pr_url}, which carries Brave ${new_version}. The branch is retained."
  note "closed superseded automation PR #${candidate_number}; branch retained"
done < <(
  jq -r '.[] | [.number, .title, .user.login, .head.ref, (.head.repo.full_name // "")] | @tsv' \
    <<<"$open_prs"
)

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  printf '%s\n' \
    "## Brave Stable update PR" \
    "" \
    "- Action: ${action}" \
    "- Ref: \`${branch}\`" \
    "- Commit: \`${published_sha}\`" \
    "- Brave: \`${new_version}\`" \
    "- PR: ${pr_url}" \
    >> "$GITHUB_STEP_SUMMARY"
fi
