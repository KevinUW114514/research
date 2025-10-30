sudo swapoff -a
sudo sed -ri 's/^[^#]*swap/#&/' /etc/fstab

# kernel modules for containers + kube networking
cat << 'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctls
cat << 'EOF' | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo sysctl --system


sudo apt-get update
sudo apt install net-tools -y
sudo apt-get install -y containerd
# Create default config and switch to systemd cgroups
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd


# Add Kubernetes apt repo
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# bash completion (helpful!)
sudo apt-get install -y bash-completion
echo 'source <(kubectl completion bash)' >>~/.bashrc
source ~/.bashrc

# manager
# Kubernetes control-plane
sudo firewall-cmd --add-port=6443/tcp --permanent         # API server
sudo firewall-cmd --add-port=2379-2380/tcp --permanent    # etcd
sudo firewall-cmd --add-port=10250/tcp --permanent        # kubelet
sudo firewall-cmd --add-port=10257/tcp --permanent        # kube-controller-manager
sudo firewall-cmd --add-port=10259/tcp --permanent        # kube-scheduler
sudo firewall-cmd --add-port=5473/tcp --permanent        # kube-scheduler
sudo firewall-cmd --add-port=2049/tcp --permanent        # nfs

# Optional: NodePort range for services you expose that way
sudo firewall-cmd --add-port=30000-32767/tcp --permanent

# CNI-dependent (pick what matches your plugin)
# Calico (VXLAN default): 
sudo firewall-cmd --add-port=4789/udp --permanent         # VXLAN
# If using Calico BGP mode instead of VXLAN:
# sudo firewall-cmd --add-port=179/tcp --permanent

# Flannel (VXLAN):
sudo firewall-cmd --add-port=8472/udp --permanent

sudo firewall-cmd --set-default-zone=public
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --zone=public --change-interface=eno1np0 --permanent

sudo firewall-cmd --reload
sudo firewall-cmd --list-all-zones


# worker:
sudo firewall-cmd --add-port=10250/tcp --permanent
sudo firewall-cmd --add-port=30000-32767/tcp --permanent   # NodePort (optional)

# Match your CNI choice:
# Calico VXLAN:
sudo firewall-cmd --add-port=4789/udp --permanent
# Flannel VXLAN:
sudo firewall-cmd --add-port=8472/udp --permanent
sudo firewall-cmd --zone=public --change-interface=enp161s0f0 --permanent

sudo firewall-cmd --reload
sudo firewall-cmd --list-all-zones


# On k8s-mgr
sudo kubeadm init \
  --pod-network-cidr=10.114.0.0/16 \
  --apiserver-advertise-address=$(hostname -I | awk '{print $1}')
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# test
kubectl get nodes

kubectl -n calico-system patch deploy calico-kube-controllers --type='json' -p='[
 {"op":"add","path":"/spec/template/spec/tolerations","value":[
   {"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"},
   {"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}
 ]}
]'
kubectl -n calico-system patch deploy calico-typha --type='json' -p='[
 {"op":"add","path":"/spec/template/spec/tolerations","value":[
   {"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"},
   {"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}
 ]}
]'

# Replace kevin-intel-manager if your node name differs
kubectl -n calico-system patch deploy calico-kube-controllers -p '{
  "spec":{"template":{"spec":{
    "affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[
      {"weight":100,
       "preference":{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["kevin-intel-manager"]}]}}
    ]}}
  }}}
}'

kubectl -n calico-system patch deploy calico-typha -p '{
  "spec":{"template":{"spec":{
    "affinity":{"nodeAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[
      {"weight":100,
       "preference":{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["kevin-intel-manager"]}]}}
    ]}}
  }}}
}'

kubectl -n calico-system rollout restart deploy/calico-kube-controllers
kubectl -n calico-system rollout restart deploy/calico-typha


# CNI (Container Network Interface), manager only
kubectl create -f https://docs.tigera.io/manifests/tigera-operator.yaml
kubectl apply  -f calico-vxlan.yaml

kubectl -n calico-system get pods -o wide
kubectl get nodes -o wide

# create token on manager
kubeadm token create --print-join-command

# join workers
sudo kubeadm join <CONTROL_PLANE_IP>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>

sudo kubeadm join 10.52.2.226:6443 --token yw9st9.4ucool0bcphkyg1m \
        --discovery-token-ca-cert-hash sha256:20c306f4c684f7f502ee3fb396e42aab0f18a7fc7a3221aa937665b2f0b53a6d 

# mgr smoke test
kubectl get nodes
kubectl get pods -A

sudo mkdir -p /srv/nfs/k8s
# Give your app's UID/GID or just open up initially for testing
sudo chown 1000:1000 /srv/nfs/k8s    # adjust to your app UID/GID
# Install NFS server
# Ubuntu/Debian:
sudo apt-get update && sudo apt-get install -y nfs-kernel-server
# RHEL/CentOS/Rocky:
# sudo dnf install -y nfs-utils && sudo systemctl enable --now nfs-server

# Export the path (all cluster nodes allowed). Harden as desired.
echo "/srv/nfs/k8s *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports
sudo exportfs -ra

kubectl apply -f storage.yaml

kubectl get pv
kubectl get pvc

kubectl apply -f pvc-test.yaml
kubectl get pods -o wide
kubectl get pods


wget https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz
tar -xzvf helm-v3.19.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
helm version
rm -rf helm-v4.0.0-beta.2-linux-amd64.tar.gz linux-amd64

helm repo add openwhisk https://openwhisk.apache.org/charts
helm repo update

sudo mkdir -p /opt/local-path-provisioner
sudo chmod 777 /opt/local-path-provisioner   # quick unblock; tighten later

kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml

kubectl -n local-path-storage rollout restart deploy/local-path-provisioner
kubectl -n local-path-storage rollout status deploy/local-path-provisioner

kubectl -n local-path-storage get pods

kubectl apply -f pvc-test.yaml
kubectl get pvc pvc-test       # should show STATUS=Bound
kubectl exec -it pvc-tester -- cat /data/hello

