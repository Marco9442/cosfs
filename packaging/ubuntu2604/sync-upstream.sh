#!/usr/bin/env bash
# 合并上游默认分支。上游提交还没有对应 Release 时，让后续步骤发版。
set -euo pipefail

cd "$(dirname "$0")/../.."

git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream https://github.com/tencentyun/cosfs.git
fi

default_branch="$(git ls-remote --symref https://github.com/tencentyun/cosfs.git HEAD \
  | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')"
if [[ -z "${default_branch}" ]]; then
  echo "无法读取上游默认分支" >&2
  exit 1
fi

git fetch --tags origin
git fetch upstream "${default_branch}"
git checkout master
git merge --ff-only origin/master

up_sha="$(git rev-parse "upstream/${default_branch}")"
if ! git merge-base --is-ancestor "${up_sha}" HEAD; then
  if ! git merge --no-edit "upstream/${default_branch}"; then
    echo "上游合并冲突" >&2
    exit 1
  fi
fi

last_ct="$(git log -1 --format=%ct)"
now="$(date +%s)"
if (( now - last_ct > 30 * 24 * 3600 )); then
  date -u +%Y-%m-%dT%H:%M:%SZ > packaging/ubuntu2604/LAST_CHECK
  git add packaging/ubuntu2604/LAST_CHECK
  git commit -m "记录上游检查"
fi

if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]]; then
  git push origin HEAD:master
fi

export UP_SHA="${up_sha}"
export HEAD_SHA="$(git rev-parse HEAD)"
export FORCE="${FORCE:-false}"
export REPO="${GITHUB_REPOSITORY:-Marco9442/cosfs}"

python3 - << 'PY'
import json
import os
import pathlib
import re
import subprocess

up = os.environ["UP_SHA"]
force = os.environ.get("FORCE", "false") == "true"
repo = os.environ["REPO"]
raw = subprocess.check_output(
    ["gh", "api", "--paginate", f"repos/{repo}/releases"],
    text=True,
)
releases = json.loads(raw or "[]")
if not isinstance(releases, list):
    raise SystemExit("无法读取 Release 列表")
already = [item.get("tag_name") for item in releases if up in (item.get("body") or "")]
text = pathlib.Path("configure.ac").read_text(encoding="utf-8")
match = re.search(r"AC_INIT\(\s*\[?cosfs\]?\s*,\s*\[?([^],)]+)", text)
if not match:
    raise SystemExit("configure.ac 里没有版本号")
version = match.group(1).strip()
prefix = f"v{version}-ubuntu26."
numbers = []
for item in releases:
    name = item.get("tag_name") or ""
    suffix = name[len(prefix):] if name.startswith(prefix) else ""
    if suffix.isdigit():
        numbers.append(int(suffix))
for name in subprocess.check_output(["git", "tag", "-l", f"{prefix}*"], text=True).split():
    suffix = name[len(prefix):]
    if suffix.isdigit():
        numbers.append(int(suffix))
revision = (max(numbers) + 1) if numbers else 1
do_release = force or not already
lines = [
    f"release={'true' if do_release else 'false'}",
    f"tag={prefix}{revision}",
    f"version={version}-ubuntu26.{revision}",
    f"upstream={up}",
    f"sha={os.environ['HEAD_SHA']}",
]
print("\n".join(lines))
output = os.environ.get("GITHUB_OUTPUT")
if output:
    with open(output, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
PY
