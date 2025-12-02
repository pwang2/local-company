#!/usr/bin/env bash

# https://kubernetes.io/docs/tasks/tls/managing-tls-in-a-cluster/
rm -rf cert
mkdir -p cert
cd cert || exit

echo "is cfssl installed?"
command -v cfssl || brew install cfssl

# Create a certificate signing request. add subdomains below
# output server-key.perm, server.csr
cat <<EOF | cfssl genkey - | cfssljson -bare server
{
  "hosts": [
    "ingress.local",
    "*.ingress.local",
    "registry.ingress.local",
    "argocd.ingress.local",
    "registry.gitlab.ingress.local",
    "kas.gitlab.ingress.local",
    "minio.gitlab.ingress.local",
    "gitlab.gitlab.ingress.local"
  ],
  "CN": "ingress.local",
  "key": {
    "algo": "ecdsa",
    "size": 256
  }
}
EOF

echo "Don't forget add those hosts in your /etc/hosts file"

# Generate a CSR manifest (in YAML), and send it to the API server
CSR=$(base64 -w 0 server.csr)

cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ingress.local
spec:
  request: ${CSR}
  signerName: ingress.local/serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

# Get the CertificateSigningRequest approved
kubectl certificate approve ingress.local

# create a signing certificate output ca.pem, ca-key.pem, ca.csr
cat <<EOF | cfssl gencert -initca - | cfssljson -bare ca
{
  "CN": "ingress.local/serving",
  "key": {
    "algo": "rsa",
    "size": 2048
  }
}
EOF

# generate signing config
cat <<EOF >server-signing-config.json
{
  "signing": {
    "default": {
      "usages": ["digital signature", "key encipherment", "server auth"],
      "expiry": "876000h",
      "ca_constraint": {
        "is_ca": false
      }
    }
  }
}
EOF

# Use signing configuration and the certificate authority key file and certificate to sign the certificate request:
# output ca-signed-server.csr, ca-signed-server.pem
kubectl get csr ingress.local -o jsonpath='{.spec.request}' |
  base64 --decode |
  cfssl sign -ca ca.pem -ca-key ca-key.pem -config server-signing-config.json - |
  cfssljson -bare ca-signed-server

# finally, populate the signed certificate in the API object's status:
certificate=$(base64 ca-signed-server.pem | tr -d '\n')
kubectl get csr ingress.local -o json |
  jq ".status.certificate = \"${certificate}\"" |
  kubectl replace --raw /apis/certificates.k8s.io/v1/certificatesigningrequests/ingress.local/status -f -

# Download the certificate and use it.
# Now, as the requesting user, you can download the issued certificate
# and save it to a server.crt file by running the following:
kubectl get csr ingress.local -o jsonpath='{.status.certificate}' | base64 --decode >server.crt

# Now you can populate server.crt and server-key.pem in a Secret that you could later mount into a Pod (for example, to use with a webserver that serves HTTPS).
kubectl delete secret --ignore-not-found=true -n argocd argocd-ingress-local
kubectl delete secret --ignore-not-found=true -n container-registry registry-ingress-local
kubectl delete secret --ignore-not-found=true -n gitlab-system gitlab-ingress-local
kubectl delete secret --ignore-not-found=true -n demo demo-ingress-local

kubectl create namespace argocd || true
kubectl create namespace container-registry || true
kubectl create namespace gitlab-system || true
kubectl create namespace demo || true

kubectl create secret tls -n argocd argocd-ingress-local --cert server.crt --key server-key.pem
kubectl create secret tls -n container-registry registry-ingress-local --cert server.crt --key server-key.pem
kubectl create secret tls -n gitlab-system gitlab-ingress-local --cert server.crt --key server-key.pem
kubectl create secret tls -n demo demo-ingress-local --cert server.crt --key server-key.pem

# populate ca.pem into a ConfigMap and use it as the trust root to verify the serving certificate:
kubectl delete configmap ingress-local-ca
kubectl create configmap ingress-local-ca --from-file ca.crt=ca.pem

# convert ca.pem to format can be install in window cert manager., use pfx for windows
openssl pkcs12 -inkey ca-key.pem -in ca.pem -export -out ca.pfx

# do this to allow tls when push to local registry
sudo cp server.crt /etc/docker/certs.d/registry.ingress.local/ca.crt
sudo cp server.crt /etc/docker/certs.d/registry.gitlab.ingress.local/ca.crt

# also remember to copy ca.pem content to argocd's tls certs store
# https://argocd.ingress.local/settings/certs
#
# for local git push to gitlab with self-cert, run
# git config http.sslCAInfo $(pwd)/ca.pem

helm repo add gitlab https://charts.gitlab.io
helm upgrade --install -n gitlab-system gitlab gitlab/gitlab \
  --set global.hosts.domain=ingress.local --set installCertmanager=false \
  --set global.ingress.configureCertmanager=false \
  --set gitlab-runner.install=false \
  --set global.ingress.tls.secretName=gitlab-ingress-local
helm upgrade --install -n gitlab-system -f gitlab-runner/values.yaml gitlab-runner

helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install -n argocd argo-cd argo/argo-cd

#kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

#use to get the root password for gitlab
#kubectl get secret gitlab-gitlab-initial-root-password -ojsonpath='{.data.password}' -n gitlab-system | base64 -d ; echo
