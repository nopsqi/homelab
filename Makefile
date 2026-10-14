.PHONY: help staging-up staging-rebuild promote protect-prod sealed-keys-backup netpol-check fire-drill
STAGING_KUBECONFIG ?= $(HOME)/.kube/staging-config
PROD_KUBECONFIG    ?= $(HOME)/.kube/config

help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

staging-up: ## boot the staging VM
	cd vagrant && vagrant up

staging-rebuild: ## destroy and rebuild staging from scratch, then wait for the root app
	cd vagrant && vagrant destroy -f && vagrant up
	chmod 600 vagrant/.vagrant/machines/default/libvirt/private_key
	cd ansible && ansible-playbook -i inventories/staging playbook.yml
	@echo "fetching fresh kubeconfig (rebuild regenerates the k3s CA)"; \
	  cd vagrant && vagrant ssh -c 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>/dev/null | sed 's#https://127.0.0.1:6443#https://192.168.56.10:6443#' > $(STAGING_KUBECONFIG)
	@echo "waiting for root app"; for i in $$(seq 1 60); do \
	  s=$$(KUBECONFIG=$(STAGING_KUBECONFIG) kubectl -n argocd get application root -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null); \
	  echo "  $$s"; [ "$$s" = "Synced/Healthy" ] && exit 0; sleep 20; done; echo "root app not healthy"; exit 1

promote: ## merge the open master -> prod PR with a merge commit (opens it first if CI has not); never squash
	@git fetch -q origin && git merge-base --is-ancestor origin/prod origin/master || { echo "prod has commits master lacks: refusing (was a PR squashed/rebased? merge prod into master first)"; exit 1; }
	@gh pr create --base prod --head master --title "promote: master -> prod" \
	  --body "Promote everything verified on staging (master) to production (prod branch)." 2>/dev/null || true
	gh pr merge --merge --repo nopsqi/homelab $$(gh pr list --repo nopsqi/homelab --base prod --head master --state open --json number -q '.[0].number')
	@git fetch -q origin && echo "prod now at $$(git rev-parse --short origin/prod)"

protect-prod: ## one-time: prod branch accepts PRs only, no force-push, no deletion
	gh api -X PUT repos/nopsqi/homelab/branches/prod/protection \
	  -H "Accept: application/vnd.github+json" \
	  --input - <<< '{"required_pull_request_reviews":{"required_approving_review_count":0},"enforce_admins":false,"required_status_checks":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'

sealed-keys-backup: ## export every sealed-secrets key from both clusters into the (git-ignored, mode 600) backup files
	@git check-ignore -q helm/sealed-secrets/sealed-secrets-prod-backup.yaml || { echo "backup path is not git-ignored: refusing"; exit 1; }
	umask 077; KUBECONFIG=$(PROD_KUBECONFIG)    kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > helm/sealed-secrets/sealed-secrets-prod-backup.yaml
	umask 077; KUBECONFIG=$(STAGING_KUBECONFIG) kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > helm/sealed-secrets/sealed-secrets-staging-backup.yaml
	chmod 600 helm/sealed-secrets/sealed-secrets-*-backup.yaml
	@grep -c tls.key helm/sealed-secrets/sealed-secrets-prod-backup.yaml | sed 's/^/prod keys: /'; grep -c tls.key helm/sealed-secrets/sealed-secrets-staging-backup.yaml | sed 's/^/staging keys: /'

netpol-check: ## allowed-path NetworkPolicy checks on prod (ENV=staging for staging; cloudflared is skipped there)
	KUBECONFIG=$(if $(filter staging,$(ENV)),$(STAGING_KUBECONFIG),$(PROD_KUBECONFIG)) scripts/netpol-check.sh

fire-drill: ## prove ContainerRestarting fires (prod; staging has no Alertmanager)
	KUBECONFIG=$(PROD_KUBECONFIG) scripts/fire-drill.sh
