---
name: data-services
description: Use when Kafka (Strimzi), MongoDB or MySQL misbehaves, or for their operators, replication and backups — UnderReplicatedPartitions, consumer lag, KafkaUser SCRAM/TLS auth, NotWritablePrimary, AuthenticationFailed, Access denied for user, Authentication requires secure connection, replica lag, GTID or dump errors. Postgres → postgres-operations.
---

# Data Services: Kafka, MongoDB, MySQL

**In plain terms:** an operator keeps rebuilding these brokers and databases from a custom resource (CR), so the fix is a CR change in Git — find which layer fails (connection, login, replication, client), then prove the fix through the application's own path.

## When to Use

- **Kafka (Strimzi):** `UnderReplicatedPartitions` or `UnderMinIsrPartitionCount` above 0, `NotEnoughReplicas` on produce, consumer lag growing; `KafkaUser` SCRAM (salted challenge-response password) or mutual TLS (Transport Layer Security, mTLS) logins failing; a `KafkaTopic` that never appears or keeps reverting; rolling brokers; Strimzi upgrades
- **MongoDB:** `NotWritablePrimary`, `PrimarySteppedDown`, `AuthenticationFailed`; a port-forwarded client that cannot reach the members; replica lag; write/read concerns; `mongodump`/`mongorestore`; MongoDB Controllers for Kubernetes (MCK) users
- **MySQL:** `ERROR 2061 ... Authentication requires secure connection`, `Access denied for user '<u>'@'<host>'`, `Host '<host>' is not allowed to connect`; replica stopped or lagging, `ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS`; `mysqldump`/MySQL Shell dumps; MySQL Operator `InnoDBCluster`
- A risky change on any of them: upgrade, scaling, storage move, restore

**Not this skill:** PostgreSQL/CloudNativePG → `devops-mutant-powers:postgres-operations`; PersistentVolumeClaim (PVC) binding, resize, volume recovery → `devops-mutant-powers:kubernetes-storage`; the dump/copy Job or CronJob wrapper → `devops-mutant-powers:batch-data-jobs`; credential storage and rotation → `devops-mutant-powers:secrets-management`; Flux not applying the CR → `devops-mutant-powers:gitops-flux`.

## Core Rules

1. **The operator owns the cluster.** Identify the operator and its CR (Strimzi `Kafka`/`KafkaNodePool`/`KafkaTopic`/`KafkaUser`, MCK `MongoDBCommunity`/`MongoDB`, MySQL Operator `InnoDBCluster`) and change the CR at its Git owner. Never hand-edit pods, StrimziPodSets/StatefulSets or operator-generated ConfigMaps and Secrets — they are reverted or become invisible drift.
2. **A verified backup before any risky change; a restore tested, not assumed.** Name its type (logical dump, physical copy, snapshot) and consistency limits; it counts only after it has restored somewhere disposable.
3. **Triage in order: connection → authentication/TLS → replication/partition health → client behaviour.** Read the exact server and client error first; do not tune replication for a wrong hostname or `authSource`.
4. **Never print credentials.** Compare Secret values by `sha256sum` or length. Keep passwords out of command lines and URIs (visible in `ps`); use a client properties, option or `--config` file.
5. **One broker, member or replica at a time, through the operator** (Strimzi pod annotation, a CR change); wait for healthy replication — no under-replicated partitions, member `SECONDARY`/`ONLINE`, replica threads running — before the next.
6. **Every command names its target:** `--context <ctx> -n <ns>`, CR, bootstrap address or host, database, user. Before a write, print where you are (`SELECT CURRENT_USER(), @@hostname;`, `db.hello().me`).
7. **Live changes need explicit human approval:** rolls, reconciliation pauses, user/ACL (access control list)/password changes, step-down, topic deletes, offset resets, restores, finalizer removal, and every durability trade (`unclean.leader.election.enable`, lower `min.insync.replicas` or write concern, `mysql_native_password`). For "how do I check", print the commands; do not run them.
8. **A green CR is not a working service.** `Ready=True`, a bootstrap address in status or a `Completed` backup Job proves nothing about clients.

## Workflow — Triage Ladder

0. **Context:** server and operator versions; the endpoint, TLS settings and user the *application* uses (not an admin shell in the pod). Version gates: Strimzi ≥ 1.0.0 serves only `kafka.strimzi.io/v1`, ZooKeeper clusters unsupported since 0.46.0; MCK replaced the MongoDB Community and Enterprise operators; MySQL 8.4 disables `mysql_native_password` by default, 9.0 removed it from the server.
1. **Connection** — does the name resolve and the port answer from the client's namespace? Strimzi adds a NetworkPolicy per listener; MongoDB drivers switch to the hostnames the replica set advertises; MySQL `localhost` means the Unix socket.
2. **Authentication/TLS** — classify the exact error:

| Error | Usually means | Load |
|---|---|---|
| `SaslAuthenticationException` / `SslAuthenticationException` | wrong SCRAM password or mechanism; client security protocol not matching the listener; cluster certificate authority (CA) not trusted | `references/kafka-strimzi.md` |
| `AuthenticationFailed` (18) | wrong password, or wrong `authSource` (default: the URI's database, else `admin`) | `references/mongodb.md` |
| `ERROR 2061 ... Authentication requires secure connection` | first `caching_sha2_password` login over plain TCP without TLS or RSA key exchange | `references/mysql.md` |
| `Access denied for user '<u>'@'<h>'` | wrong password, or a more specific account row (e.g. `''@'localhost'`) matched first | `references/mysql.md` |

3. **Replication/partition health** — Kafka: under-replicated and under-min-ISR (in-sync replica) partitions, one active controller; MongoDB: `rs.status()`, who is primary; MySQL: `SHOW REPLICA STATUS` threads and errors, or Group Replication member states.
4. **Client behaviour** — consumer lag and committed offsets, retries during elections, write/read concern, `acks`, read preference.

## LLM Mistakes Checklist

- `kubectl delete pod` to "restart" a broker or member — bypasses the operator's ordering and replica checks.
- Enabling unclean leader election or lowering `min.insync.replicas`/`acks` to clear an outage — availability bought with possible data loss.
- Port-forwarding to one MongoDB member and blaming DNS (name resolution) or auth — without `directConnection=true` the driver discovers and dials the in-cluster member names.
- Re-enabling `mysql_native_password` to fix `2061` — use TLS or RSA key exchange; 9.0 servers no longer have the plugin.
- `mongodump` without `--oplog` or `mysqldump` without `--single-transaction` called consistent; an unrestored dump called a backup.
- Lag `0` read as healthy — `Seconds_Behind_Source` is `0` when the applier is idle, `NULL` when it stopped; MongoDB lag can read negative after idle periods; Kafka Exporter sees only groups that commit offsets.
- Changing a topic with `kafka-configs.sh` while a `KafkaTopic` owns it — the Topic Operator reverts it.

## Output Contract

1. **Diagnosis tied to evidence** — the exact error plus the status field, metric or output that proves it; anything not seen marked unverified, with a confidence.
2. **Read-only commands with explicit targets** (Rule 6) — printed for the human when asked how to check.
3. **The fix at the owner** — a CR diff in Git, or a reviewed admin statement for in-database objects; backup status stated; every state-changing step held for explicit approval, staging first.
4. **Verification through the client's real path** — produce and consume a test record, or log in and run a real query as the application user through the same Service, port and TLS settings — plus replication evidence (full ISR, `rs.status()`, replica threads); a restore proven by counts and an app smoke test.
5. **Durability and follow-ups** — committed to Git; no pause, manual annotation or temporary setting left behind; owner and next action for anything open.

## References — load only the 1–2 files that match the task

- `references/kafka-strimzi.md` — Kafka/Strimzi: `v1` API, KRaft node pools, listeners, TLS/SCRAM `KafkaUser`, `KafkaTopic` ownership, ISR and under-replicated partitions, consumer lag, safe rolls
- `references/mongodb.md` — MongoDB: MCK users, replica sets and elections, concerns, connection strings, error codes, lag, backups
- `references/mysql.md` — MySQL: auth plugins and account matching, GTID replication, `SHOW REPLICA STATUS`, `InnoDBCluster`, backups

## Verified References (all links with their claims: the last section of each reference file)

- <https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/CHANGELOG.md> — Strimzi `v1`-only API in 1.0.0; ZooKeeper removed in 0.46.0 · <https://strimzi.io/docs/operators/latest/deploying> (1.2.0, the latest release) — out-of-band topic changes reverted; NetworkPolicy per listener
- <https://kafka.apache.org/43/configuration/topic-configs/> — `min.insync.replicas`; unclean leader election off by default, risks data loss
- <https://www.mongodb.com/docs/kubernetes/current/> — MCK replaces the Community and Enterprise operators
- <https://dev.mysql.com/doc/refman/8.4/en/native-pluggable-authentication.html> — `mysql_native_password` disabled in 8.4, removed in 9.0.0 · <https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html> — `Seconds_Behind_Source` `0`/`NULL`
