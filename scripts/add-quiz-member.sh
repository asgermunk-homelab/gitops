#!/usr/bin/env bash
# Gives one person kubectl access to the namespace quiz (and nothing else).
#
# The person makes their own key, so the private key never leaves their PC:
#   openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
#     -keyout <name>.key -out <name>.csr -subj "/CN=<name>/O=quiz-developers"
# They send you <name>.csr (not the .key). You run:
#   ./add-quiz-member.sh <name> <name>.csr
# and send back <name>.kubeconfig. They put it next to <name>.key and run:
#   kubectl --kubeconfig <name>.kubeconfig get pods
#
# Revoke: k3s has no certificate revocation. Delete the RoleBinding subject
# or remove the person from the Tailscale group. The certificate expires
# after EXPIRY_SECONDS anyway.
set -euo pipefail

NAME="${1:?usage: add-quiz-member.sh <name> <csr-file>}"
CSR_FILE="${2:?usage: add-quiz-member.sh <name> <csr-file>}"
CONTEXT="${CONTEXT:-homelab}"
EXPIRY_SECONDS="${EXPIRY_SECONDS:-15552000}"   # 180 days: past the exam

[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "Name must be lowercase letters, digits, dashes."; exit 1; }

# The group (O=) decides the rights. Accept exactly CN=<name>, O=quiz-developers,
# so nobody can sneak in O=system:masters (= cluster-admin).
SUBJECT=$(openssl req -in "$CSR_FILE" -noout -subject -nameopt RFC2253)
EXPECTED="subject=O=quiz-developers,CN=$NAME"
if [[ "$SUBJECT" != "$EXPECTED" ]]; then
  echo "Wrong CSR subject: $SUBJECT"
  echo "Expected:          $EXPECTED"
  exit 1
fi

CSR_NAME="quiz-$NAME"
kubectl --context "$CONTEXT" delete csr "$CSR_NAME" --ignore-not-found
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $CSR_NAME
spec:
  request: $(base64 -w0 < "$CSR_FILE")
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $EXPIRY_SECONDS
  usages: [client auth]
EOF
kubectl --context "$CONTEXT" certificate approve "$CSR_NAME"

for _ in $(seq 1 20); do
  CERT=$(kubectl --context "$CONTEXT" get csr "$CSR_NAME" -o jsonpath='{.status.certificate}')
  [[ -n "$CERT" ]] && break
  sleep 1
done
[[ -n "$CERT" ]] || { echo "The certificate was not issued."; exit 1; }

SERVER=$(kubectl --context "$CONTEXT" config view --raw -o jsonpath="{.clusters[?(@.name==\"$CONTEXT\")].cluster.server}")
CA=$(kubectl --context "$CONTEXT" config view --raw -o jsonpath="{.clusters[?(@.name==\"$CONTEXT\")].cluster.certificate-authority-data}")

cat > "$NAME.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: $SERVER
      certificate-authority-data: $CA
users:
  - name: $NAME
    user:
      client-certificate-data: $CERT
      client-key: $NAME.key
contexts:
  - name: quiz
    context:
      cluster: homelab
      user: $NAME
      namespace: quiz
current-context: quiz
EOF

kubectl --context "$CONTEXT" delete csr "$CSR_NAME"
echo "Wrote $NAME.kubeconfig. Send it to $NAME (it holds no private key)."
