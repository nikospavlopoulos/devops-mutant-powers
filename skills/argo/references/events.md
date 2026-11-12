# Argo Events — EventSource → EventBus → Sensor → Trigger

Load this when an Argo Events Sensor never fires, fires on the wrong combination of events, or a trigger (a
Workflow, a Kubernetes object, an HTTP call) is not created. It walks the event path one hop at a time. Facts are
for Argo Events 1.9 (current at the time of writing).

**Targets.** `kubectl` always carries `--context <ctx>` and `-n <ns>`. Editing EventSources, Sensors, the EventBus or
their role-based access control (RBAC) changes live state: each needs the owner's explicit approval, and the change belongs in Git when the
objects are managed by Argo CD or Flux.

## 1. The path

1. **EventSource** — consumes events from an external source (webhook, queue, cloud service, Kubernetes resource
   watch), converts them to CloudEvents and publishes them to the EventBus.
2. **EventBus** — the transport between EventSources and Sensors: NATS (deprecated), JetStream or Kafka. It is
   namespaced and required in the namespace; the convention is one named `default`. A bus with another name must be
   selected with `eventBusName` on **both** the EventSource and the Sensor.
3. **Sensor** — declares event dependencies (inputs) and triggers (outputs); it listens on the EventBus and fires a
   trigger once its dependencies resolve.
4. **Trigger** — what runs: Argo Workflows, Argo Rollouts, any Kubernetes object, HTTP request, AWS Lambda,
   OpenWhisk, Kafka or NATS message, Slack notification, Azure Event Hubs, custom, or `log` (for debugging).

## 2. Triage, hop by hop

```bash
kubectl --context <ctx> -n <ns> get eventbus,eventsources,sensors
kubectl --context <ctx> -n <ns> get eventsources.argoproj.io <source> -o yaml
kubectl --context <ctx> -n <ns> get sensors.argoproj.io <sensor> -o yaml
kubectl --context <ctx> -n <ns> get pods -l eventsource-name=<source>
kubectl --context <ctx> -n <ns> logs -l eventsource-name=<source> --since=30m
kubectl --context <ctx> -n <ns> get events --sort-by=.lastTimestamp
```

| Symptom | Check |
|---|---|
| nothing reaches the EventSource | for webhook sources the `service` field creates only a test `ClusterIP`; external callers need your own Service (selector `eventsource-name: <source>`) plus a LoadBalancer or Ingress |
| a `resource` EventSource sees nothing | its service account needs `list` and `watch` on the watched resource (Role, or ClusterRole for cluster-wide) |
| EventSource receives, Sensor never fires | both use the same EventBus (`default`, or the same `eventBusName`); the dependency's `eventSourceName`/`eventName` match |
| fires on the wrong combination | with no `conditions`, **all** dependencies must resolve (AND); `conditions` takes `&&` / `||` over dependency names; `conditionsReset.byTime.cron` clears partial state |
| fired with an old payload | for each dependency the latest event is used; earlier ones are dropped |
| Workflow/Kubernetes trigger not created | the Sensor's `spec.template.serviceAccountName` needs `create` (+ `list` for Workflows) on the target; `update`/`get` for retry, resume or suspend |
| created Workflow fails on permissions | its own service account is set in the Workflow spec, not by the Sensor — see `references/workflows.md` §2 |
| a trigger failed once and never again | triggers are not retried unless `retryStrategy` is set; a `dlqTrigger` also needs `atLeastOnce: true` |

## 3. Discipline

- Add triggers' `retryStrategy` and `rateLimit` deliberately in Git — by default there is neither.
- A Sensor service account is needed only for `k8s` and `argoWorkflow` triggers; do not hand broad RBAC to every
  Sensor.
- Prove the path end to end with one real test event (approval on a shared system) and the object it created
  (Workflow, Kubernetes object, HTTP call) — not only Pods `Running`.

## Verified References

- <https://argoproj.github.io/argo-events/concepts/architecture/> — the four main components
- <https://argoproj.github.io/argo-events/concepts/event_source/> — consumes external events, transforms to CloudEvents, dispatches to the EventBus
- <https://argoproj.github.io/argo-events/concepts/eventbus/> — transport between EventSources and Sensors; NATS (deprecated), JetStream, Kafka
- <https://argoproj.github.io/argo-events/eventbus/eventbus/> — namespaced and required, `default` by convention, `eventBusName` on both sides
- <https://argoproj.github.io/argo-events/concepts/sensor/> — dependencies and triggers, listens on the EventBus
- <https://argoproj.github.io/argo-events/concepts/trigger/> — trigger types
- <https://argoproj.github.io/argo-events/sensors/trigger-conditions/> — default AND of all dependencies, `&&`/`||`, `conditionsReset.byTime`
- <https://argoproj.github.io/argo-events/sensors/more-about-sensors-and-triggers/> — latest event per dependency, no retry or rate limit by default, `atLeastOnce` for `dlqTrigger`
- <https://argoproj.github.io/argo-events/service-accounts/> — `resource` EventSources need `list`/`watch`; Sensor service account only for `k8s`/`argoWorkflow` triggers and its verbs; Workflow SA set in the Workflow spec
- <https://argoproj.github.io/argo-events/eventsources/services/> — `service` field = test-only `ClusterIP`; own Service/Ingress with `eventsource-name` selector
