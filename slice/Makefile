# One command up, one down, one to prove it. CASE= runs a single verify case.
.PHONY: create verify destroy render

create:
	./create.sh

verify:
	./verify.sh $(CASE)

destroy:
	./destroy.sh

# Render every tenant without a cluster. Fails on a spec the schema rejects.
render:
	@bash -c 'set -eo pipefail; source ./lib.sh; for spec in tenants/*.yaml; do \
	  helm template "$$(basename $$spec .yaml)" chart -f "$$spec" >/dev/null; echo "ok  $$spec"; done'
