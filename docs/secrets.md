# Secrets

Encrypted source files (`encrypted_*`) are decrypted at apply time with
[age](https://age-encryption.org/). The identity (private key) never lives
in the repo; it's sourced from `pass` on interactive machines or from the
`CHEZMOI_AGE_KEY` environment variable in CI.

## Key generation (one-time, manual)

Run on a trusted machine — not committed anywhere:

```bash
mkdir -p ~/.config/chezmoi
age-keygen -o ~/.config/chezmoi/key.txt
grep 'public key:' ~/.config/chezmoi/key.txt   # → age1... recipient
```

Put the `age1...` recipient in `home/.chezmoi.toml.tmpl`'s `[age].recipient`.

## Storing the key in `pass` (Linux/WSL)

`pass` isn't available on Windows; run this on a Linux/WSL machine that has
`pass` set up:

```bash
pass insert -m chezmoi/age-key < ~/.config/chezmoi/key.txt
```

On machines with `pass`, chezmoi is expected to read the identity from
`~/.config/chezmoi/key.txt` directly (the default `[age].identity`), so this
step is about having a durable, shareable backup of the key — not a runtime
dependency chezmoi calls into automatically. Restore it with:

```bash
mkdir -p ~/.config/chezmoi
pass chezmoi/age-key > ~/.config/chezmoi/key.txt
```

## CI: `CHEZMOI_AGE_KEY`

Set `CHEZMOI_AGE_KEY` to the full contents of `key.txt` as a CI secret (e.g.
a GitHub Actions repository secret). `home/.chezmoi.toml.tmpl` detects the
env var and points `[age].identity` at `$RUNNER_TEMP/chezmoi-age-key.txt`
instead of the local `pass`-populated path.

That temp file is written by `home/run_before_00-write-ci-age-key.sh`, which
runs before chezmoi applies any file — including decrypting `encrypted_`
entries — and is a no-op when `CHEZMOI_AGE_KEY` is unset (the local/`pass`
path). A separate script is used instead of computing this inline in the
config template because chezmoi's `writeToStdout | out2` idiom for
side-effecting during config templating isn't available in this chezmoi
version.

## Populating the work-identity slot

`home/dot_config/private_git/encrypted_work-identity.age` decrypts to
`~/.config/git/work-identity`, a YAML file with `email` and `signingkey`
consumed by `home/dot_gitconfig.tmpl` when `machineRole` is `work`. It ships
committed with blank values (`email: ""`, `signingkey: ""`), which
`dot_gitconfig.tmpl` treats as "unset" and falls back to the personal
identity for.

To populate it with real work values:

```bash
chezmoi edit --source home home/dot_config/private_git/encrypted_work-identity.age
```

This decrypts the file, opens it in `$EDITOR`, and re-encrypts on save. Set
`email` and `signingkey` to the work identity, then re-run `chezmoi apply`.

## Notes

- `encrypted_` source files are only ever committed in their encrypted
  (`.age`) form — the plaintext content never touches git.
- `dot_gitconfig.tmpl` reads the encrypted slot with
  `include "dot_config/private_git/encrypted_work-identity.age" | decrypt | fromYaml`
  rather than `include` on the decrypted destination path: `include`
  resolves relative to the chezmoi *source* directory, so it can't see
  target files chezmoi hasn't applied yet.

Because the work-identity slot is an `encrypted_` source file, chezmoi
decrypts it unconditionally on every `chezmoi apply` regardless of
`machineRole`. That means **every** machine — personal and ephemeral
included, not just `work` — needs a working age identity for `apply` to
succeed at all; `machineRole` only changes who ends up consuming the
decrypted values, not whether decryption happens.
