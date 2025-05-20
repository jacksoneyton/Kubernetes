#!/bin/bash

# Show banner
cat <<'EOF'
[34;5m __  __     __    ____              ____                    ___                       
[31;5m/\ \/\ \  /'__`\ /\  _`\           /\  _`\                 /\_ \                      
[34;5m\ \ \/'/'/\_\L\ \\ \,\L\_\         \ \ \/\ \     __   _____\//\ \     ___   __  __    
[31;5m \ \ , < \/_/_\_<_\/_\__ \   _______\ \ \ \ \  /'__`\/\ '__`\\ \ \   / __`\/\ \/\ \   
[34;5m  \ \ \\`\ /\ \L\ \ /\ \L\ \/\______\\ \ \_\ \/\  __/\ \ \L\ \\_\ \_/\ \L\ \ \ \_\ \  
[31;5m   \ \_\ \_\ \____/ \ `\____\/______/ \ \____/\ \____\\ \ ,__//\____\ \____/\/`____ \ 
[34;5m    \/_/\/_/\/___/   \/_____/          \/___/  \/____/ \ \ \/ \/____/\/___/  `/___/> \
[31;5m                                                        \ \_\                   /\___/
[34;5m                                                         \/_/                   \/__/ 
[0m
EOF

#############################################
# YOU SHOULD ONLY NEED TO EDIT THIS SECTION #
#############################################
KVVERSION="v0.6.3"
k3sVersion="v1.26.10+k3s2"
master1=192.168.13.20
master2=192.168.13.21
master3=192.168.13.22
worker1=192.168.13.23
worker2=192.168.13.24
user=root
interface=eth0
vip=192.168.13.25
masters=($master2 $master3)
workers=($worker1 $worker2)
all=($master1 $master2 $master3 $worker1 $worker2)
lbrange=192.168.13.30-192.168.3.49
certName=id_rsa
config_file="$HOME/.ssh/config"

#############################################
#            DO NOT EDIT BELOW              #
#############################################

# Sync time
sudo timedatectl set-ntp off && sudo timedatectl set-ntp on

# Setup SSH certs
mkdir -p ~/.ssh
cp "/home/$user/{$certName,$certName.pub}" ~/.ssh/
chmod 600 ~/.ssh/$certName
chmod 644 ~/.ssh/$certName.pub

# Install k3sup if not installed
if ! command -v k3sup &>/dev/null; then
    echo -e "\033[31;5mk3sup not found, installing\033[0m"
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
else
    echo -e "\033[32;5mk3sup already installed\033[0m"
fi

# Install kubectl if not installed
if ! command -v kubectl &>/dev/null; then
    echo -e "\033[31;5mKubectl not found, installing\033[0m"
    curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo -e "\033[32;5mKubectl already installed\033[0m"
fi

# Configure SSH to disable StrictHostKeyChecking (dev only)
if [ ! -f "$config_file" ]; then
    echo "StrictHostKeyChecking no" > "$config_file"
    chmod 600 "$config_file"
else
    grep -q "^StrictHostKeyChecking" "$config_file" \
        && sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$config_file" \
        || echo "StrictHostKeyChecking no" >> "$config_file"
fi

# Copy SSH key to all nodes
for node in "${all[@]}"; do
    ssh-copy-id "$user@$node"
done

# Install policycoreutils on all nodes
for node in "${all[@]}"; do
    ssh -i ~/.ssh/$certName "$user@$node" 'NEEDRESTART_MODE=a apt-get install -y policycoreutils'
    echo -e "\033[32;5mPolicyCoreUtils installed on $node!\033[0m"
done

# Bootstrap first master
mkdir -p ~/.kube
k3sup install \
    --ip "$master1" \
    --user "$user" \
    --tls-san "$vip" \
    --cluster \
    --k3s-version "$k3sVersion" \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$master1 --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --merge \
    --sudo \
    --local-path "$HOME/.kube/config" \
    --ssh-key "$HOME/.ssh/$certName" \
    --context k3s-ha
echo -e "\033[32;5mFirst Node bootstrapped!\033[0m"

# Apply kube-vip RBAC
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml

# Download and configure kube-vip manifest
curl -sO https://raw.githubusercontent.com/jacksoneyton/Kubernetes/refs/heads/main/K3S-Deploy/kube-vip
sed "s/\$interface/$interface/g; s/\$vip/$vip/g" kube-vip > ~/kube-vip.yaml

# Transfer kube-vip.yaml to master1
scp -i ~/.ssh/$certName ~/kube-vip.yaml "$user@$master1:~/"

ssh -i ~/.ssh/$certName "$user@$master1" <<EOF
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests
  sudo mv kube-vip.yaml /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
EOF

# Join additional masters
for node in "${masters[@]}"; do
  k3sup join \
    --ip "$node" \
    --user "$user" \
    --sudo \
    --k3s-version "$k3sVersion" \
    --server \
    --server-ip "$master1" \
    --ssh-key "$HOME/.ssh/$certName" \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$node --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --server-user "$user"
  echo -e "\033[32;5mMaster node $node joined!\033[0m"
done

# Join worker nodes
for node in "${workers[@]}"; do
  k3sup join \
    --ip "$node" \
    --user "$user" \
    --sudo \
    --k3s-version "$k3sVersion" \
    --server-ip "$master1" \
    --ssh-key "$HOME/.ssh/$certName" \
    --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""
  echo -e "\033[32;5mWorker node $node joined!\033[0m"
done

# Deploy kube-vip cloud controller
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml

# Deploy MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Configure IP pool
curl -sO https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/ipAddressPool
sed "s/\$lbrange/$lbrange/g" ipAddressPool > ~/ipAddressPool.yaml
kubectl apply -f ~/ipAddressPool.yaml

# Test with Nginx
kubectl apply -f https://raw.githubusercontent.com/inlets/inlets-operator/master/contrib/nginx-sample-deployment.yaml -n default
kubectl expose deployment nginx-1 --port=80 --type=LoadBalancer -n default

echo -e "\033[32;5mWaiting for Nginx pod readiness...\033[0m"
until [[ $(kubectl get pods -l app=nginx -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}") == "True" ]]; do
    sleep 1
done

# Wait for MetalLB controller and apply L2Advertisement
kubectl wait --namespace metallb-system --for=condition=ready pod --selector=component=controller --timeout=120s
kubectl apply -f ~/ipAddressPool.yaml
kubectl apply -f https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/K3S-Deploy/l2Advertisement.yaml

kubectl get nodes
kubectl get svc
kubectl get pods --all-namespaces -o wide

echo -e "\033[32;5m🎉 Happy Kubing! Access Nginx at the EXTERNAL-IP above 🎉\033[0m"
