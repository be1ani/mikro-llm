CLUSTER_NAME ?= mikro-llm
LOCAL_PORT   ?= 8888

.PHONY: up down forward status argocd-password

up:
	./up.sh

down:
	kind delete cluster --name $(CLUSTER_NAME)

forward:
	@SVC=$$(kubectl -n envoy-gateway-system get svc \
	  -l gateway.envoyproxy.io/owning-gateway-name=llm-gateway \
	  -o jsonpath='{.items[0].metadata.name}'); \
	echo "Forwarding $$SVC -> localhost:$(LOCAL_PORT)"; \
	kubectl -n envoy-gateway-system port-forward svc/$$SVC $(LOCAL_PORT):80

status:
	kubectl -n argocd get applications
	kubectl -n llm-models get pods,pvc
	kubectl -n envoy-gateway-system get gateway,svc

argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo
