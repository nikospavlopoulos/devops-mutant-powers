# Kafka on Kubernetes with Strimzi

Load this file when a Kafka cluster run by the Strimzi operator misbehaves or must change: clients cannot connect or
log in, partitions are under-replicated, consumers lag, a topic or user does not behave as its custom resource (CR)
says, or brokers must be rolled or upgraded. Facts are from the Strimzi 1.2.0 docs (the latest release and the
version `strimzi.io/docs/operators/latest` describes; the main-branch CHANGELOG already lists unreleased 1.3.0 and
1.4.0 entries) and the Apache Kafka 4.3 docs; check the versions you run first. Placeholders: context `<ctx>`,
namespace `shop`, cluster `my-cluster`, user `app-a`, topic `orders`, consumer group `orders-worker`.

## Versions and API

| Strimzi | What changed | Consequence |
|---|---|---|
| 0.46.0 | ZooKeeper-based clusters and ZooKeeper → KRaft migration removed | KRaft (Kafka Raft metadata mode) only; migrate on an older release first |
| 0.48.0 | KRaft and node pools on by default; `strimzi.io/node-pools` and `strimzi.io/kraft` annotations ignored | Old annotations in Git are dead weight |
| 0.49.0 | `v1` API introduced, with a conversion tool for resource files; before upgrading to 0.49+, `KafkaUser` ACL rules must use `operations`, not the deprecated `operation` | Convert manifests while both versions are served |
| 1.0.0 | `v1beta2` removed from the CRDs (custom resource definitions); `v1` is the only and stored version | Manifests still on `v1beta2` stop applying — convert them in Git before the upgrade |

## KRaft and node pools

- A cluster is a `Kafka` CR plus one or more `KafkaNodePool` CRs. Node roles: `broker`, `controller`, or both
  (dual-role). Dual-role is meant for development and testing; production uses dedicated broker and controller pools.
- Strimzi uses a static controller quorum for all deployments: the number of controllers is fixed, and changing it
  needs downtime. Size the controller pool before go-live.

## Who owns what (change the CR, never its products)

| CR | Reconciled by | Notes |
|---|---|---|
| `Kafka`, `KafkaNodePool` | Cluster Operator | Owns pods (through StrimziPodSets), Services, NetworkPolicies, certificate Secrets |
| `KafkaTopic` | Topic Operator | Needs label `strimzi.io/cluster: my-cluster`; with a wrong label the operator never sees it and the topic is not created |
| `KafkaUser` | User Operator | Same label; writes a Secret with the same name as the `KafkaUser` |

Topic Operator behaviour (1.2.0 docs, §12):

- Changes go one way, from `KafkaTopic` to Kafka. Config changed outside the resource (for example with
  `kafka-configs.sh`) is reverted. Topics without a `KafkaTopic` are left alone.
- Several `KafkaTopic` resources for one topic: only the oldest is reconciled; the others go `Ready=False` with a
  conflict.
- Not allowed through `KafkaTopic`: decreasing `spec.partitions` (Kafka cannot) and changing `spec.replicas` (needs
  Cruise Control). Adding partitions changes which partition a key maps to.
- `strimzi.io/managed=false` on a `KafkaTopic` stops management (condition `Unmanaged`) — approval.
- Finalizer `strimzi.io/topic-operator`: if the Topic Operator is down, deleting topics or the namespace hangs in
  `Terminating`. Removing the finalizer skips the cleanup (the Kafka topic is not deleted) — approval only.

Topic and user changes (create, config, partitions, delete, ACLs, passwords) are CR changes in Git — approval.
Pause a CR's reconciliation with the annotation `strimzi.io/pause-reconciliation="true"` (approval; remove it after).

## Listeners and client access

- Listener types: internal `internal`, `cluster-ip`; external `nodeport`, `loadbalancer`, `ingress` (deprecated since
  0.51.0), `route`, `tlsroute` (Gateway API, since 1.1.0). Bootstrap Service: `my-cluster-kafka-bootstrap` for
  `internal`, `my-cluster-kafka-<listener>-bootstrap` for the other types.
- `internal` listeners use a headless Service and broker pod DNS (Domain Name System) names, without the cluster DNS
  domain by default (`useServiceDnsDomain` changes that); `cluster-ip` uses per-broker ClusterIP Services.
- The address clients should use is in `.status.listeners[].bootstrapServers`. Its presence does not mean the endpoint
  or the cluster is ready.
- Strimzi creates a NetworkPolicy for every listener. By default it allows all namespaces; `networkPolicyPeers`
  restricts it. A client in a namespace that is not listed is blocked before any TLS (Transport Layer Security)
  handshake or login happens.

## Authentication and TLS

- Listener authentication: `tls` (mutual TLS, mTLS — only on listeners with TLS on), `scram-sha-512`, `custom`
  (`oauth` and `keycloak` types are deprecated in favour of `custom`).
- `KafkaUser.spec.authentication.type`: `tls`, `tls-external` (certificate issued outside the User Operator),
  `scram-sha-512`.
- User Secret contents: SCRAM (Salted Challenge Response Authentication Mechanism) user → `password`,
  `sasl.jaas.config` (JAAS: Java Authentication and Authorization Service); TLS user → `ca.crt` (clients certificate
  authority, CA), `user.crt`,
  `user.key`, `user.p12`, `user.password`. A SCRAM user may bring its own password through
  `spec.authentication.password.valueFrom.secretKeyRef`.
- Clients verify brokers with the cluster CA: Secret `my-cluster-cluster-ca-cert`, key `ca.crt`.
- SCRAM-SHA-512 works on plain and TLS listeners, but Kafka's docs say to use SCRAM only with TLS so the exchange
  cannot be intercepted.
- `strimzi.io/force-renew="true"` on the user Secret (approval) issues a new certificate at the next reconciliation;
  the old one stays valid until it expires.
- Authorization `type: simple`: with no matching ACL (access control list) rule, access is denied.

| Client symptom | Check (in this order) |
|---|---|
| Timeout, no TLS error | bootstrap address from status; listener NetworkPolicy peers; DNS of the per-broker names the bootstrap returns |
| `SslAuthenticationException` (TLS handshake failed) | client uses TLS on a TLS listener; truststore holds the current `ca.crt`; mTLS user certificate from the right Secret |
| `SaslAuthenticationException` (SASL — Simple Authentication and Security Layer — authentication failed) | `sasl.mechanism=SCRAM-SHA-512` (not `-256`); password hash matches the Secret; user `Ready`; listener auth type |
| Logged in, but requests are refused as not authorized | `KafkaUser` ACLs (resource, `patternType`, `operations`) and `superUsers` |

Client properties for SCRAM over TLS (the password file is created from the Secret and never printed):

```properties
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="app-a" password="<from-secret>";
ssl.truststore.type=PEM
ssl.truststore.location=<dir>/ca.crt
```

## Replication health

- Durable baseline: replication factor 3, `min.insync.replicas=2`, producers with `acks=all` (the producer default,
  with idempotence on by default). With fewer in-sync replicas (ISR) than the minimum, `acks=all` producers get
  `NotEnoughReplicas` or `NotEnoughReplicasAfterAppend`. The broker default for `min.insync.replicas` is 1.
- `unclean.leader.election.enable` is `false` by default. Turning it on lets an out-of-sync replica lead — possible
  message loss. Treat it as a data-loss decision for the owner, never a quick fix.
- Broker metrics, normal values: `UnderReplicatedPartitions` 0, `UnderMinIsrPartitionCount` 0, `ActiveControllerCount`
  1 on exactly one node, `IsrShrinksPerSec`/`IsrExpandsPerSec` 0 unless a broker went down.
- `kafka-topics.sh --describe` filters (only valid with `--describe`): `--under-replicated-partitions`,
  `--under-min-isr-partitions`, `--at-min-isr-partitions`, `--unavailable-partitions` (leader not available).

## Consumer lag

- `kafka-consumer-groups.sh --describe --group <g>` shows `CURRENT-OFFSET`, `LOG-END-OFFSET`, `LAG` per partition;
  add `--members` or `--state` for who consumes and the group state.
- Kafka Exporter (`spec.kafkaExporter`) reads lag from `__consumer_offsets`, so groups that do not commit offsets show
  nothing. The client metric `records-lag-max` uses the current position, not the committed offset.
- `--reset-offsets` needs the group's consumers stopped; it only plans (`--dry-run`) unless `--execute` is given —
  approval only.

## Safe rolling changes

- Roll through the Cluster Operator, not `kubectl delete pod`: it avoids clashing with its own pod operations and
  respects in-sync replica settings.
- Manual roll: annotate the **pod** `strimzi.io/manual-rolling-update="true"` (approval). It runs at the next
  reconciliation (every two minutes by default) and the annotation is removed when the roll completes. The main-branch
  docs prefer pod annotations over annotating the StrimziPodSet, because an in-progress reconciliation can overwrite the
  StrimziPodSet annotation.
- Availability during any roll needs replication factor ≥ 3 and `min.insync.replicas` = replication factor − 1.
  Roll one pod, confirm under-replicated and under-min-ISR partitions are back to 0, then the next.
- Listener changes trigger a rolling update of the brokers; plan them like any other roll.

## Read-only commands

```bash
# Cluster, pools, topics, users and their readiness
kubectl --context <ctx> -n shop get kafka,kafkanodepool,kafkatopic,kafkauser
kubectl --context <ctx> -n shop get kafka my-cluster -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
# Bootstrap address per listener (status, not proof of readiness)
kubectl --context <ctx> -n shop get kafka my-cluster -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.bootstrapServers}{"\n"}{end}'
# Listener NetworkPolicies
kubectl --context <ctx> -n shop get networkpolicy -o wide
# Compare a SCRAM password without printing it
kubectl --context <ctx> -n shop get secret app-a -o jsonpath='{.data.password}' | base64 -d | sha256sum
# From a client pod that uses the application's listener and credentials (client.properties as above)
bin/kafka-topics.sh --bootstrap-server <bootstrap>:<port> --command-config client.properties --describe --under-replicated-partitions
bin/kafka-topics.sh --bootstrap-server <bootstrap>:<port> --command-config client.properties --describe --under-min-isr-partitions
bin/kafka-consumer-groups.sh --bootstrap-server <bootstrap>:<port> --command-config client.properties --describe --group orders-worker
```

Every Kafka tool prints its options when run without arguments — check flag names against your Kafka version.

## Practice (throwaway kind or k3d cluster)

Install Strimzi from its quickstart, create a small cluster with a TLS + SCRAM listener, then: give a `KafkaTopic` the
wrong `strimzi.io/cluster` label and watch it never appear; log in with `SCRAM-SHA-256` and read the error; roll one
broker with the pod annotation while a producer with `acks=all` keeps writing.

## Verified References

- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/CHANGELOG.md> — ZooKeeper and migration
  removed in 0.46.0; KRaft/node pools default and annotations ignored in 0.48.0; `v1` API, conversion tool and
  `operations` field in 0.49.0; `ingress` listener deprecated in 0.51.0; `v1beta2` removed in 1.0.0; `KafkaUser`
  force-renew annotation added in 1.0.0; `tlsroute` listener in 1.1.0; unreleased 1.3.0/1.4.0 entries at the top
- <https://github.com/strimzi/strimzi-kafka-operator/releases> — 1.2.0 is the latest release; 1.3.0 only at release
  candidate
- <https://strimzi.io/docs/operators/latest/deploying> (Deploying and Managing 1.2.0) — node roles and dual-role for
  dev/test (§2), static controller quorum (§2.1), `strimzi.io/cluster` label (§1.1.1), pause annotation (§11.6.3),
  Topic Operator one-way sync, conflicts, limits, `managed=false`, finalizer (§12.1–§12.9), replication factor 3 / min ISR 2 (§12.5),
  listener types, `ingress` deprecated, headless `internal` vs per-broker ClusterIP `cluster-ip` (§15.2), listener auth, NetworkPolicy and `networkPolicyPeers`, user
  Secret keys, custom password, force-renew, ACLs, super users, cluster CA Secret (§16.1–§16.4), `tls-external`
  (§11.9.2)
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/modules/managing/proc-manual-rolling-update-pods.adoc>
  — pod annotation, next reconciliation every two minutes, annotation removed after the roll, replication factor ≥ 3 and min ISR = factor − 1
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/assemblies/deploying/assembly-rolling-updates.adoc>
  — roll through the Cluster Operator rather than deleting pods; pod annotation preferred over StrimziPodSet
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/modules/security/con-securing-client-authentication.adoc>
  — the user Secret has the same name as the `KafkaUser`
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/modules/overview/con-configuration-points-listener-names.adoc>
  — bootstrap and per-broker Service names
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/modules/managing/con-custom-resources-status.adoc>
  — `status.listeners[].bootstrapServers`; bootstrap address does not mean Ready
- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/documentation/modules/metrics/con_kafka-exporter-lag.adoc>
  — Kafka Exporter lag needs committed offsets in `__consumer_offsets`
- <https://kafka.apache.org/43/configuration/topic-configs/> — `min.insync.replicas` default 1, errors, replication factor 3 / min ISR 2
  / `acks=all`; `unclean.leader.election.enable` default false and data loss
- <https://kafka.apache.org/43/configuration/producer-configs/> — `acks` default `all`; idempotence default true
- <https://kafka.apache.org/43/operations/monitoring/> — normal values of under-replicated, under-min-ISR, active controller, ISR
  shrink/expand; `records-lag-max` based on current offset
- <https://kafka.apache.org/43/operations/basic-kafka-operations/> — `kafka-consumer-groups.sh --describe` columns;
  tools print options when run without arguments
- <https://kafka.apache.org/43/security/authentication-using-sasl/> — SCRAM client properties; SCRAM only with TLS
- <https://kafka.apache.org/43/security/encryption-and-authentication-using-ssl/> — PEM store type for file-based
  trust stores; `--command-config` on console clients in 4.3
- <https://raw.githubusercontent.com/apache/kafka/trunk/tools/src/main/java/org/apache/kafka/tools/TopicCommand.java>
  — `--describe` filters and `--command-config`
- <https://raw.githubusercontent.com/apache/kafka/trunk/tools/src/main/java/org/apache/kafka/tools/consumer/group/ConsumerGroupCommandOptions.java>
  — `--members`, `--state`, `--reset-offsets` (inactive group, `--dry-run`/`--execute`)
- <https://kafka.apache.org/43/javadoc/org/apache/kafka/common/errors/SaslAuthenticationException.html> and
  <https://kafka.apache.org/43/javadoc/org/apache/kafka/common/errors/SslAuthenticationException.html> — meaning of
  the two client exceptions
