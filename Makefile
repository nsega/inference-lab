CLUSTER := inference-lab
NS := inference-lab
KCTL := kubectl --context kind-$(CLUSTER) -n $(NS)
GATEWAY_URL := http://localhost:30080
PROM_URL := http://localhost:30090

IMAGES := \
	ghcr.io/llm-d/llm-d-inference-sim:v0.9.2 \
	ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0 \
	envoyproxy/envoy:distroless-v1.33.2 \
	prom/prometheus:v3.4.1 \
	python:3.12-alpine

.PHONY: up down load load-stop inject reset status smoke pull-images

## up: create cluster, load images, deploy backends + EPP gateway + prometheus
up: pull-images
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || \
		kind create cluster --config manifests/kind-config.yaml --wait 120s
	@# kind load docker-image is broken with Docker's containerd image store
	@# (multi-arch digest error) -> save per-platform archive and load that.
	@for img in $(IMAGES); do \
		f=/tmp/$$(echo $$img | tr '/:' '__').tar; \
		docker save --platform linux/arm64 $$img -o $$f && \
		kind load image-archive --name $(CLUSTER) $$f && rm -f $$f; \
	done
	kubectl --context kind-$(CLUSTER) apply -f manifests/crds/gie-crds-v1.5.0.yaml
	kubectl --context kind-$(CLUSTER) create namespace $(NS) --dry-run=client -o yaml | \
		kubectl --context kind-$(CLUSTER) apply -f -
	$(KCTL) apply -f manifests/backends.yaml -f manifests/prometheus.yaml
	$(KCTL) create configmap epp-config --from-file=config.yaml=manifests/epp-config.yaml \
		--dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) apply -f manifests/epp.yaml
	$(KCTL) wait --for=condition=available --timeout=300s \
		deploy/backend-0 deploy/backend-1 deploy/backend-2 deploy/prometheus deploy/epp
	@mkdir -p lab/state && rm -f lab/state/fault.json
	@echo "gateway:    $(GATEWAY_URL)"
	@echo "prometheus: $(PROM_URL)"

## down: delete the whole cluster
down:
	kind delete cluster --name $(CLUSTER) || true
	@rm -f lab/state/fault.json

## pull-images: pre-pull all images to the host docker cache
pull-images:
	@for img in $(IMAGES); do docker pull -q $$img; done

## load: start the in-cluster load generator
load:
	$(KCTL) create configmap loadgen-script --from-file=load/loadgen.py \
		--dry-run=client -o yaml | $(KCTL) apply -f -
	$(KCTL) apply -f manifests/loadgen.yaml
	$(KCTL) rollout restart deploy/loadgen
	$(KCTL) wait --for=condition=available --timeout=120s deploy/loadgen
	@echo "load running; tail with: kubectl -n $(NS) logs -f deploy/loadgen"

load-stop:
	$(KCTL) delete deploy/loadgen --ignore-not-found

## inject: make inject FAULT=s1|s2|s3
inject:
	@test -n "$(FAULT)" || (echo "usage: make inject FAULT=s1|s2|s3" && exit 1)
	./scripts/inject.sh $(FAULT)

## reset: restore healthy configuration and clear ground-truth state
reset:
	./scripts/reset.sh

## smoke: one OpenAI-style request through the gateway
smoke:
	curl -sf -X POST $(GATEWAY_URL)/v1/chat/completions \
	  -H 'Content-Type: application/json' \
	  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"ping"}]}' \
	  | python3 -m json.tool

status:
	@$(KCTL) get pods -o wide
	@echo "--- fault state:"; cat lab/state/fault.json 2>/dev/null || echo "(healthy — no fault injected)"
