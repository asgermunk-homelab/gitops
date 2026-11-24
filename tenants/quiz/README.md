# The quiz tenant: the homelab side

The quiz tenant consists of these files:

```
clusters/homelab/quiz.yaml      Flux Kustomization quiz-tenant (cluster-admin)
tenants/quiz/                   namespace, admission policies,
                                RBAC, SecretStore, deploy key, the quiz Kustomization
scripts/add-quiz-member.sh      kubeconfig for one person
```

The quiz team's own repo `6-sem-musik-quiz/gitops` is applied by the
Kustomization `quiz` as the service account `quiz-flux`. It can only touch the
namespace `quiz`, and it cannot create Kustomizations, GitRepositories or
SecretStores.

## Why not the built-in `edit` role

In this cluster `edit` includes `flux-edit-flux-system`, so it can create Flux
Kustomizations. Flux runs without multi-tenancy lockdown, and a Kustomization
or HelmRelease without `serviceAccountName` runs as cluster-admin. So:

- The people get the read-only Role `quiz-developer`, plus logs, exec, port-forward and pod delete.
- Flux gets `quiz-flux` and `quiz-helm`, with explicit Roles.
- Two ValidatingAdmissionPolicies refuse a HelmRelease or Kustomization in
  `quiz` without the right service account, and refuse pods that run as those accounts.

## Steps, in order

### 1. OpenBao: policy, role, passwords and deploy key (done 2026-11-17)

`scripts/openbao-quiz.sh` runs on the Proxmox host and calls `bao` inside the
OpenBao LXC with `pct exec` (the LXC has no `openssl` or `ssh-keygen`). It makes:

- the policy `quiz-read` and the Kubernetes auth role `quiz` (the same form as
  the other namespaces: `audience=openbao`, TTL 1 h, max 4 h)
- random hex passwords in `kv/quiz/postgres`, `kv/quiz/redis` and
  `kv/quiz/rabbitmq` (hex needs no quoting in SQL or in connection strings)
- the Flux deploy key in `kv/quiz/flux-deploy-key`

The secrets go to `bao` over stdin or as a RAM file that is deleted at once;
it prints only the public deploy key. It never
replaces an existing secret, so it is safe to run again.

Log in inside the LXC (the password is in Bitwarden):

```bash
ssh pve
pct enter 102
export BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/opt/openbao/tls/ca.crt
bao login -no-print -method=userpass username=asger
```

Then, from the PC, in the `scripts` folder of this repo:

```bash
ssh pve 'bash -s' < openbao-quiz.sh
```

Afterwards, inside the LXC: `bao token revoke -self; rm -f /root/.vault-token`.

### 2. The deploy key in GitHub (done 2026-11-17)

Allow deploy keys in the org settings of `6-sem-musik-quiz` (new orgs block
them). Then add the public key from step 1 to `6-sem-musik-quiz/gitops` under
Settings → Deploy keys, with **Allow write access** (the image automation
pushes the tag updates).

### 3. Tailscale (admin console, Access controls)

Before you invite anyone: the default policy lets every device reach every
other device. Add a group and a grant that only opens the Kubernetes API, and
make sure the existing allow-all rule only covers your own login.

```jsonc
"groups": {
  "group:quiz": ["<friend1 login>", "<friend2 login>", "<friend3 login>"]
},
"grants": [
  // ... your existing rules, limited to your own login ...
  { "src": ["group:quiz"], "dst": ["192.168.0.20/32"], "ip": ["tcp:6443"] }
]
```

Then invite the three as users. They connect through the subnet route on `pve`
(Windows uses subnet routes by default; Linux needs `tailscale up --accept-routes`).
They do not get Traefik (`100.97.211.103`): it also serves `proxmox.lab`,
`openbao.lab` and `grafana.lab`.

### 4. kubeconfig for each person

Each person runs (their key never leaves their PC):

```bash
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout <name>.key -out <name>.csr -subj "/CN=<name>/O=quiz-developers"
```

They send you `<name>.csr`. You run `./scripts/add-quiz-member.sh <name> <name>.csr`
and send back `<name>.kubeconfig`. The certificate lasts 180 days.

### 5. Public hostnames (Cloudflare, tunnel `homelab`)

When the frontend and the edge service exist, add to the tunnel:

| Hostname | Path | Service |
|---|---|---|
| `quiz.munkcloud.dk` | `^/(api\|hubs)/` | `http://edgeservice.quiz.svc.cluster.local:8080` |
| `quiz.munkcloud.dk` | (rest) | `http://frontend.quiz.svc.cluster.local:8080` |

Same hostname for both, so the browser needs no CORS.
