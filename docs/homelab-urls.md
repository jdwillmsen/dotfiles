# Homelab URL index

Every web UI in the homelab in one table, with where its login lives. Logins
are named by location (a Vault path or an encrypted file), never by value.
Vault paths are on the `kv` (v2) mount that the platform's `vault`
ClusterSecretStore reads, written as `kv/<key>` with the property after `#`.

URLs come from the HTTPRoute manifests in `jdwlabs/platform` and
`jdwillmsen/jdw-deployments`, and from `docs/proxmox-tls-certificates.md` in
`jdwlabs/infrastructure`. On 2026-11-27 every URL below answered from the
devbox (200, or 302/401 where a login sits in front). That only proves the LAN
and tailnet paths. Outside the LAN, `*.jdwlabs.com` resolves to the WAN address,
and whether a given UI answers there has not been checked.

| UI | URL | Login lives in | Network |
|---|---|---|---|
| Proxmox pve1 | `https://pve1.tail5bbd6f.ts.net:8006/` | **Unconfirmed.** The Proxmox credentials Terraform uses are in `terraform/terraform.tfvars.enc.yaml` (sops) in `jdwlabs/infrastructure`; whether the UI's own login is the same account is not recorded | tailnet |
| Proxmox pve2 | `https://pve2.tail5bbd6f.ts.net:8006/` | as pve1 (one cluster, one realm) | tailnet |
| Proxmox pve3 | `https://pve3.tail5bbd6f.ts.net:8006/` | as pve1 | tailnet |
| Proxmox pve4 | `https://pve4.tail5bbd6f.ts.net:8006/` | as pve1 | tailnet |
| Proxmox pve5 | `https://pve5.tail5bbd6f.ts.net:8006/` | as pve1 | tailnet |
| ArgoCD | `https://argocd.jdwlabs.com/` | GitHub (jdwlabs org) or Google through Dex; access is per-email in ArgoCD's policy. Fallback user `admin`: only its hash is stored, at `kv/argocd-dex#admin-password-hash`. **Where the plaintext lives is unconfirmed** | LAN |
| Grafana | `https://grafana.jdwlabs.com/` | `kv/grafana#admin-user` and `#admin-password` | LAN |
| Vault UI | `https://vault.jdwlabs.com/ui/` | Token. The root token is the in-cluster Secret `vault-init` (namespace `vault`), with a sops backup at `clusters/<name>/vault/vault-unseal.enc.yaml` in `jdwlabs/infrastructure`. **Other auth methods unconfirmed** | LAN |
| Headlamp (cluster dashboard) | `https://dashboard.jdwlabs.com/` | GitHub or Google through ArgoCD's Dex; cluster-admin per-email via the `headlamp-oidc-admin` ClusterRoleBinding | LAN |
| Alertmanager | `https://alertmanager.jdwlabs.com/` | basic auth; only the htpasswd hash is in `kv/alertmanager#htpasswd_string`. **Where the plaintext lives is unconfirmed** | LAN |
| Longhorn | `https://longhorn.jdwlabs.com/` | basic auth; only the htpasswd hash is in `kv/longhorn#htpasswd_string`. **Where the plaintext lives is unconfirmed** | LAN |
| DB UI | `https://dbui.jdwlabs.com/` | **Unconfirmed** | LAN |
| Crew console | `https://crew.prd.jdwlabs.com/` | none: a public, view-only console | public |
| FWB map | `https://fwb.prd.jdwlabs.com/` | an in-game login code, no stored credential | public |
| T3 Code, devbox | `https://devbox.tail5bbd6f.ts.net/` | device pairing: run `npx t3@latest pair --tailscale` on the box, in your own terminal ([t3code.md](t3code.md#3-pairing-a-device)) | tailnet |
| T3 Code, devbox2 | `https://devbox2.tail5bbd6f.ts.net/` | as devbox, run on devbox2 | tailnet |

Proxmox is also on each host's LAN address, but that path serves the cluster's
self-signed certificate and fails a hostname check. Use the tailnet names.

A new UI belongs here once its route merges, with its login location and
**unconfirmed** on anything not checked.
