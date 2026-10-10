.PHONY: help staging-up staging-rebuild promote protect-prod netpol-check fire-drill
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

promote: ## fast-forward prod to master (GitHub's merge button cannot fast-forward; a merge commit would make prod diverge)
	@git fetch -q origin && git merge-base --is-ancestor origin/prod origin/master || { echo "prod is not an ancestor of master: refusing"; exit 1; }
	@gh pr create --base prod --head master --title "promote: master -> prod" \
	  --body "Promote everything verified on staging (master) to production (prod branch)." 2>/dev/null \
	  || true
	git push origin origin/master:prod
	@echo "prod now at $$(git rev-parse --short origin/master); GitHub marks the open promotion PR as merged"

protect-prod: ## one-time: prod branch accepts PRs only, no force-push, no deletion
	gh api -X PUT repos/nopsqi/homelab/branches/prod/protection \
	  -H "Accept: application/vnd.github+json" \
	  --input - <<< '{"required_pull_request_reviews":{"required_approving_review_count":0},"enforce_admins":false,"required_status_checks":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'

netpol-check: ## allowed-path NetworkPolicy checks on prod (ENV=staging for staging; cloudflared is skipped there)
	KUBECONFIG=$(if $(filter staging,$(ENV)),$(STAGING_KUBECONFIG),$(PROD_KUBECONFIG)) scripts/netpol-check.sh

fire-drill: ## prove ContainerRestarting fires (prod; staging has no Alertmanager)
	KUBECONFIG=$(PROD_KUBECONFIG) scripts/fire-drill.sh
