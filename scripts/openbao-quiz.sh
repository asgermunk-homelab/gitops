#!/usr/bin/env bash
# Sets up OpenBao for the quiz tenant. Runs on the PROXMOX HOST and calls bao
# inside the OpenBao LXC (102) with pct exec. The LXC has no openssl or
# ssh-keygen, so the host makes the passwords and the deploy key.
#
# First log in inside the LXC (pct enter 102, then bao login ... username=asger).
# Then, from the PC:
#   ssh pve 'bash -s' < openbao-quiz.sh
#
# What it does (same pattern as the other namespaces, see the note OpenBao.md):
#   - policy quiz-read: read kv/data/quiz/*, list kv/metadata/quiz/*
#   - Kubernetes auth role quiz: ServiceAccount openbao in the namespace quiz
#   - random hex passwords for Postgres, Redis and RabbitMQ
#   - the SSH deploy key that Flux uses for 6-sem-musik-quiz/gitops
#
# Secrets go to bao over stdin (never as command arguments) or as a file in
# RAM (/dev/shm) that is deleted at once. Only the PUBLIC deploy key is printed.
# Safe to run again: it never replaces an existing secret, because Postgres
# only reads the passwords on its first start.
set -euo pipefail

CT=102
bao() {
  pct exec "$CT" -- env BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/opt/openbao/tls/ca.crt bao "$@"
}
exists() { bao kv get "kv/$1" >/dev/null 2>&1; }
pw() { openssl rand -hex 24; }

for tool in openssl ssh-keygen ssh-keyscan pct; do
  command -v "$tool" >/dev/null || { echo "Missing on the host: $tool"; exit 1; }
done
bao token lookup >/dev/null 2>&1 || {
  echo "Not logged in. In the LXC: bao login -no-print -method=userpass username=asger"; exit 1; }

echo "== policy quiz-read"
bao policy write quiz-read - <<'EOF'
path "kv/data/quiz/*" {
  capabilities = ["read"]
}
path "kv/metadata/quiz/*" {
  capabilities = ["read", "list"]
}
EOF

echo "== role quiz"
bao write auth/kubernetes/role/quiz \
  bound_service_account_names=openbao \
  bound_service_account_namespaces=quiz \
  audience=openbao \
  token_policies=quiz-read \
  token_ttl=1h token_max_ttl=4h

echo "== kv/quiz/postgres"
if exists quiz/postgres; then echo "exists, kept"; else
  printf '{"postgres-password":"%s","userservice":"%s","lobbyservice":"%s","gameservice":"%s","musicservice":"%s","statisticservice":"%s"}' \
    "$(pw)" "$(pw)" "$(pw)" "$(pw)" "$(pw)" "$(pw)" | bao kv put kv/quiz/postgres - >/dev/null
  echo "created"
fi

echo "== kv/quiz/redis"
if exists quiz/redis; then echo "exists, kept"; else
  printf '{"password":"%s"}' "$(pw)" | bao kv put kv/quiz/redis - >/dev/null
  echo "created"
fi

echo "== kv/quiz/rabbitmq"
if exists quiz/rabbitmq; then echo "exists, kept"; else
  printf '{"username":"quiz","password":"%s"}' "$(pw)" | bao kv put kv/quiz/rabbitmq - >/dev/null
  echo "created"
fi

echo "== kv/quiz/flux-deploy-key"
if exists quiz/flux-deploy-key; then
  echo "exists, kept. Public key:"
  bao kv get -field=identity.pub kv/quiz/flux-deploy-key; echo
else
  host_tmp=$(mktemp -d /dev/shm/quiz-key.XXXXXX)
  ct_tmp=/dev/shm/quiz-key
  cleanup() { rm -rf "$host_tmp"; pct exec "$CT" -- rm -rf "$ct_tmp" 2>/dev/null || true; }
  trap cleanup EXIT

  ssh-keygen -q -t ed25519 -N "" -C flux-quiz -f "$host_tmp/key"
  ssh-keyscan -t ed25519,ecdsa,rsa github.com > "$host_tmp/known_hosts" 2>/dev/null
  [ -s "$host_tmp/known_hosts" ] || { echo "ssh-keyscan github.com failed"; exit 1; }

  pct exec "$CT" -- install -d -m 700 "$ct_tmp"
  for f in key key.pub known_hosts; do pct push "$CT" "$host_tmp/$f" "$ct_tmp/$f" --perms 600; done
  bao kv put kv/quiz/flux-deploy-key \
    identity=@"$ct_tmp/key" identity.pub=@"$ct_tmp/key.pub" known_hosts=@"$ct_tmp/known_hosts" >/dev/null

  echo "created. Public key (add it to 6-sem-musik-quiz/gitops as a deploy key WITH write access):"
  cat "$host_tmp/key.pub"
fi

echo
echo "== check"
bao kv list kv/quiz
echo
echo "Done. In the LXC afterwards: bao token revoke -self; rm -f /root/.vault-token"
