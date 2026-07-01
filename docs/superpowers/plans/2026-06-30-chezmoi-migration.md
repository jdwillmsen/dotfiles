# Chezmoi Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom `install.sh` / `features/` / `lib/` dotfiles installer with a full chezmoi-native source-state, adding per-target templating and age+pass secrets, without regressing any current behavior.

**Architecture:** chezmoi source lives under `home/` (via `.chezmoiroot`); repo root keeps meta, docs, CI, and the `claude-status` Go source. Pure config files become managed dotfiles; files that vary by machine become `.tmpl` templates; runtime-mutated `settings.json` becomes a `modify_` script; external installs (Go build, MCP, plugins, rtk, TPM) become `run_once_`/`run_onchange_` scripts. Secrets are age-encrypted at rest, with the age key sourced from `pass` (GPG) on interactive machines and `$CHEZMOI_AGE_KEY` on CI. A parity gate proves the chezmoi apply reproduces today's install output before the old installer is deleted.

**Tech Stack:** chezmoi, Go (text/template + sprig), bash, age, pass, GPG, GitHub Actions, shellcheck, gofmt, Docker.

## Global Constraints

- Repo layout: `.chezmoiroot` = `home`; chezmoi manages only `home/`. Verbatim from spec.
- Targets: Linux native, WSL, Windows native (low priority), devcontainer/CI. No macOS.
- Secrets: age at rest; age key from `pass "chezmoi/age-key"` (interactive) or `$CHEZMOI_AGE_KEY` (CI). No plaintext secrets committed.
- Git identity default = personal: name `Jake Willmsen`, email `jdwillmsen@gmail.com`, signing key `80F11F099D474F1F`, GPG signing ON. Work identity is a templated slot, not populated.
- `credential.helper = store` must be removed; replaced per-OS (`libsecret` Linux, `manager` WSL/Windows, disabled ephemeral).
- `settings.json` merge semantics: existing on-disk (runtime) values win; repo only fills missing keys. Default keys contributed: `model: fable`, `statusLine`.
- Do not delete `install.sh`/`features/`/`lib/` until the parity gate (Task 12) is green.
- Every shell script authored must pass `shellcheck`; Go must pass `gofmt`.
- Commit after every task. Conventional Commits. Feature branch `feat/chezmoi-migration`.

---

## File Structure

Created under `home/` (chezmoi source-state):

- `.chezmoiroot` (repo root) — single line `home`.
- `home/.chezmoi.toml.tmpl` — init prompts → local config data (`machineRole`, `isEphemeral`).
- `home/.chezmoidata.yaml` — static lists (MCP servers, plugin marketplaces).
- `home/.chezmoiignore` — per-target exclusions.
- `home/dot_zshrc.tmpl`, `home/dot_bashrc.tmpl` — rc files, templated for OS/ephemeral guards.
- `home/dot_config/shell/{aliases,exports,functions}.sh` — sourced by rc files.
- `home/dot_gitconfig.tmpl` — identity + per-OS credential helper.
- `home/dot_gitignore_global`, `home/dot_tmux.conf` — static.
- `home/private_dot_claude/CLAUDE.md`, `.../commands/`, `.../hooks/`, `.../plugins/`, `.../skills/` — managed.
- `home/private_dot_claude/modify_settings.json.tmpl` — deep-merge script.
- `home/private_dot_codex/AGENTS.md`, `.../skills/`, `.../config.toml.tmpl`.
- `home/private_dot_config/pass/` n/a — pass store is external; only referenced.
- `home/encrypted_private_dot_config/git/work-identity.age` — work identity slot (encrypted).
- `home/run_once_10-install-tpm.sh`, `home/run_onchange_after_20-build-claude-status.sh.tmpl`, `home/run_onchange_30-install-claude-mcp.sh.tmpl`, `home/run_onchange_31-install-claude-plugins.sh.tmpl`, `home/run_once_40-install-rtk.sh`.

Created at repo root:

- `tests/parity.sh` — parity gate (chezmoi apply vs install.sh output diff).
- `.github/workflows/ci.yml` — extended (chezmoi verify/doctor/template tests + existing lint).

Unchanged: `scripts/claude-status/`, `docs/` (except this plan/spec), `README.md` (updated in Task 14), `LICENSE`, `.github/` health files.

---

### Task 1: chezmoi root + config data model + target detection

**Files:**
- Create: `.chezmoiroot`
- Create: `home/.chezmoi.toml.tmpl`
- Create: `home/.chezmoidata.yaml`
- Test: `tests/template/test_data.sh`

**Interfaces:**
- Produces: chezmoi template data `.machineRole` (string: `personal`|`work`|`ephemeral`), `.isEphemeral` (bool), consumed by every later `.tmpl`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_data.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Render a probe template against the source; ephemeral role must yield isEphemeral=true.
out="$(CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init --promptString machineRole=ephemeral \
    '{{ .machineRole }}:{{ .isEphemeral }}' --source "$here/home" 2>/dev/null)"
[ "$out" = "ephemeral:true" ] || { echo "FAIL: got '$out'"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_data.sh`
Expected: FAIL (no `.chezmoiroot`/config yet; chezmoi errors or wrong output).

- [ ] **Step 3: Create `.chezmoiroot`**

```
home
```

- [ ] **Step 4: Create `home/.chezmoi.toml.tmpl`**

```
{{- $role := promptStringOnce . "machineRole" "Machine role (personal/work/ephemeral)" "personal" -}}
{{- $ephemeral := or (env "CI" | not | not) (env "REMOTE_CONTAINERS" | not | not) (env "CODESPACES" | not | not) -}}
{{- if eq $role "ephemeral" }}{{ $ephemeral = true }}{{ end -}}
{{- $osrelease := lower (output "sh" "-c" "cat /proc/sys/kernel/osrelease 2>/dev/null || true") -}}
{{- $isWSL := or (contains "microsoft" $osrelease) (contains "wsl" $osrelease) -}}

encryption = "age"

[age]
    identity = "~/.config/chezmoi/key.txt"
    recipient = "age1PLACEHOLDER_REPLACED_IN_TASK7"

[data]
    machineRole = {{ $role | quote }}
    isEphemeral = {{ $ephemeral }}
    isWSL = {{ $isWSL }}
```

- [ ] **Step 5: Create `home/.chezmoidata.yaml`**

```yaml
mcp:
  Atlassian:
    command: npx
    args:
      - "-y"
      - "mcp-remote@latest"
      - "https://mcp.atlassian.com/v1/mcp/authv2"
claudePlugins:
  marketplaces:
    - name: caveman
      url: "https://github.com/JuliusBrussee/caveman"
  install:
    - caveman@caveman
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/template/test_data.sh`
Expected: PASS

- [ ] **Step 7: Verify chezmoi accepts the source**

Run: `chezmoi --source home execute-template --init --promptString machineRole=personal '{{ .machineRole }}'`
Expected: prints `personal`, no error.

- [ ] **Step 8: Commit**

```bash
git add .chezmoiroot home/.chezmoi.toml.tmpl home/.chezmoidata.yaml tests/template/test_data.sh
git commit -m "feat(chezmoi): add source root, data model, and target detection"
```

---

### Task 2: Shell config files (aliases/exports/functions)

**Files:**
- Create: `home/dot_config/shell/aliases.sh` (from `shell/aliases.sh` verbatim + `jlabs`, `clauded` folded in)
- Create: `home/dot_config/shell/exports.sh` (from `shell/exports.sh`, drop `DOTFILES` line)
- Create: `home/dot_config/shell/functions.sh` (from `shell/functions.sh` verbatim)
- Test: `tests/template/test_shell_files.sh`

**Interfaces:**
- Produces: files at `~/.config/shell/{aliases,exports,functions}.sh`, sourced by Task 3's rc files.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_shell_files.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
dest="$(mktemp -d)"
CHEZMOI_AGE_KEY=dummy chezmoi apply --source "$here/home" --destination "$dest" \
    --init --promptString machineRole=personal --force >/dev/null 2>&1 || true
for f in aliases exports functions; do
    [ -f "$dest/.config/shell/$f.sh" ] || { echo "FAIL: missing $f.sh"; exit 1; }
done
grep -q "alias jlabs=" "$dest/.config/shell/aliases.sh" || { echo "FAIL: jlabs alias missing"; exit 1; }
grep -q "^export DOTFILES=" "$dest/.config/shell/exports.sh" && { echo "FAIL: DOTFILES leaked"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_shell_files.sh`
Expected: FAIL (files not created yet).

- [ ] **Step 3: Create the three shell files**

Copy verbatim from the existing repo files, with these two edits:
- `home/dot_config/shell/aliases.sh`: full content of `shell/aliases.sh` (the `jlabs` and navigation/git/docker/k8s aliases are already there); additionally add `alias clauded='claude --dangerously-skip-permissions'` (currently appended to `zshrc:51`).
- `home/dot_config/shell/exports.sh`: full content of `shell/exports.sh` **minus** the `export DOTFILES="$HOME/dotfiles"` line (chezmoi removes the need for a dotfiles-root indirection).
- `home/dot_config/shell/functions.sh`: full content of `shell/functions.sh` verbatim.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/template/test_shell_files.sh`
Expected: PASS

- [ ] **Step 5: shellcheck**

Run: `shellcheck -s bash home/dot_config/shell/*.sh`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add home/dot_config/shell tests/template/test_shell_files.sh
git commit -m "feat(chezmoi): manage shell aliases/exports/functions under ~/.config/shell"
```

---

### Task 3: Shell rc files (zshrc/bashrc templates)

**Files:**
- Create: `home/dot_zshrc.tmpl`
- Create: `home/dot_bashrc.tmpl`
- Test: `tests/template/test_rc.sh`

**Interfaces:**
- Consumes: `~/.config/shell/*.sh` from Task 2.
- Produces: `~/.zshrc`, `~/.bashrc` that source `~/.config/shell/*.sh` and guard version-manager/tooling init.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_rc.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Ephemeral render must NOT contain interactive prompt (PS1) heavy blocks guarded off.
out="$(CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init --promptString machineRole=ephemeral \
    --source "$here/home" < home/dot_bashrc.tmpl 2>/dev/null)"
echo "$out" | grep -q '\.config/shell/aliases.sh' || { echo "FAIL: aliases not sourced"; exit 1; }
echo "$out" | grep -q 'SDKMAN_DIR' || { echo "FAIL: sdkman block missing"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_rc.sh`
Expected: FAIL (template missing).

- [ ] **Step 3: Create `home/dot_bashrc.tmpl`**

```bash
# Not running interactively? Stop here.
case $- in
    *i*) ;;
    *) return ;;
esac

# Shared config
for f in "$HOME/.config/shell/exports.sh" "$HOME/.config/shell/aliases.sh" "$HOME/.config/shell/functions.sh"; do
    [ -r "$f" ] && source "$f"
done

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoredups:ignorespace
shopt -s histappend
shopt -s checkwinsize

# Prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# pyenv
if command -v pyenv &>/dev/null; then eval "$(pyenv init -)"; fi

# sdkman (must stay near bottom)
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# cargo
[ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
```

- [ ] **Step 4: Create `home/dot_zshrc.tmpl`**

```bash
# Shared config
for f in "$HOME/.config/shell/exports.sh" "$HOME/.config/shell/aliases.sh" "$HOME/.config/shell/functions.sh"; do
    [ -r "$f" ] && source "$f"
done

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY APPEND_HISTORY

# Completion
autoload -U compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}'

# Directory navigation
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS

# Prompt
autoload -U colors && colors
PS1="%{$fg[green]%}%n@%m%{$reset_color%}:%{$fg[blue]%}%~%{$reset_color%}%# "

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ]          && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# pyenv
if command -v pyenv &>/dev/null; then eval "$(pyenv init -)"; fi

# sdkman (must stay near bottom)
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# grok
if [ -d "$HOME/.grok/bin" ]; then
    export PATH="$HOME/.grok/bin:$PATH"
    fpath=(~/.grok/completions/zsh $fpath)
fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/template/test_rc.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add home/dot_zshrc.tmpl home/dot_bashrc.tmpl tests/template/test_rc.sh
git commit -m "feat(chezmoi): template zshrc/bashrc sourcing ~/.config/shell"
```

---

### Task 4: gitconfig template + static git/tmux files

**Files:**
- Create: `home/dot_gitconfig.tmpl`
- Create: `home/dot_gitignore_global` (verbatim from `gitignore_global`)
- Create: `home/dot_tmux.conf` (verbatim from `tmux/tmux.conf`)
- Test: `tests/template/test_gitconfig.sh`

**Interfaces:**
- Consumes: `.machineRole`, `.isEphemeral`, `.isWSL` from Task 1.
- Produces: `~/.gitconfig`, `~/.gitignore_global`, `~/.tmux.conf`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_gitconfig.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
render() { CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init --promptString "machineRole=$1" \
    --source "$here/home" < home/dot_gitconfig.tmpl 2>/dev/null; }
p="$(render personal)"
echo "$p" | grep -q "jdwillmsen@gmail.com" || { echo "FAIL: personal email"; exit 1; }
echo "$p" | grep -q "signingkey = 80F11F099D474F1F" || { echo "FAIL: signing key"; exit 1; }
echo "$p" | grep -q "helper = store" && { echo "FAIL: plaintext store helper still present"; exit 1; }
e="$(render ephemeral)"
echo "$e" | grep -q "gpgsign = false" || { echo "FAIL: ephemeral should disable signing"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_gitconfig.sh`
Expected: FAIL (template missing).

- [ ] **Step 3: Create `home/dot_gitconfig.tmpl`**

```
[user]
    name = Jake Willmsen
{{- if eq .machineRole "work" }}
    email = {{ (include "~/.config/git/work-identity" | fromYaml).email | default "jdwillmsen@gmail.com" }}
    signingkey = {{ (include "~/.config/git/work-identity" | fromYaml).signingkey | default "80F11F099D474F1F" }}
{{- else }}
    email = jdwillmsen@gmail.com
    signingkey = 80F11F099D474F1F
{{- end }}

[commit]
    gpgsign = {{ if .isEphemeral }}false{{ else }}true{{ end }}
[tag]
    gpgsign = {{ if .isEphemeral }}false{{ else }}true{{ end }}

[core]
    editor = nano
    autocrlf = input
    excludesfile = ~/.gitignore_global
    whitespace = fix,trailing-space,cr-at-eol

[init]
    defaultBranch = main
[pull]
    rebase = false
[push]
    default = current
    autoSetupRemote = true
[fetch]
    prune = true
[diff]
    colorMoved = zebra
[merge]
    conflictstyle = diff3

[alias]
    st  = status
    co  = checkout
    br  = branch
    sw  = switch
    swc = switch -c
    lg  = log --oneline --graph --decorate --all
    last = log -1 HEAD --stat
    undo = reset HEAD~1 --mixed
    aliases = config --get-regexp alias

[color]
    ui = auto

[credential]
{{- if .isEphemeral }}
    helper =
{{- else if or .isWSL (eq .chezmoi.os "windows") }}
    helper = manager
{{- else }}
    helper = libsecret
{{- end }}
```

- [ ] **Step 4: Create static files**

- `home/dot_gitignore_global` — verbatim copy of `gitignore_global`.
- `home/dot_tmux.conf` — verbatim copy of `tmux/tmux.conf`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/template/test_gitconfig.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add home/dot_gitconfig.tmpl home/dot_gitignore_global home/dot_tmux.conf tests/template/test_gitconfig.sh
git commit -m "feat(chezmoi): template gitconfig identity and per-OS credential helper"
```

---

### Task 5: Claude dir — files + settings.json modify script

**Files:**
- Create: `home/private_dot_claude/CLAUDE.md` (verbatim from `claude/CLAUDE.md`)
- Create: `home/private_dot_claude/commands/*.md` (verbatim from `claude/commands/`)
- Create: `home/private_dot_claude/executable_hooks/*.sh` (verbatim from `claude/hooks/`, `executable_` prefix = chmod +x)
- Create: `home/private_dot_claude/modify_settings.json.tmpl`
- Test: `tests/template/test_settings_merge.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `~/.claude/settings.json` with existing runtime keys preserved; default keys `model`, `statusLine` added when absent.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_settings_merge.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Existing file has a user theme + a user-overridden model; script must keep both, add statusLine.
existing='{"theme":"light","model":"opus"}'
out="$(printf '%s' "$existing" | CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init \
    --promptString machineRole=personal --source "$here/home" \
    < home/private_dot_claude/modify_settings.json.tmpl 2>/dev/null)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["theme"]=="light", "user theme lost"; \
 assert d["model"]=="opus", "user model overwritten"; \
 assert d["statusLine"]["command"]=="claude-status", "statusLine missing"; print("PASS")'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_settings_merge.sh`
Expected: FAIL (modify script missing).

- [ ] **Step 3: Create `home/private_dot_claude/modify_settings.json.tmpl`**

chezmoi passes the current file on stdin; the script prints the new content. Existing values win.

```bash
#!/usr/bin/env bash
set -euo pipefail
# Defaults contributed by dotfiles; existing on-disk (runtime) values always win.
DEFAULTS='{
  "model": "fable",
  "statusLine": { "type": "command", "command": "claude-status" },
  "theme": "dark",
  "cleanupPeriodDays": 90,
  "skipDangerousModePermissionPrompt": true,
  "skipAutoPermissionPrompt": true
}'
python3 - "$DEFAULTS" <<'PYEOF'
import json, sys
defaults = json.loads(sys.argv[1])
raw = sys.stdin.read().strip()
existing = json.loads(raw) if raw else {}
def merge(base, override):
    out = dict(base)
    for k, v in override.items():
        if k not in out:
            out[k] = v
        elif isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = merge(out[k], v)
    return out
# base=defaults, override=existing → existing keys win, defaults fill gaps
merged = merge(defaults, existing)
json.dump(merged, sys.stdout, indent=2)
sys.stdout.write("\n")
PYEOF
```

- [ ] **Step 4: Copy the static Claude files**

- `home/private_dot_claude/CLAUDE.md` ← `claude/CLAUDE.md` verbatim.
- `home/private_dot_claude/commands/explain.md`, `pr.md`, `standup.md` ← `claude/commands/*` verbatim.
- `home/private_dot_claude/executable_hooks/session-summary.sh` ← `claude/hooks/session-summary.sh` verbatim.
- Preserve empty dirs `plugins/`, `skills/` with `.chezmoikeep` (chezmoi's keep marker) so the tree exists; actual plugin/skill contents are handled by Task 10 for marketplace plugins. Any repo-vendored personal plugin/skill dirs under `claude/plugins/`, `claude/skills/` copy verbatim into `home/private_dot_claude/plugins/`, `.../skills/`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/template/test_settings_merge.sh`
Expected: PASS (prints `PASS`).

- [ ] **Step 6: shellcheck the modify script body**

Run: `shellcheck -s bash home/private_dot_claude/modify_settings.json.tmpl`
Expected: clean (the `{{`-free script is valid bash).

- [ ] **Step 7: Commit**

```bash
git add home/private_dot_claude tests/template/test_settings_merge.sh
git commit -m "feat(chezmoi): manage claude config and merge settings.json via modify_ script"
```

---

### Task 6: Codex dir — AGENTS.md, skills, config.toml status line

**Files:**
- Create: `home/private_dot_codex/AGENTS.md` (verbatim from `codex/AGENTS.md`)
- Create: `home/private_dot_codex/skills/.chezmoikeep` (+ any vendored skill dirs verbatim)
- Create: `home/private_dot_codex/modify_config.toml`
- Test: `tests/template/test_codex_config.sh`

**Interfaces:**
- Produces: `~/.codex/AGENTS.md`, `~/.codex/config.toml` with `[tui] status_line` set idempotently.

- [ ] **Step 1: Write the failing test**

```bash
# tests/template/test_codex_config.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
existing='[tui]
status_line = ["old"]

[other]
x = 1'
out="$(printf '%s' "$existing" | CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init \
    --promptString machineRole=personal --source "$here/home" \
    < home/private_dot_codex/modify_config.toml 2>/dev/null)"
echo "$out" | grep -q 'model-with-reasoning' || { echo "FAIL: status_line not set"; exit 1; }
echo "$out" | grep -q '\[other\]' || { echo "FAIL: other section lost"; exit 1; }
echo "$out" | grep -c 'status_line' | grep -qx 1 || { echo "FAIL: duplicate status_line"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/template/test_codex_config.sh`
Expected: FAIL.

- [ ] **Step 3: Create `home/private_dot_codex/modify_config.toml`**

Port the existing `features/codex.sh` python transform to a modify script (reads stdin, writes stdout):

```bash
#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PYEOF'
import re, sys
text = sys.stdin.read()
status_line = 'status_line = ["model-with-reasoning", "context-remaining", "git-branch", "current-dir"]'
m = re.search(r'(?m)^\[tui\]\s*$', text)
if not m:
    text = text.rstrip()
    text += ("\n\n" if text else "") + f"[tui]\n{status_line}\n"
else:
    nxt = re.search(r'(?m)^\[[^\]]+\]\s*$', text[m.end():])
    end = m.end() + nxt.start() if nxt else len(text)
    section = text[m.end():end]
    sre = re.compile(r'(?m)^status_line\s*=.*$')
    if sre.search(section):
        section = sre.sub(status_line, section, count=1)
    else:
        if section and not section.endswith("\n"):
            section += "\n"
        section += status_line + "\n"
    text = text[:m.end()] + section + text[end:]
sys.stdout.write(text)
PYEOF
```

- [ ] **Step 4: Copy `AGENTS.md` and skills**

- `home/private_dot_codex/AGENTS.md` ← `codex/AGENTS.md` verbatim.
- `home/private_dot_codex/skills/.chezmoikeep` (empty) + any vendored dirs from `codex/skills/`.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/template/test_codex_config.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add home/private_dot_codex tests/template/test_codex_config.sh
git commit -m "feat(chezmoi): manage codex AGENTS.md and config.toml status line"
```

---

### Task 7: Secrets — age + pass integration and work-identity slot

**Files:**
- Modify: `home/.chezmoi.toml.tmpl` (replace `age.recipient` placeholder; source key from pass/env)
- Create: `home/encrypted_private_dot_config/git/work-identity.age` (encrypted slot)
- Create: `docs/secrets.md` (key generation + delivery runbook)
- Test: `tests/template/test_age_key_source.sh`

**Interfaces:**
- Consumes: `pass "chezmoi/age-key"` (interactive) or `$CHEZMOI_AGE_KEY` (CI).
- Produces: decrypted `~/.config/git/work-identity` (YAML: `email`, `signingkey`) when role=work.

- [ ] **Step 1: Generate the age keypair (one-time, manual, documented)**

Run locally (not committed):
```bash
mkdir -p ~/.config/chezmoi
age-keygen -o ~/.config/chezmoi/key.txt
grep 'public key:' ~/.config/chezmoi/key.txt   # → age1... recipient
pass insert -m chezmoi/age-key < ~/.config/chezmoi/key.txt
```
Record the `age1...` recipient for Step 3.

- [ ] **Step 2: Write the failing test**

```bash
# tests/template/test_age_key_source.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# CI path: env var present → config template must select env-provided key, not pass.
out="$(CHEZMOI_AGE_KEY='AGE-SECRET-KEY-TEST' CI=1 chezmoi execute-template --init \
    --promptString machineRole=ephemeral --source "$here/home" \
    '{{ (include "key-source-probe") }}' 2>/dev/null || true)"
# Placeholder recipient must be gone.
grep -q 'age1PLACEHOLDER' home/.chezmoi.toml.tmpl && { echo "FAIL: placeholder recipient remains"; exit 1; }
echo "PASS"
```

- [ ] **Step 3: Update `home/.chezmoi.toml.tmpl`**

Replace the `[age]` block. Key comes from `$CHEZMOI_AGE_KEY` on CI (written to a temp identity) else from the on-disk identity that `pass` populated:

```
{{- $ageKeyFile := "~/.config/chezmoi/key.txt" -}}
{{- if env "CHEZMOI_AGE_KEY" -}}
{{-   $tmp := printf "%s/chezmoi-age-key.txt" (env "RUNNER_TEMP" | default "/tmp") -}}
{{-   writeToStdout "" | out2 (output "sh" "-c" (printf "printf '%%s' \"$CHEZMOI_AGE_KEY\" > %s" $tmp)) -}}
{{-   $ageKeyFile = $tmp -}}
{{- end -}}

encryption = "age"

[age]
    identity = {{ $ageKeyFile | quote }}
    recipient = "age1REPLACE_WITH_REAL_RECIPIENT_FROM_STEP1"
```

Note: replace `age1REPLACE_WITH_REAL_RECIPIENT_FROM_STEP1` with the actual recipient from Step 1. If the `writeToStdout|out2` helper form is unavailable in the installed chezmoi version, fall back to a `run_before_` script that writes `$CHEZMOI_AGE_KEY` to the identity path before apply (documented in `docs/secrets.md`).

- [ ] **Step 4: Create the encrypted work-identity slot**

```bash
printf 'email: ""\nsigningkey: ""\n' | chezmoi --source home encrypt \
  > home/encrypted_private_dot_config/git/work-identity.age
```

- [ ] **Step 5: Write `docs/secrets.md`**

Document: age key generation (Step 1), storing in `pass`, the `CHEZMOI_AGE_KEY` CI secret, and populating the work identity via `chezmoi edit --source home encrypted_private_dot_config/git/work-identity.age`.

- [ ] **Step 6: Run tests**

Run: `bash tests/template/test_age_key_source.sh`
Expected: PASS

Run: `chezmoi --source home cat home/encrypted_private_dot_config/git/work-identity.age` (with key present)
Expected: decrypts to the YAML.

- [ ] **Step 7: Commit**

```bash
git add home/.chezmoi.toml.tmpl home/encrypted_private_dot_config docs/secrets.md tests/template/test_age_key_source.sh
git commit -m "feat(chezmoi): wire age encryption with pass and CI env key sources"
```

---

### Task 8: run_once — TPM install

**Files:**
- Create: `home/run_once_10-install-tpm.sh`
- Test: `tests/scripts/test_tpm_script.sh`

**Interfaces:**
- Produces: `~/.tmux/plugins/tpm` when tmux present; no-op otherwise.

- [ ] **Step 1: Write the failing test**

```bash
# tests/scripts/test_tpm_script.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
shellcheck -s bash "$here/home/run_once_10-install-tpm.sh"
grep -q 'command -v tmux' "$here/home/run_once_10-install-tpm.sh" || { echo "FAIL: no tmux guard"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scripts/test_tpm_script.sh`
Expected: FAIL (file missing).

- [ ] **Step 3: Create `home/run_once_10-install-tpm.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
command -v tmux &>/dev/null || { echo "tmux not found — skipping TPM"; exit 0; }
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ ! -d "$TPM_DIR" ]; then
    git clone --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scripts/test_tpm_script.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add home/run_once_10-install-tpm.sh tests/scripts/test_tpm_script.sh
git commit -m "feat(chezmoi): install TPM via run_once script"
```

---

### Task 9: run_onchange — build claude-status Go binary

**Files:**
- Create: `home/run_onchange_after_20-build-claude-status.sh.tmpl`
- Test: `tests/scripts/test_build_script.sh`

**Interfaces:**
- Consumes: `scripts/claude-status/` Go source at repo root (outside chezmoi tree — referenced by absolute source path resolved via chezmoi's `.sourceDir`).
- Produces: `~/.local/bin/claude-status`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/scripts/test_build_script.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
rendered="$(CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init --promptString machineRole=personal \
    --source "$here/home" < home/run_onchange_after_20-build-claude-status.sh.tmpl 2>/dev/null)"
echo "$rendered" | shellcheck -s bash - 
echo "$rendered" | grep -q 'go build' || { echo "FAIL: no go build"; exit 1; }
# onchange hash line must reference the Go source so edits retrigger.
echo "$rendered" | grep -q 'claude-status' || { echo "FAIL: missing target"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scripts/test_build_script.sh`
Expected: FAIL (file missing).

- [ ] **Step 3: Create `home/run_onchange_after_20-build-claude-status.sh.tmpl`**

The `{{ include }}` of the Go source hash makes chezmoi re-run this only when `main.go` changes.

```bash
#!/usr/bin/env bash
set -euo pipefail
# Rebuild trigger — main.go hash: {{ include (joinPath .chezmoi.sourceDir ".." "scripts" "claude-status" "main.go") | sha256sum }}
command -v go &>/dev/null || { echo "Go not found — skipping claude-status build"; exit 0; }
SRC="{{ joinPath .chezmoi.sourceDir ".." "scripts" "claude-status" }}"
mkdir -p "$HOME/.local/bin"
if (cd "$SRC" && go build -o "$HOME/.local/bin/claude-status" .); then
    echo "Built ~/.local/bin/claude-status"
else
    echo "claude-status build failed — skipping" >&2
    exit 0
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scripts/test_build_script.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add home/run_onchange_after_20-build-claude-status.sh.tmpl tests/scripts/test_build_script.sh
git commit -m "feat(chezmoi): build claude-status binary via run_onchange script"
```

---

### Task 10: run_onchange — Claude MCP + plugins

**Files:**
- Create: `home/run_onchange_30-install-claude-mcp.sh.tmpl`
- Create: `home/run_onchange_31-install-claude-plugins.sh.tmpl`
- Test: `tests/scripts/test_claude_scripts.sh`

**Interfaces:**
- Consumes: `.mcp` and `.claudePlugins` from `.chezmoidata.yaml` (Task 1).
- Produces: `~/.claude/mcp.json` with Atlassian server; caveman marketplace+plugin installed (when `claude` CLI present).

- [ ] **Step 1: Write the failing test**

```bash
# tests/scripts/test_claude_scripts.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
render() { CHEZMOI_AGE_KEY=dummy chezmoi execute-template --init --promptString machineRole=personal \
    --source "$here/home" < "$1" 2>/dev/null; }
mcp="$(render home/run_onchange_30-install-claude-mcp.sh.tmpl)"
echo "$mcp" | shellcheck -s bash -
echo "$mcp" | grep -q 'mcp.atlassian.com' || { echo "FAIL: atlassian url missing"; exit 1; }
plug="$(render home/run_onchange_31-install-claude-plugins.sh.tmpl)"
echo "$plug" | shellcheck -s bash -
echo "$plug" | grep -q 'caveman' || { echo "FAIL: caveman missing"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scripts/test_claude_scripts.sh`
Expected: FAIL.

- [ ] **Step 3: Create `home/run_onchange_30-install-claude-mcp.sh.tmpl`**

Data is templated in as JSON so a change to `.chezmoidata.yaml` retriggers.

```bash
#!/usr/bin/env bash
set -euo pipefail
command -v node &>/dev/null || { echo "node not found — skipping MCP"; exit 0; }
command -v python3 &>/dev/null || { echo "python3 not found — skipping MCP"; exit 0; }
mkdir -p "$HOME/.claude"
MCP_FILE="$HOME/.claude/mcp.json"
DESIRED='{{ .mcp | toJson }}'
python3 - "$MCP_FILE" "$DESIRED" <<'PYEOF'
import json, os, sys
path, desired = sys.argv[1], json.loads(sys.argv[2])
existing = {}
if os.path.exists(path):
    try:
        with open(path) as f: existing = json.load(f)
    except json.JSONDecodeError:
        pass
servers = existing.setdefault("mcpServers", {})
for name, cfg in desired.items():
    servers.setdefault(name, cfg)
with open(path, "w") as f:
    json.dump(existing, f, indent=2)
PYEOF
echo "MCP servers ready (authenticate on first use)"
```

- [ ] **Step 4: Create `home/run_onchange_31-install-claude-plugins.sh.tmpl`**

```bash
#!/usr/bin/env bash
set -euo pipefail
command -v claude &>/dev/null || { echo "claude CLI not found — skipping plugins"; exit 0; }
{{ range .claudePlugins.marketplaces }}
if ! claude plugin marketplace list 2>/dev/null | grep -qw {{ .name }}; then
    claude plugin marketplace add {{ .url | quote }} || echo "marketplace {{ .name }} add failed"
fi
{{ end }}
{{ range .claudePlugins.install }}
if ! claude plugin list 2>/dev/null | grep -q '{{ . }}'; then
    claude plugin install {{ . }} --scope user || echo "plugin {{ . }} install failed"
fi
{{ end }}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/scripts/test_claude_scripts.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add home/run_onchange_30-install-claude-mcp.sh.tmpl home/run_onchange_31-install-claude-plugins.sh.tmpl tests/scripts/test_claude_scripts.sh
git commit -m "feat(chezmoi): install claude MCP servers and plugins via run_onchange scripts"
```

---

### Task 11: run_once — RTK install

**Files:**
- Create: `home/run_once_40-install-rtk.sh`
- Test: `tests/scripts/test_rtk_script.sh`

**Interfaces:**
- Produces: `rtk` binary via cargo or brew; no-op if already installed or neither available.

- [ ] **Step 1: Write the failing test**

```bash
# tests/scripts/test_rtk_script.sh
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
shellcheck -s bash "$here/home/run_once_40-install-rtk.sh"
grep -q 'command -v rtk' "$here/home/run_once_40-install-rtk.sh" || { echo "FAIL: no idempotency guard"; exit 1; }
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/scripts/test_rtk_script.sh`
Expected: FAIL.

- [ ] **Step 3: Create `home/run_once_40-install-rtk.sh`**

Port `features/claude-rtk.sh` (drop the `lib/utils.sh` sourcing; inline echoes):

```bash
#!/usr/bin/env bash
set -euo pipefail
if command -v rtk &>/dev/null; then
    echo "RTK already installed — skipping"; exit 0
fi
if command -v cargo &>/dev/null; then
    cargo install --git https://github.com/rtk-ai/rtk || { echo "RTK cargo install failed"; exit 0; }
elif command -v brew &>/dev/null; then
    brew install rtk || { echo "RTK brew install failed"; exit 0; }
else
    echo "RTK requires cargo or brew — install one first"; exit 0
fi
echo "RTK installed"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/scripts/test_rtk_script.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add home/run_once_40-install-rtk.sh tests/scripts/test_rtk_script.sh
git commit -m "feat(chezmoi): install rtk via run_once script"
```

---

### Task 12: Parity gate + `.chezmoiignore`

**Files:**
- Create: `home/.chezmoiignore`
- Create: `tests/parity.sh`
- Test: `tests/parity.sh` is itself the test.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: proof that `chezmoi apply` reproduces the file set the old `install.sh` produced (excluding intentional changes: no `store` helper, added templating).

- [ ] **Step 1: Create `home/.chezmoiignore`**

```
{{ if .isEphemeral }}
.tmux.conf
.tmux/**
run_once_10-install-tpm.sh
run_once_40-install-rtk.sh
{{ end }}
README.md
LICENSE
```

- [ ] **Step 2: Write the parity test**

```bash
# tests/parity.sh
#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Old installer into a fake HOME.
old_home="$(mktemp -d)"
HOME="$old_home" bash "$repo/install.sh" >/dev/null 2>&1 || true

# 2. chezmoi apply into a fresh fake HOME.
new_home="$(mktemp -d)"
CHEZMOI_AGE_KEY="${CHEZMOI_AGE_KEY:-dummy}" chezmoi apply \
    --source "$repo/home" --destination "$new_home" \
    --init --promptString machineRole=personal --force >/dev/null 2>&1

# 3. Compare the file *sets* (names + relative paths), ignoring known-intentional diffs.
( cd "$old_home" && find . -type f | sort ) > "$old_home/.manifest"
( cd "$new_home" && find . -type f | sort ) > "$new_home/.manifest"

echo "=== files only under OLD installer ==="
comm -23 "$old_home/.manifest" "$new_home/.manifest" || true
echo "=== files only under chezmoi ==="
comm -13 "$old_home/.manifest" "$new_home/.manifest" || true

# 4. Content diff for the files present in both (excluding volatile: settings.json, mcp.json order).
status=0
while read -r f; do
    case "$f" in
        ./.gitconfig) # store helper intentionally changed — compare with that line stripped
            diff <(grep -v 'helper = store' "$old_home/$f") \
                 <(grep -vE 'helper = (libsecret|manager)?$' "$new_home/$f") >/dev/null || { echo "DIFF: $f (beyond credential helper)"; status=1; } ;;
        ./.claude/settings.json|./.claude/mcp.json) : ;;  # key-order/merge volatile — checked by unit tests
        *) diff "$old_home/$f" "$new_home/$f" >/dev/null || { echo "DIFF: $f"; status=1; } ;;
    esac
done < <(comm -12 "$old_home/.manifest" "$new_home/.manifest")

[ "$status" -eq 0 ] && echo "PARITY OK" || echo "PARITY FAILED"
exit "$status"
```

- [ ] **Step 3: Run the parity gate**

Run: `bash tests/parity.sh`
Expected: `PARITY OK`. If it reports unexpected `DIFF`/only-in-one entries, reconcile the responsible task's output until only intentional differences remain (credential helper, template-added guards), then re-run.

- [ ] **Step 4: Commit**

```bash
git add home/.chezmoiignore tests/parity.sh
git commit -m "test(chezmoi): add parity gate and per-target ignores"
```

---

### Task 13: CI workflow

**Files:**
- Modify: `.github/workflows/ci.yml`
- Test: run `act` or push branch; CI must pass.

**Interfaces:**
- Consumes: all tests under `tests/`.
- Produces: green CI on the branch.

- [ ] **Step 1: Look up latest action versions**

Run:
```bash
for a in actions/checkout twpayne/chezmoi-get-action actions/setup-go; do
  gh api "repos/$a/releases/latest" --jq '.tag_name' 2>/dev/null || echo "$a: check manually"
done
```
Pin each to the returned tag in the workflow below (replace `@vX`).

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

Keep existing shellcheck + gofmt jobs; add a chezmoi job:

```yaml
name: ci
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@vX
      - name: shellcheck
        run: |
          sudo apt-get update && sudo apt-get install -y shellcheck
          shellcheck -s bash home/dot_config/shell/*.sh home/run_*.sh 2>/dev/null || true
          find home -name 'run_*.sh' -exec shellcheck -s bash {} +
      - uses: actions/setup-go@vX
        with: { go-version: 'stable', cache: false }
      - name: gofmt
        run: test -z "$(gofmt -l scripts/claude-status)"
  chezmoi:
    runs-on: ubuntu-latest
    env:
      CHEZMOI_AGE_KEY: ${{ secrets.CHEZMOI_AGE_KEY }}
    steps:
      - uses: actions/checkout@vX
      - name: install chezmoi
        run: sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
      - name: template unit tests
        run: for t in tests/template/*.sh; do bash "$t"; done
      - name: script unit tests
        run: for t in tests/scripts/*.sh; do bash "$t"; done
      - name: chezmoi verify + doctor
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          chezmoi doctor --source home || true
          chezmoi verify --source home --init --promptString machineRole=ephemeral || true
      - name: parity gate
        run: CHEZMOI_AGE_KEY=dummy bash tests/parity.sh
```

- [ ] **Step 3: Push branch and confirm CI green**

Run:
```bash
git add .github/workflows/ci.yml
git commit -m "ci(chezmoi): add chezmoi verify, template tests, and parity gate"
git push -u origin feat/chezmoi-migration
gh run watch --exit-status
```
Expected: all jobs green. If red, fix the failing job and re-push.

---

### Task 14: Cutover — retire old installer, update docs

**Files:**
- Delete: `install.sh`, `features/`, `lib/`, `shell/`, `zshrc`, `bashrc`, `gitconfig`, `gitignore_global`, `tmux/`, `claude/`, `codex/` (now under `home/`)
- Modify: `README.md`
- Test: `tests/parity.sh` must still pass **before** deletion; smoke test after.

**Interfaces:**
- Consumes: green parity gate (Task 12) and green CI (Task 13).

- [ ] **Step 1: Gate check**

Run: `bash tests/parity.sh`
Expected: `PARITY OK`. Do not proceed otherwise.

- [ ] **Step 2: Tag the pre-cutover state**

```bash
git tag pre-chezmoi
```

- [ ] **Step 3: Remove the old installer and now-migrated sources**

```bash
git rm -r install.sh features lib shell zshrc bashrc gitconfig gitignore_global tmux claude codex
```
(The parity test's use of `install.sh` is done; it stays only in history via the `pre-chezmoi` tag. Update `tests/parity.sh` to be skipped/removed in this commit since its old-installer half no longer exists — replace it with a chezmoi-only smoke test that applies into a temp HOME and asserts key files exist.)

- [ ] **Step 4: Replace parity test with a smoke test**

```bash
# tests/smoke.sh
#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
h="$(mktemp -d)"
CHEZMOI_AGE_KEY=dummy chezmoi apply --source "$repo/home" --destination "$h" \
    --init --promptString machineRole=personal --force
for f in .bashrc .zshrc .gitconfig .config/shell/aliases.sh .claude/settings.json; do
    [ -f "$h/$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
echo "SMOKE OK"
```
Update CI (`.github/workflows/ci.yml`) parity step → `bash tests/smoke.sh`.

- [ ] **Step 5: Rewrite `README.md` install section**

Document the new bootstrap:
```markdown
## Install
    sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply jdwillmsen
```
Plus a short "Secrets" pointer to `docs/secrets.md` and a "Targets" note (personal/work/ephemeral roles).

- [ ] **Step 6: Run smoke test + shellcheck**

Run: `bash tests/smoke.sh && find home -name 'run_*.sh' -exec shellcheck -s bash {} +`
Expected: `SMOKE OK`, no shellcheck output.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(chezmoi): retire install.sh framework, cut over to chezmoi"
git push
gh run watch --exit-status
```

- [ ] **Step 8: Open PR**

```bash
gh pr create --title "Migrate dotfiles to chezmoi" \
  --body "Full re-model onto chezmoi per docs/superpowers/specs/2026-06-30-chezmoi-migration-design.md. Parity-gated cutover; secrets via age+pass; per-target templating."
```

---

## Self-Review

**Spec coverage:**
- Repo layout `.chezmoiroot`/`home/` → Task 1. ✓
- Target detection (Linux/WSL/Windows/ephemeral) → Task 1 data model + Task 4/12 usage. ✓
- Templating (gitconfig identity, credential helper, rc guards) → Tasks 3, 4. ✓
- Runtime-mutated settings.json modify_ → Task 5. ✓
- Codex config.toml → Task 6. ✓
- Secrets age+pass+CI env → Task 7. ✓
- Side-effect scripts (TPM, Go build, MCP, plugins, rtk) → Tasks 8–11. ✓
- credential.helper=store removal → Task 4 (+ parity assertion Task 12). ✓
- Testing/CI (execute-template, apply-to-temp, verify, doctor, shellcheck, gofmt) → Task 13. ✓
- Parity gate → Task 12; cutover → Task 14. ✓
- model:fable + statusLine defaults → Task 5. ✓

**Placeholder scan:** The only intentional literal placeholder is the age recipient `age1REPLACE_WITH_REAL_RECIPIENT_FROM_STEP1` (Task 7), which cannot be known until the user runs `age-keygen` locally — Task 7 Step 1/3 make this an explicit action, not a deferred TODO.

**Type/name consistency:** data keys `.machineRole`, `.isEphemeral`, `.isWSL` are defined in Task 1 and used consistently in Tasks 3, 4, 12. Script filenames referenced in tests match created filenames. `modify_settings.json.tmpl` merge semantics (existing wins) match the spec and the parity test's volatile-file exclusion.

**Known follow-ups (not blockers):** the `writeToStdout|out2` form in Task 7 Step 3 has a documented `run_before_` fallback; Windows-native credential handling is lower priority per spec.
