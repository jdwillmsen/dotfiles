# Agent tooling traps

Tool behaviours that have misled agents (and humans) on this box, in any repo.
Each one produced output that looked fine and was not. Repo-specific traps stay
in that repo's docs; add a row here when a tool's output sends you the wrong way
regardless of repo. Pointed to from `~/.claude/RTK.md` and `~/.codex/AGENTS.md`.

## RTK

RTK's filtered output is **not** the tool's output — it summarises, truncates,
and prints its own status lines. Every row here is that one root cause. Run
anything you intend to act on through `rtk proxy <cmd>` and read the raw result.

| Symptom | Cause | Fix |
|---|---|---|
| `rtk go build -o <path>` prints `Go build: Success`, exits 1, and writes no binary | RTK's success line doesn't reflect the Go toolchain result. Reproduced from a worktree: `Go build: Success` printed, exit code **1**, no binary — the VCS-stamping failure (`error obtaining VCS status: exit status 128`) was swallowed. Compile errors _are_ printed, so a clean-looking run is not the same as a silent one. The VCS failure did not reproduce on the devbox (go 1.26.5, git 2.43, 2026-09-30); the success-line behaviour is the trap | Trust the exit code, never the success line. `rtk proxy go build ...` for the real output; add `-buildvcs=false` when a worktree build fails VCS stamping |
| `helm template <release> <chart> > out.yaml` writes a short file ending in a literal `... (N lines truncated)` marker — even redirected to a file | RTK caps the captured output regardless of the redirect target — one chart rendered 41 lines with the marker where the real render is 534 lines. Anything downstream (kubeconform, a diff, a review) then validates a fragment while looking successful | `rtk proxy helm template ...` for the untruncated render |
| `gh pr view <n>` reports `OPEN` for a PR that has already been merged | RTK caches the `gh` response, and the cached body is well-formed — unlike a truncation marker or a bogus success line, a stale answer gives you nothing to notice. Observed on three PRs at once: `gh pr view` said `OPEN` while all three were already merged. The same staleness reaches the check summary, so a red gate can read green | `rtk proxy gh pr view <n>` (or `rtk proxy gh pr list`) returns live state. Via the API read `.merged`, not `.state` — REST only reports `open`/`closed`, so a merged PR reads `closed`: `gh api repos/<owner>/<repo>/pulls/<n> --jq .merged` |

## GitHub (`gh`, API, rebase-only repos)

| Symptom | Cause | Fix |
|---|---|---|
| `gh pr edit` fails on every PR in the jdwlabs org | `gh` resolves the org through a GraphQL **query** that requires the `read:org` scope, and an exported `GITHUB_TOKEN` (`ghp_...`) lacks it — it fails before any mutation is attempted (`the 'login' field requires ... ['read:org']`). The devbox exports no `GITHUB_TOKEN`; this bites wherever one is set | `unset GITHUB_TOKEN` so `gh` falls back to the keyring `gho_` OAuth token, which already carries `read:org`. Fallback if that token is unavailable: `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> --input payload.json` |
| `gh run watch <n>` errors or watches nothing | It takes the run's **databaseId** (`<run-id>`), not the run number shown in the UI or in a `gh run list` number column | Resolve it first — `gh run list --json databaseId,number,headBranch` — and pass the `databaseId` |
| `gh api repos/<o>/<r>/commits/<sha>/status --jq '.state'` reports `pending` on a commit whose every check is green | That is the legacy **combined-status** API. The jdwlabs repos post only check runs, so `.statuses` is empty and `.state` falls back to `pending` permanently. Sampled on jdwlabs/platform PR #305 head `9d87c32c`: `/status` answered `{"state":"pending","statuses":0,"total_count":0}` while `/check-runs` returned 19 runs, every one `success`; re-checked on jdwlabs/infrastructure `main` 2026-09-30. A gate polling it waits forever; a script reading it concludes CI never ran | Read `repos/<o>/<r>/commits/<sha>/check-runs?per_page=100` and match on `.check_runs[].name` / `.conclusion` — `success`, `neutral` and `skipped` all satisfy a required context, and a name with no run at all is the real bypass signal. A re-run appends a second run under the same name rather than replacing it, so take the newest by `started_at` |
| A PR that was `mergeable` goes `dirty`/`BLOCKED` with zero CI runs registered for the latest push, sometimes for many minutes | `pull_request`-triggered workflows check out the `refs/pull/<n>/merge` ref, and GitHub can't materialize that ref once the branch conflicts with the current `main` tip — so no run is ever created, independent of merge strategy | `gh api repos/<owner>/<repo>/pulls/<n> --jq '{mergeable, mergeable_state}'` to confirm before assuming CI is stuck; if `dirty`, `git fetch origin main && git rebase origin/main`, resolve, push, and checks register within seconds |
| A locally-resolved conflict reappears at merge time even though the branch showed no conflict before pushing | Resolving with `git merge origin/main` creates a merge commit — but GitHub's rebase-merge replays each of the branch's **original** commits individually and discards merge commits, so the pre-resolution conflict comes back as if nothing was fixed | Resolve with `git rebase origin/main`, then `git push --force-with-lease`. Where a `signatures` check is required, a plain `git rebase` only re-signs replayed commits if `commit.gpgsign=true` (or pass `-S`) |

## Kubernetes and images

| Symptom | Cause | Fix |
|---|---|---|
| A resource's owning controller is unclear, or it looks unmanaged, in `kubectl get -o json` | `managedFields` (which manager set which field) is hidden by default | Add `--show-managed-fields` |
| `.status.containerStatuses[].image` disagrees with the pod spec — a bare `sha256:…` with no repo, or a digest that matches nothing you deployed | That field carries the **config** digest, reported under whichever reference resolved first; `.imageID` carries the repo plus the **manifest** digest. Sampled live: `.image` was `sha256:9700374b…` with no repo while `.imageID` was `docker.io/jdwlabs/ai-sre-relay@sha256:f42b749b…` — two different digests for one running container | Read `.imageID`, never `.status…image`, when verifying which image is running. If the repo names still disagree, compare config/layer digests rather than concluding the wrong image is deployed |
| Comparing a registry digest for an image tag against a pod's `imageID` reports drift that isn't real | A tag can be an OCI **index** (multi-arch manifest list); its digest is never equal to one of its own per-platform **child manifest** digests, even for byte-identical content | Resolve both sides to the same manifest level before comparing (`rtk proxy docker buildx imagetools inspect <ref>`) |

## Windows

| Symptom | Cause | Fix |
|---|---|---|
| `curl --cacert <ca>.pem https://host` reports HTTP 000 on Windows, and it is read as "`--cacert` was ignored" | Windows curl uses the **Schannel** TLS backend, which **does** honour `--cacert` — it verifies against that bundle alone and fails loudly when the chain does not build. HTTP 000 only means no HTTP response was received; every TLS and connection failure reports it, so the status carries no diagnostic information. Verified on curl 8.21.0 (Windows, Schannel): the same `--cacert isrgrootx1.pem` fails `https://example.com` and succeeds against `https://letsencrypt.org`, which is only possible if the bundle is being applied | Read the **exit code**, never the HTTP status: `60` = chain did not verify against the supplied bundle (wrong CA, or an empty one), `77` = bundle unreadable or holding no extractable certificate, `7` = connection refused before TLS (the CA is irrelevant), `2` = the `--cacert` path does not exist. No `openssl s_client` detour is needed |
| A formatter (e.g. `nx format:check --all`) still reports EOL diffs on Windows right after pulling a `.gitattributes` LF pin | `.gitattributes` only governs new checkouts/re-adds — it does not rewrite files already sitting CRLF in an existing working tree | One-time per existing Windows clone, with no uncommitted work (it discards it): `git rm --cached -r . && git reset --hard` to force every tracked file through the new attribute |
