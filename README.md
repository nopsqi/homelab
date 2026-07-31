# homelab

Infrastructure for a single Hetzner CX33 (4 vCPU, 8GB) running K3s. Terraform provisions the server, Ansible configures it, ArgoCD deploys everything else from this repo.

Currently running 10 apps on one node at ~73% memory.

## Services

| URL | What |
|---|---|
| https://nopsqi.dev | Astro site |
| https://naila.nopsqi.dev | Discord bot + web console |
| https://actual.nopsqi.dev | Actual Budget |
| https://minio.nopsqi.dev | Minio S3 API |
| https://minio-console.nopsqi.dev | Minio console (Cloudflare Access) |
| https://argocd.nopsqi.dev | ArgoCD (Cloudflare Access) |
| https://grafana.nopsqi.dev | Grafana (Cloudflare Access) |

Also running without a public URL: Prometheus, Loki, Alloy, Alertmanager (→ Discord), Sealed Secrets, cloudflared, and Restic backup CronJobs.

## Stack

| Layer | Tool |
|---|---|
| Provisioning | Terraform, state on HCP Terraform Cloud |
| Configuration | Ansible, one inventory per environment |
| Orchestration | K3s |
| Packaging | Helm, layered values files |
| GitOps | ArgoCD, App of Apps |
| CI/CD | GitHub Actions (in the app repos, not here) |
| CNI | Calico |
| Networking | Tailscale for SSH, Cloudflare Tunnel for public traffic |
| Observability | Prometheus, Grafana, Loki, Alloy, Alertmanager |
| Secrets | Sealed Secrets |
| Backups | Restic → Cloudflare R2 |

## Networking

No inbound ports are open. The Hetzner firewall has zero rules, which is the mechanism — Hetzner treats an inbound direction with no rules as deny-all.

- **SSH** goes over Tailscale.
- **Public traffic** arrives through a Cloudflare tunnel that the cluster dials outward. `cloudflared` routes each hostname straight to a ClusterIP Service, so there's no ingress controller — Traefik is disabled in K3s.
- **Admin UIs** (ArgoCD, Grafana, Minio console) sit behind Cloudflare Access.
- **Inside the cluster**, Calico enforces per-namespace NetworkPolicies. Calico rather than Cilium because Cilium had host-network routing problems on K3s that broke the tunnel.

## Deployments

ArgoCD watches this repo. The `root` Application points at `argocd/prod/`, which contains one Application manifest per service, each pointing at a chart in `helm/`. Adding a service is committing one file to `argocd/prod/`; removing one is deleting it.

Every app syncs with `prune: true` and `selfHeal: true`, so manual `kubectl edit` gets reverted. PVCs carry `argocd.argoproj.io/sync-options: Delete=false` so pruning can't take the data with it.

Charts use layered values: `values.yaml` for shared defaults, plus `values.prod.yaml` or `values.staging.yaml`. The ArgoCD Application picks which layers apply.

For the two apps I build myself (astro, naila), GitHub Actions builds the image, tags it `sha-<commit>`, signs it with cosign, commits the new tag to `values.staging.yaml`, then opens a PR to bump `values.prod.yaml`. Staging deploys on merge to the app repo; production deploys when I merge the promotion PR.

## Bootstrap

```bash
terraform apply
ansible-playbook -i inventories/production playbook.yml
```

The playbook installs Tailscale, K3s and Calico, deploys ArgoCD, creates the `homelab-repo` secret, applies the root App of Apps, and restores the Sealed Secrets controller key. Everything else arrives through ArgoCD.

Two files must exist beforehand and are not in the repo:

- `ansible/secrets/argocd-homelab` — ArgoCD deploy key
- `helm/sealed-secrets/sealed-secrets-prod-backup.yaml` — Sealed Secrets controller key backup

Tailscale also needs authenticating manually; the role installs it but doesn't run `tailscale up`.

## Secrets

Application secrets are encrypted with Sealed Secrets and committed to this repo. They're only decryptable by the controller running in the cluster, which is why the controller key backup matters — without it, a rebuilt cluster can't read any of them.

`homelab-repo` (the SSH deploy key ArgoCD uses to read this repo) can't be managed this way, since ArgoCD needs it before it can sync anything. Ansible applies it during bootstrap.

## Backups

Restic CronJobs back up Actual and Minio to Cloudflare R2 daily at 02:00 UTC. Encrypted client-side, incremental, 7 daily + 4 weekly retained. Actual's job runs `sqlite3 .backup` before archiving, since copying a live SQLite file can produce something that won't restore.

Restore Jobs exist for both apps but are disabled by default. Triggering one is manual, outside GitOps:

```bash
helm template actual ./helm/actual -f helm/actual/values.prod.yaml \
  --set restore.enabled=true --set restore.snapshotId=<id> | kubectl apply -f -
```

It scales the deployment down, restores the snapshot, and scales it back up. The Job runs with a scoped ServiceAccount, Role and NetworkPolicy that need deleting afterwards.

## Staging

A local Vagrant/libvirt VM (Debian 12, 4 vCPU, 8GB) at `192.168.56.10`. Same playbook, same charts, different inventory and values.

```bash
cd vagrant && vagrant up
cd ansible && ansible-playbook -i inventories/staging playbook.yml
```

Known differences from production: no cloudflared, so NetworkPolicy rules that allow traffic from the tunnel aren't exercised. Alertmanager is disabled. Prometheus storage is ephemeral. Smaller PVCs.

## Layout

```
terraform/              server, firewall, SSH key
ansible/
  playbook.yml          assigns roles to hosts
  roles/                common, tailscale, k3s, calico, argocd
  inventories/          production/ and staging/
  secrets/              gitignored
helm/                   one chart per app
  <app>/                values.yaml + values.{prod,staging}.yaml + templates/
argocd/
  prod/                 Application manifests; root.yaml watches this directory
  staging/              same, without cloudflared
vagrant/                staging VM definition
```

## Known gaps

- Images are signed but nothing verifies signatures at admission.
- Single node, one replica each. All PVCs are `local-path`, so a second node wouldn't let workloads move.
- CI opens the production PR immediately after pushing to staging, so staging-then-promote is a convention rather than something the pipeline enforces.
- DNS records, the Cloudflare tunnel, the R2 bucket and Access policies are configured by hand, not in Terraform.
