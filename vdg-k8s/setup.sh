#!/bin/bash
set -e

# 1. Create a k3d cluster with a load balancer on ports 80 and 443
# Check if the cluster 'vdg-k8s' exists. If not, create it.
if ! k3d cluster get vdg-k8s >/dev/null 2>&1; then
  echo ">>> Creating k3d cluster 'vdg-k8s'..."
  k3d cluster create vdg-k8s --api-port 6443 -p "80:80@loadbalancer" -p "443:443@loadbalancer" --wait
else
  echo ">>> k3d cluster 'vdg-k8s' already exists, skipping creation."
fi

echo ">>> k3d cluster created successfully."

# 1.1 Apply Traefik Dashboard Ingress
echo ">>> Applying Traefik dashboard configuration..."
kubectl apply -f traefik-dashboard-ingress.yaml

# 2. Add Helm repositories
echo ">>> Adding Helm repositories..."
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 3. Install Gitea
echo ">>> Installing Gitea..."
helm upgrade --install gitea gitea-charts/gitea --version 12.4.0 \
  -n gitea --create-namespace \
  -f gitea-values.yaml --wait

# 4. Install ArgoCD
echo ">>> Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f argocd-values.yaml --wait

# 5. Install TeamCity
echo ">>> Installing TeamCity..."

# Wir verwenden den Community-Chart, der Server und Agent getrennt installiert.
# Zuerst der Server:
helm upgrade --install teamcity-server teamcity-charts/teamcity-server \
  -n teamcity --create-namespace -f teamcity-values.yaml --wait --timeout 15m
# Dann der Agent:
helm upgrade --install teamcity-agent teamcity-charts/teamcity-agent \
  -n teamcity --create-namespace -f teamcity-values.yaml --wait --timeout 15m

# 6. Install Prometheus and Grafana
echo ">>> Installing Prometheus and Grafana..."
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f prometheus-values.yaml --wait

echo ">>> Setup complete!"
echo ">>> Gitea should be available at http://gitea.localhost"
echo ">>> ArgoCD should be available at http://argocd.localhost"
echo ">>> Traefik dashboard should be available at http://traefik.localhost"
echo ">>> TeamCity should be available at http://teamcity.localhost"
echo ">>> Prometheus should be available at http://prometheus.localhost"
echo ">>> Grafana should be available at http://grafana.localhost (Login: admin/password)"
echo ">>> You can get the ArgoCD initial admin password with:"
echo "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
kubectl patch ingress argocd-server -n argocd --type='json' -p='[{"op": "replace", "path": "/spec/rules/0/host", "value":"argocd.localhost"}]'
