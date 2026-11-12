# Reverse Proxy — Hop-Walk Commands

**Purpose.** Load this whenever you print commands for the 5xx / cross-origin resource sharing (CORS) hop-walk in
`SKILL.md`: the replay of the failing request, the content delivery network (CDN) bypass, gateway and route status,
EndpointSlices, the proxy bypass and the quick one-liners, each with the note on how to read the result. Every
command reads state only and names its target (`--context <ctx> -n <ns>`, host, IP); for "how do I check", print
them for the human. Layer depth lives in the matching reference (`envoy-gateway.md`, `azure-appgw-agic.md`,
`cdn-edge.md`, `haproxy-sni.md`, `service-mesh.md`).

Hop map: `client → CDN/WAF → cloud LB or gateway → ingress/Gateway → Service → EndpointSlice → pod → app`
(WAF = web application firewall, LB = load balancer).

## 1. Capture the failing request (browser or client)

DevTools → Network: the failing request **and** its `OPTIONS` preflight; status, response headers, body. A console
"CORS error" hides the real status — the network entry shows it. Copy as cURL, delete cookies/tokens, replay:

```bash
curl -sS -o /dev/null -D - -w '%{http_code} %{time_total}s\n' https://app.example.com/api/x
curl -sS -D - -o /dev/null -X OPTIONS https://app.example.com/api/x \
  -H 'Origin: https://ui.example.com' -H 'Access-Control-Request-Method: POST'
```

## 2. Which layer answered?

Match the status, body and headers against the evidence table in `SKILL.md` (step 2); the first one-liner under
"Quick one-liners" prints the headers it needs. Status meanings per layer: `status-and-cors.md`.

## 3. CDN / WAF

Security events for the request (rule ID, action), origin status vs edge status, the edge timeout (524 = origin
accepted the connection but sent no response in time). Bypass the edge to split edge from origin (same SNI):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --resolve app.example.com:443:203.0.113.10 https://app.example.com/api/x
```

## 4. Cloud gateway / load balancer backend health

Backend health per pool member and the probe's Host header (App Gateway's default probe sends `127.0.0.1`); the
access log's backend status vs client status (`ServerStatus` vs `HttpStatus`). Details: `references/azure-appgw-agic.md`.

## 5. Ingress / Gateway objects and their status

```bash
kubectl --context <ctx> -n <ns> get httproute,gateway -o wide
kubectl --context <ctx> -n <ns> get httproute <route> \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl --context <ctx> -n <ns> get securitypolicy,clienttrafficpolicy,backendtrafficpolicy
kubectl --context <ctx> -n <ns> describe ingress <ingress>        # events: sync errors, ignored class
```

`Accepted=False` / `ResolvedRefs=False` on a route means the gateway never programmed it. For Envoy, read the access
log `response_flags` (`UH`, `UF`, `UT`, `NR`, `URX`) — `references/envoy-gateway.md`.

## 6. Service → EndpointSlices

```bash
kubectl --context <ctx> -n <ns> get endpointslices -l kubernetes.io/service-name=<svc> \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
kubectl --context <ctx> -n <ns> get svc <svc> -o jsonpath='{.spec.selector} {.spec.ports}{"\n"}'
```

No ready endpoints → 503 at the proxy. Selector/port/`targetPort` mismatch → no endpoints or connection refused.
Readiness flapping → `kubernetes/references/probes-and-readiness.md`.

## 7. Bypass every proxy: port-forward and in-pod request

```bash
kubectl --context <ctx> -n <ns> port-forward svc/<svc> 18080:<port> &
curl -sS -o /dev/null -D - -H 'Host: app.example.com' http://127.0.0.1:18080/api/x
kubectl --context <ctx> -n <ns> exec deploy/<name> -- sh -c 'wget -qSO /dev/null http://127.0.0.1:<port>/healthz 2>&1 | head -3'
```

Works here but fails through the proxy → the proxy hop (Host routing, path rewrite, timeout, body or header size).
Fails here too → the app; continue in its logs.

## 8. App logs at the same timestamp and request ID

Match `x-request-id` or the timestamp. No log line at all = the request never arrived (go back up the chain).

## Quick one-liners

```bash
# Which hop answered: status, server-ish headers, request id
curl -sS -o /dev/null -D - https://app.example.com/ | grep -iE '^(HTTP|server|via|cf-ray|x-request-id|location|access-control)'
# Same request pinned to one hop (bypasses DNS/CDN; SNI stays correct)
curl -sS -o /dev/null -w '%{http_code}\n' --resolve app.example.com:443:203.0.113.10 https://app.example.com/
# Redirect chain (loops, lost paths)
curl -sS -o /dev/null -L --max-redirs 10 -w '%{num_redirects} %{url_effective}\n' 'http://app.example.com/a/b?c=1'
# Envoy Gateway access log for one Gateway (flags, upstream, the client IP Envoy believes)
kubectl --context <ctx> -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=<gw> -c envoy --since=10m \
  | grep '"start_time"' | jq -c '{response_code,response_flags,route_name,upstream_host,downstream_remote_address}'
```

## Verified References

- <https://gateway.envoyproxy.io/docs/tasks/observability/proxy-accesslog/> — default access-log fields (`response_flags`, `upstream_host`, `downstream_remote_address`)
- <https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/> — EndpointSlice `conditions.ready`, `kubernetes.io/service-name` label
- <https://developers.cloudflare.com/fundamentals/reference/http-headers/> — `Cf-Ray` header returned to visitors
- <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/> — 524 after the 125 s Proxy Read Timeout
