# Commands — Who Has What, Proof as the Identity

Read-only checks for access questions: what an identity may do, which bindings name it, who it really is through the
person's own kubeconfig, and what a tailnet device can see and reach. Every command names its target
(`--context <ctx>`, `-n <ns>`, `--as=<identity>`, the person's kubeconfig or device). Nothing here changes state;
grants, token issuance and revokes live in `kubernetes-rbac.md`, `tailscale-policy.md`, `private-access-paths.md`
and `tooling/kubernetes/rbac/README.md`, each step needing explicit approval. Never print a token: compare by
`sha256sum` or length. Abbreviation: SA = Kubernetes ServiceAccount.

```bash
# Can identity X do Y? (--subresource, NOT "pods/exec": TYPE/NAME means the pod named "exec")
kubectl --context <ctx> -n app-a auth can-i create pods --subresource=exec --as=system:serviceaccount:human-access:dev-a
# Everything X may do in a namespace (SelfSubjectRulesReview: may be incomplete, listed rules are real)
kubectl --context <ctx> -n app-a auth can-i --list --as=system:serviceaccount:human-access:dev-a
# Every binding that names a ServiceAccount, cluster-wide
kubectl --context <ctx> get rolebindings,clusterrolebindings -A -o json | jq -r '.items[]
  | select(any(.subjects[]?; .kind=="ServiceAccount" and .name=="dev-a" and .namespace=="human-access"))
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.kind)/\(.roleRef.name)"'
# Bindings to broad groups apply to every identity too — check them
kubectl --context <ctx> get rolebindings,clusterrolebindings -A -o json | jq -r '.items[]
  | select(any(.subjects[]?; .kind=="Group" and (.name=="system:authenticated" or (.name|startswith("system:serviceaccounts")))))
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.name)"'
# Who am I with the person's kubeconfig (real path)
kubectl --kubeconfig ./dev-a.kubeconfig --context dev-a@<cluster> auth whoami

# Tailscale, run on the person's (non-admin) device: what it can see, with tags
tailscale status --json | jq -r '.Peer[] | [.HostName, ((.Tags // []) | join(",")), (.TailscaleIPs[0] // "-")] | @tsv'
# Port reachability, allowed AND denied (bash /dev/tcp; 3 s cap)
for p in 5432 22 443; do timeout 3 bash -c "</dev/tcp/<tailnet-ip>/$p" 2>/dev/null && echo "$p open" || echo "$p closed"; done
# Identity behind a tailnet IP
tailscale whois <tailnet-ip>
```

The full Kubernetes proof matrix (expected yes/no per check) is in `kubernetes-rbac.md`; the tailnet procedure,
including "closed proves the policy only if the service listens", is in `tailscale-policy.md`.

## Verified References

- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/> — `VERB [TYPE | TYPE/NAME | NONRESOURCEURL]`, `--subresource`, `--list`, `-q`, `--as`
- <https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/self-subject-rules-review-v1/> — rules review may be incomplete; listed rules can be trusted
- <https://tailscale.com/docs/reference/tailscale-cli.md> — `tailscale status --json`, `tailscale whois`
