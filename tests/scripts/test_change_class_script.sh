#!/usr/bin/env bash
# change-class reads the real change-risk policy, so these tests classify
# known paths against it and keep a fixture repo for the diff modes.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cc="$here/home/dot_local/bin/executable_change-class"
rules="$here/home/dot_config/agents/change-risk.toml"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$cc" ] || fail "change-class missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$cc" || fail "change-class does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

out="$tmp/out"
err="$tmp/err"

run_in() {
    local dir="$1" want="$2" got=0
    shift 2
    ( cd "$dir" && "$cc" "$@" ) >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "change-class $* exited $got, want $want" "$(cat "$out" "$err")"
}

run() { run_in "$PWD" "$@"; }

files_tier() {
    local path="$1" got=0
    printf '%s\n' "$path" | "$cc" --rules "$rules" --files - >"$out" 2>"$err" || got=$?
    [ "$got" = 0 ] || fail "classifying $path exited $got" "$(cat "$out" "$err")"
    sed -n 's/^tier: //p' "$out"
}

expect_files_tier() {
    local path="$1" want="$2" got
    got="$(files_tier "$path")"
    [ "$got" = "$want" ] || fail "$path classified $got, want $want" "$(cat "$out")"
}

plan_tier() {
    local dir="$1" text="$2" got=0
    ( cd "$dir" && printf '%s\n' "$text" | "$cc" --rules "$rules" --plan - ) >"$out" 2>"$err" || got=$?
    [ "$got" = 0 ] || fail "classifying plan exited $got" "$(cat "$out" "$err")"
    sed -n 's/^tier: //p' "$out"
}

repo_files() {
    local repo="$1" path="$2" got=0
    shift 2
    ( cd "$tmp" && printf '%s\n' "$path" | "$cc" --rules "$rules" --files - --repo "$repo" "$@" ) \
        >"$out" 2>"$err" || got=$?
    [ "$got" = 0 ] || fail "classifying $path as $repo exited $got" "$(cat "$out" "$err")"
}

new_repo() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
}

commit_all() {
    git -C "$1" add -A && git -C "$1" commit -qm "$2"
}

# ── The real policy classifies the paths the design names ──
expect_files_tier README.md R0
expect_files_tier tests/scripts/test_x.sh R0
expect_files_tier src/app.ts R1
expect_files_tier .github/workflows/ci.yml R2
expect_files_tier charts/app/values-prd.yaml R3
expect_files_tier scripts/provision-foo.sh R3
expect_files_tier home/dot_config/agents/AGENTS.md R3

[ "$(plan_tier "$tmp" 'wipe the world and restart the server while players are online')" = R3 ] \
    || fail "an irreversible plan is not R3" "$(cat "$out")"
[ "$(plan_tier "$tmp" 'add a unit test for the parser')" = R0 ] \
    || fail "a benign plan is not R0" "$(cat "$out")"

# ── Output fields and labels are the contract ──
cat >"$tmp/expected" <<'EOF'
tier: R2
tags[1]: ci
merge: agent-review
reviewer: review@sonnet+
human: false
interview: false
labels[2]: risk/R2,tag/ci
reasons[1]{rule,tier,where}:
  ci-workflows,R2,.github/workflows/ci.yml
files: 1
lines: 0
content_scanned: false
EOF
printf '.github/workflows/ci.yml\n' | "$cc" --rules "$rules" --files - >"$out" 2>"$err" \
    || fail "ci.yml classification failed" "$(cat "$err")"
diff -u "$tmp/expected" "$out" || fail "ci.yml output fields changed" "$(cat "$out")"

# ── Highest matching rule wins; --explain keeps the losers ──
printf 'charts/app/values-prd.yaml\n' | "$cc" --rules "$rules" --files - >"$out"
grep -qx 'tier: R3' "$out" || fail "prd values did not win over deploy config" "$(cat "$out")"
grep -qx 'tags\[2\]: deploy,prd' "$out" || fail "prd tags are wrong" "$(cat "$out")"
grep -qx '  prd-config,R3,charts/app/values-prd.yaml' "$out" || fail "prd reason missing" "$(cat "$out")"
if grep -q 'deploy-config' "$out"; then fail "the losing rule is in the default reasons" "$(cat "$out")"; fi
printf 'charts/app/values-prd.yaml\n' | "$cc" --rules "$rules" --files - --explain >"$out"
grep -qx '  deploy-config,R2,charts/app/values-prd.yaml' "$out" \
    || fail "--explain dropped a matched rule" "$(cat "$out")"

# The design's example: docs stays a tag, but only deciding tiers label the PR.
printf 'README.md\n.github/workflows/ci.yml\n' \
    | "$cc" --rules "$rules" --files - --repo deployments >"$out"
grep -qx 'tags\[3\]: ci,deploy,docs' "$out" || fail "the example tags differ" "$(cat "$out")"
grep -qx 'labels\[3\]: risk/R2,tag/ci,tag/deploy' "$out" \
    || fail "an R0 docs tag leaked into the labels" "$(cat "$out")"
grep -qx '  ci-workflows,R2,.github/workflows/ci.yml' "$out" || fail "the example CI reason differs" "$(cat "$out")"
grep -qx '  deploy floor,R2,repo deployments' "$out" || fail "the example floor reason differs" "$(cat "$out")"

# ── Glob semantics: ** crosses directories, * does not, exclude wins ──
glob_rules="$tmp/glob-risk.toml"
cat >"$glob_rules" <<'TOML'
[tiers.R0]
merge = "auto"
reviewer = "none"
human = false
interview = false

[tiers.R1]
merge = "agent-review"
reviewer = "review@other-family"
human = false
interview = false

[tiers.R2]
merge = "agent-review"
reviewer = "review@sonnet+"
human = false
interview = false

[tiers.R3]
merge = "human"
reviewer = "review@opus"
human = true
interview = true

[size]
files = 100
lines = 10000
cap = "R2"

[default]
tier = "R1"
tag = "code"

[[rule]]
id = "root-text"
tag = "docs"
tier = "R0"
paths = ["foo/*.txt"]

[[rule]]
id = "deep"
tag = "docs"
tier = "R0"
paths = ["deep/**/file.txt"]

[[rule]]
id = "all-md"
tag = "docs"
tier = "R0"
paths = ["**/*.md"]
exclude = ["**/AGENTS.md"]
TOML
custom_tier() {
    local path="$1" got=0
    printf '%s\n' "$path" | "$cc" --rules "$glob_rules" --files - >"$out" 2>"$err" || got=$?
    [ "$got" = 0 ] || fail "custom rule classification exited $got" "$(cat "$out" "$err")"
    sed -n 's/^tier: //p' "$out"
}
[ "$(custom_tier foo/a.txt)" = R0 ] || fail "* did not match within one directory"
[ "$(custom_tier foo/bar/b.txt)" = R1 ] || fail "* crossed a directory boundary"
[ "$(custom_tier deep/file.txt)" = R0 ] || fail "** did not match zero directories"
[ "$(custom_tier deep/a/b/file.txt)" = R0 ] || fail "** did not cross directories"
[ "$(custom_tier sub/notes.md)" = R0 ] || fail "**/*.md missed a nested markdown file"
[ "$(custom_tier sub/AGENTS.md)" = R1 ] || fail "an exclude glob did not switch the rule off"

# ── Unknown paths are R1, an empty change is R0 ──
expect_files_tier src/unknown.rs R1
printf 'src/unknown.rs\n' | "$cc" --rules "$rules" --files - >"$out"
grep -qx 'tags\[1\]: code' "$out" || fail "an unknown path lost the code tag" "$(cat "$out")"
grep -qx '  default,R1,src/unknown.rs' "$out" || fail "an unknown path lost its default reason" "$(cat "$out")"

printf '' | "$cc" --rules "$rules" --files - >"$out"
grep -qx 'tier: R0' "$out" || fail "an empty change is not R0" "$(cat "$out")"
grep -qx 'files: 0' "$out" || fail "an empty change reports files" "$(cat "$out")"
grep -qx 'reasons\[0\]{rule,tier,where}:' "$out" || fail "an empty change reports reasons" "$(cat "$out")"

# ── Size lifts R0/R1 to the cap, and only at the threshold ──
for i in $(seq 1 24); do printf 'docs/file%s.md\n' "$i"; done >"$tmp/twenty-four.txt"
run 0 --rules "$rules" --files "$tmp/twenty-four.txt"
grep -qx 'tier: R0' "$out" || fail "24 docs files were treated as large" "$(cat "$out")"
for i in $(seq 1 25); do printf 'docs/file%s.md\n' "$i"; done >"$tmp/twenty-five.txt"
run 0 --rules "$rules" --files "$tmp/twenty-five.txt"
grep -qx 'tier: R2' "$out" || fail "25 files did not lift R0 to the size cap" "$(cat "$out")"
grep -q '^  size,R2,' "$out" || fail "the size lift has no reason" "$(cat "$out")"

# ── Default policy path, and unreadable policy fails closed ──
mkdir -p "$tmp/home/.config/agents"
cp "$rules" "$tmp/home/.config/agents/change-risk.toml"
got=0
( cd "$tmp" && printf 'src/app.ts\n' | env -u XDG_CONFIG_HOME HOME="$tmp/home" "$cc" --files - ) \
    >"$out" 2>"$err" || got=$?
[ "$got" = 0 ] || fail "the default rules path exited $got" "$(cat "$out" "$err")"
grep -qx 'tier: R1' "$out" || fail "the default rules path was not used" "$(cat "$out")"

mkdir -p "$tmp/empty-home"
got=0
( cd "$tmp" && env -u XDG_CONFIG_HOME HOME="$tmp/empty-home" "$cc" --plan /dev/null ) \
    >"$out" 2>"$err" || got=$?
[ "$got" = 1 ] || fail "a missing default policy exited $got, want 1" "$(cat "$out" "$err")"
grep -qx 'code: 1' "$out" || fail "a missing policy has no structured error" "$(cat "$out")"

run 1 --rules "$tmp/no-such.toml" --plan /dev/null
grep -qx 'code: 1' "$out" || fail "a missing --rules file did not fail closed" "$(cat "$out")"
printf 'not toml [[[\n' >"$tmp/bad.toml"
run 1 --rules "$tmp/bad.toml" --plan /dev/null
grep -qx 'code: 1' "$out" || fail "invalid TOML did not fail closed" "$(cat "$out")"

cat >"$tmp/missing-tier.toml" <<'TOML'
[tiers.R0]
merge = "auto"
reviewer = "none"
human = false
interview = false

[size]
files = 25
lines = 800
cap = "R2"

[default]
tier = "R1"
tag = "code"
TOML
run 1 --rules "$tmp/missing-tier.toml" --plan /dev/null
grep -qx 'code: 1' "$out" || fail "a missing tier did not fail closed" "$(cat "$out")"

cat >"$tmp/bad-tier.toml" <<'TOML'
[tiers.R0]
merge = "auto"
reviewer = "none"
human = false
interview = false

[tiers.R1]
merge = "agent-review"
reviewer = "review@other-family"
human = false
interview = false

[tiers.R2]
merge = "agent-review"
reviewer = "review@sonnet+"
human = false
interview = false

[tiers.R3]
merge = "human"
reviewer = "review@opus"
human = true
interview = true

[size]
files = 25
lines = 800
cap = "R2"

[default]
tier = "R1"
tag = "code"

[[rule]]
id = "bad"
tag = "x"
tier = "R9"
paths = ["**"]
TOML
run 1 --rules "$tmp/bad-tier.toml" --plan /dev/null
grep -qx 'code: 1' "$out" || fail "an invalid rule tier did not fail closed" "$(cat "$out")"

cat >"$tmp/bad-regex.toml" <<'TOML'
[tiers.R0]
merge = "auto"
reviewer = "none"
human = false
interview = false

[tiers.R1]
merge = "agent-review"
reviewer = "review@other-family"
human = false
interview = false

[tiers.R2]
merge = "agent-review"
reviewer = "review@sonnet+"
human = false
interview = false

[tiers.R3]
merge = "human"
reviewer = "review@opus"
human = true
interview = true

[size]
files = 25
lines = 800
cap = "R2"

[default]
tier = "R1"
tag = "code"

[[rule]]
id = "bad"
tag = "x"
tier = "R3"
content = ["("]
TOML
run 1 --rules "$tmp/bad-regex.toml" --plan /dev/null
grep -qx 'code: 1' "$out" || fail "an invalid expression did not fail closed" "$(cat "$out")"

# ── Floors: --repo and the git remote, docs exempt ──
repo_files deployments src/app.ts
grep -qx 'tier: R2' "$out" || fail "the deployments floor did not raise code" "$(cat "$out")"
grep -qx '  deploy floor,R2,repo deployments' "$out" || fail "the floor reason is wrong" "$(cat "$out")"
repo_files deployments README.md
grep -qx 'tier: R0' "$out" || fail "a docs-only change waited on the deployments floor" "$(cat "$out")"
repo_files infrastructure src/app.ts
grep -qx 'tier: R2' "$out" || fail "the infrastructure floor did not raise code" "$(cat "$out")"
grep -qx '  infra floor,R2,repo infrastructure' "$out" \
    || fail "the infrastructure floor reason is wrong" "$(cat "$out")"

remote_repo="$tmp/remote-repo"
new_repo "$remote_repo"
git -C "$remote_repo" remote add origin git@github.com:acme/deployments.git
printf 'a\n' >"$remote_repo/app.ts"
commit_all "$remote_repo" one
printf 'b\n' >>"$remote_repo/app.ts"
commit_all "$remote_repo" two
run_in "$remote_repo" 0 --rules "$rules"
grep -qx 'tier: R2' "$out" || fail "the origin remote did not supply the floor repo" "$(cat "$out")"
grep -qx '  deploy floor,R2,repo deployments' "$out" || fail "the remote floor reason is wrong" "$(cat "$out")"

bare_remote="$tmp/bare-remote"
new_repo "$bare_remote"
git -C "$bare_remote" remote add origin "$tmp/deployments.git"
printf 'a\n' >"$bare_remote/app.ts"
commit_all "$bare_remote" one
printf 'b\n' >>"$bare_remote/app.ts"
commit_all "$bare_remote" two
run_in "$bare_remote" 0 --rules "$rules"
grep -qx 'tier: R2' "$out" || fail "a bare remote repo did not supply the floor" "$(cat "$out")"
grep -qx '  deploy floor,R2,repo deployments' "$out" || fail "the bare repo floor reason is wrong" "$(cat "$out")"

# ── Diff mode: merge-base with origin/main, then the HEAD~1 fallback ──
repo="$tmp/repo"
new_repo "$repo"
printf '# doc\n' >"$repo/README.md"
commit_all "$repo" base
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -qb feature
mkdir -p "$repo/src"
printf 'export const x = 1\n' >"$repo/src/app.ts"
commit_all "$repo" change
run_in "$repo" 0 --rules "$rules"
grep -qx 'tier: R1' "$out" || fail "merge-base diff lost the new file" "$(cat "$out")"
grep -qx 'files: 1' "$out" || fail "merge-base diff file count is wrong" "$(cat "$out")"
grep -qx 'lines: 1' "$out" || fail "merge-base diff line count is wrong" "$(cat "$out")"
if grep -qx 'content_scanned: false' "$out"; then fail "a normal diff claimed a skipped content scan"; fi

got=0
wipe='wipe the world and restart the server while players are online'
( cd "$repo" && printf '%s\n' "$wipe" | "$cc" --rules "$rules" --plan - --diff ) \
    >"$out" 2>"$err" || got=$?
[ "$got" = 0 ] || fail "diff plus plan exited $got" "$(cat "$out" "$err")"
grep -qx 'tier: R3' "$out" || fail "a diff plus an R3 plan did not combine to R3" "$(cat "$out")"
( cd "$repo" && printf 'add a unit test for the parser\n' | "$cc" --rules "$rules" --plan - --diff ) >"$out"
grep -qx 'tier: R1' "$out" || fail "a benign plan lowered the diff tier" "$(cat "$out")"

fallback="$tmp/fallback"
new_repo "$fallback"
printf 'a\n' >"$fallback/app.ts"
commit_all "$fallback" one
git -C "$fallback" commit -q --allow-empty -m two
printf 'b\n' >>"$fallback/app.ts"
run_in "$fallback" 0 --rules "$rules"
grep -qx 'tier: R1' "$out" || fail "the HEAD~1 fallback classified the wrong change" "$(cat "$out")"
grep -qx 'lines: 1' "$out" || fail "the HEAD~1 fallback counted the wrong lines" "$(cat "$out")"
run_in "$fallback" 0 --rules "$rules" --base HEAD
grep -qx 'lines: 1' "$out" || fail "--base HEAD did not diff the working tree" "$(cat "$out")"

single="$tmp/single"
new_repo "$single"
printf 'a\n' >"$single/app.ts"
commit_all "$single" one
printf 'b\n' >>"$single/app.ts"
run_in "$single" 0 --rules "$rules"
grep -qx 'tier: R1' "$out" || fail "a first commit's working change was not classified" "$(cat "$out")"
grep -qx 'lines: 1' "$out" || fail "a first commit's working change lost its line count" "$(cat "$out")"

clean="$tmp/clean"
new_repo "$clean"
printf 'x\n' >"$clean/app.ts"
commit_all "$clean" one
git -C "$clean" update-ref refs/remotes/origin/main HEAD
run_in "$clean" 0 --rules "$rules"
grep -qx 'tier: R0' "$out" || fail "a clean repo is not an empty change" "$(cat "$out")"
grep -qx 'files: 0' "$out" || fail "a clean repo reports files" "$(cat "$out")"

mkdir -p "$tmp/not-a-repo"
run_in "$tmp/not-a-repo" 1 --rules "$rules"
grep -qx 'code: 1' "$out" || fail "a non-repository without inputs did not fail" "$(cat "$out")"

# ── Content rules: changed lines only, never an R0 path ──
content="$tmp/content"
new_repo "$content"
printf '# doc\n' >"$content/README.md"
printf 'echo ok\n' >"$content/run.sh"
commit_all "$content" base
printf 'kubectl delete pod x\n' >>"$content/run.sh"
printf 'kubectl delete pod x\n' >>"$content/README.md"
run_in "$content" 0 --rules "$rules" --base HEAD
grep -qx 'tier: R3' "$out" || fail "an added destructive line is not R3" "$(cat "$out")"
grep -qx '  destructive-command,R3,run.sh' "$out" || fail "the destructive reason is missing" "$(cat "$out")"
if grep -q 'destructive-command,R3,README.md' "$out"; then fail "content rules scanned an R0 docs path"; fi

removed="$tmp/removed"
new_repo "$removed"
printf 'terraform destroy -auto-approve\n' >"$removed/run.sh"
commit_all "$removed" base
printf 'echo ok\n' >"$removed/run.sh"
run_in "$removed" 0 --rules "$rules" --base HEAD
grep -qx 'tier: R3' "$out" || fail "a removed destructive line was not scanned" "$(cat "$out")"

# ── Size lifts on changed lines, and caps content scans ──
large="$tmp/large"
new_repo "$large"
printf 'a\n' >"$large/app.ts"
commit_all "$large" one
git -C "$large" commit -q --allow-empty -m two
python3 -c 'import sys; open(sys.argv[1], "a").write("line\n" * 800)' "$large/app.ts"
run_in "$large" 0 --rules "$rules"
grep -qx 'tier: R2' "$out" || fail "800 changed lines did not lift R1 to the cap" "$(cat "$out")"
grep -qx 'lines: 800' "$out" || fail "the changed-line count is wrong" "$(cat "$out")"

huge="$tmp/huge"
new_repo "$huge"
printf 'a\n' >"$huge/app.ts"
commit_all "$huge" one
git -C "$huge" commit -q --allow-empty -m two
python3 -c 'import sys; open(sys.argv[1], "w").write("kubectl delete " + "x" * 2200000 + "\n")' "$huge/app.ts"
run_in "$huge" 0 --rules "$rules"
grep -qx 'content_scanned: false' "$out" || fail "a diff over the content cap was still scanned" "$(cat "$out")"
if grep -q 'destructive' "$out"; then fail "a skipped content scan still matched a rule"; fi
grep -qx 'tier: R1' "$out" || fail "a skipped content scan changed the path tier" "$(cat "$out")"

# ── --pr uses gh, passing the repo through ──
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$GH_ARGS_FILE"
cat "$GH_DIFF_FILE"
SH
chmod 755 "$tmp/bin/gh"
cat >"$tmp/pr.diff" <<'DIFF'
diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -1 +1,2 @@
 on: push
+  pull_request:
DIFF
export GH_ARGS_FILE="$tmp/gh-args" GH_DIFF_FILE="$tmp/pr.diff"
got=0
( cd "$tmp" && PATH="$tmp/bin:$PATH" "$cc" --rules "$rules" --pr 42 --repo acme/app ) \
    >"$out" 2>"$err" || got=$?
[ "$got" = 0 ] || fail "--pr exited $got" "$(cat "$out" "$err")"
grep -qx 'tier: R2' "$out" || fail "--pr did not classify the workflow" "$(cat "$out")"
grep -qx 'files: 1' "$out" || fail "--pr file count is wrong" "$(cat "$out")"
grep -qx 'lines: 1' "$out" || fail "--pr line count is wrong" "$(cat "$out")"
[ "$(cat "$GH_ARGS_FILE")" = "$(printf 'pr\ndiff\n42\n--repo\nacme/app')" ] \
    || fail "gh did not receive the PR and repo" "$(cat "$GH_ARGS_FILE")"

# ── --fail-at and usage errors ──
printf 'scripts/provision-x.sh\n' | "$cc" --rules "$rules" --files - --fail-at R3 >"$out" || got=$?
[ "$got" = 3 ] || fail "--fail-at R3 on R3 exited $got, want 3" "$(cat "$out")"
got=0
printf '.github/workflows/ci.yml\n' | "$cc" --rules "$rules" --files - --fail-at R3 >"$out" || got=$?
[ "$got" = 0 ] || fail "--fail-at R3 on R2 exited $got, want 0" "$(cat "$out")"
run 2 --files "$tmp/twenty-five.txt" --pr 1
run 2 --files "$tmp/twenty-five.txt" --base HEAD
run 2 --fail-at R9
run 2 --bogus

run 0 --version
grep -qx '1.0.0' "$out" || fail "--version did not print the version" "$(cat "$out")"


# --plan alone must ignore the working diff (the repo above has an R1 diff).
( cd "$repo" && printf 'add a unit test for the parser\n' | "$cc" --rules "$rules" --plan - ) >"$out"
grep -qx 'tier: R0' "$out" || fail "a plan alone was lifted by the working diff" "$(cat "$out")"
( cd "$repo" && printf 'refactor the map renderer\n' | "$cc" --rules "$rules" --plan - ) >"$out"
grep -qx 'tier: R1' "$out" || fail "an unrecognised plan is not the default R1" "$(cat "$out")"
( cd "$repo" && printf 'refactor the renderer and add tests\n' | "$cc" --rules "$rules" --plan - ) >"$out"
grep -qx 'tier: R1' "$out" || fail "a mixed plan was lowered to R0" "$(cat "$out")"

echo "test_change_class_script: OK"
