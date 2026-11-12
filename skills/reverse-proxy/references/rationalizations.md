# Reverse Proxy — Common Rationalizations

**Purpose.** Load this when reviewing a plan or a reply about a proxy, ingress, gateway or content delivery network
(CDN) failure for shortcuts. Each row is an excuse that sounds reasonable and the fact that refutes it; the LLM
Mistakes Checklist in `SKILL.md` is the condensed form. CORS = cross-origin resource sharing; AGIC = the Application
Gateway Ingress Controller.

| Excuse | Reality |
|---|---|
| "It's a CORS problem, add `*`" | The browser hides the real status. A proxy 403/5xx has no CORS headers. Read the network entry. |
| "Raise the timeout" | Which hop fired? The shortest ceiling in the chain wins; raising another one changes nothing. |
| "The app logs are clean, so the app is fine" | Clean logs + 5xx = the request died at a proxy. Find that hop's log line. |
| "Restart the ingress/gateway pod" | Restarts erase evidence and fix nothing that is configuration. Read status and logs first. |
| "I fixed it in the portal" | AGIC/Envoy Gateway/Flux rewrite managed objects within seconds. Change the source of truth. |
| "Allow the cluster CIDR too, just in case" | If client-IP recovery breaks, everyone arrives from that CIDR and the allowlist opens. |
| "The config reloaded fine" | `-c`/`-t` proves syntax, not behaviour. Prove with a canary request whose result changes. |
| "We moved CORS to the gateway, same thing" | Config equivalence ≠ header equivalence. Diff emitted headers per origin and method. |
| "Switch the CDN to Flexible to stop the error" | Flexible + an origin HTTPS redirect is a redirect loop, and origin traffic goes plaintext. |

Details behind the rows: timeout chain and CORS move → `envoy-gateway.md` §5–§6; SSL modes and loops → `cdn-edge.md`
§5; AGIC ownership → `azure-appgw-agic.md` §3; CORS essentials → `status-and-cors.md`.
