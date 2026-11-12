# MongoDB Replica Sets, Clients and Backups

Load this file when a MongoDB replica set misbehaves or must change: clients cannot find the primary or log in,
writes fail during elections, secondaries lag, users created by the Kubernetes operator do not work, or a backup or
restore is planned. Facts are from the current MongoDB manual and MongoDB Controllers for Kubernetes 1.13.0.
Placeholders: context `<ctx>`, namespace `shop`, replica set `rs0`, members `rs0-0`…`rs0-2`, user `app-a`, database
`orders`.

## The operator: MongoDB Controllers for Kubernetes (MCK)

- MCK replaces both the MongoDB Community Operator and the MongoDB Enterprise Kubernetes Operator. The old
  `mongodb/mongodb-kubernetes-operator` repository is deprecated (best-effort support until November 2025) and was
  archived read-only on 12 December 2025; it points to `mongodb/mongodb-kubernetes` and a migration guide there.
- Community deployments are the database resource only (`MongoDBCommunity`). Enterprise deployments also need an
  external management service — Ops Manager (self-managed) or Cloud Manager — for automation, backup and monitoring.
- `MongoDBCommunity` users live in `spec.users[]`: `name`, `db` (authentication database, default `admin`),
  `passwordSecretRef.name` and `.key` (default key `password`), `roles[]`, `scramCredentialsSecretName`. The operator
  creates the SCRAM (Salted Challenge Response Authentication Mechanism) credential Secret (that name plus a `scram-credentials` suffix) and a Secret holding the user's
  connection strings.
- Password change (approval): apply a new password Secret under the same `passwordSecretRef.name`; the operator
  regenerates the credentials. Once the resource is running the operator no longer needs the password Secret — the
  docs suggest storing the password safely and deleting that Secret (approval), so decide where it lives (secrets
  manager) before you do.
- Change members, versions and users in the custom resource (CR) in Git (approval) — not by `rs.reconfig()` or
  `db.createUser()` behind the operator's back.

## Replica sets and elections

- Members send heartbeats every 2 seconds. A primary unreachable for more than 10 seconds (`electionTimeoutMillis`)
  triggers an election; the median time to a new primary should not normally exceed 12 seconds. `rs.stepDown()`,
  `rs.reconfig()`, adding a member and initiating a set also cause elections — each is a live change (approval), run
  against a named replica set after checking `db.hello().me`.
- No writes until the election finishes. Reads continue only if they are allowed on secondaries.
- Drivers detect the lost primary and retry certain writes once (`retryWrites`, default `true` in official drivers).
- Up to 50 members, at most 7 voting; extra members need `votes: 0` and `priority: 0`.
- `db.hello()` shows `isWritablePrimary`, `secondary`, `primary` (current primary host), `hosts` and `me` (the
  member that answered).

## Error codes

| Name (code) | Means | First check |
|---|---|---|
| `NotWritablePrimary` (10107), `NotPrimaryNoSecondaryOk` (13435), `NotPrimaryOrSecondary` (13436) | the member that received the operation is not a writable primary (the name says which case) | which host the client really reached (`hello`), `directConnection`, election in progress |
| `PrimarySteppedDown` (189), `InterruptedDueToReplStateChange` (11602) | failover or step-down during the operation | election events; driver retry settings — all five codes above are in the server's retryable "not primary" category |
| `AuthenticationFailed` (18) | wrong user, password, mechanism or authentication database | `authSource`, percent-encoding of the password, user `db` |
| `Unauthorized` (13) | logged in, but the role lacks the action | user `roles[]` |
| `UnsatisfiableWriteConcern` (100), `WriteConcernTimeout` (64) | write concern cannot be met, or `wtimeout` expired | members up and voting; after a timeout the write may still have been applied |
| `HostUnreachable` (6), `NetworkTimeout` (89) | connection layer | Service, DNS (Domain Name System), NetworkPolicy, the advertised member names |

## Write and read concerns

- Implicit default write concern is `w: "majority"`, except with arbiters when the non-arbiter members do not exceed
  the voting majority — then it is `w: 1`.
- `w: 1` writes can be rolled back if the primary steps down before a secondary has them.
- `wtimeout` returns a write concern error after the limit but does **not** undo the write. Without it, an
  unreachable write concern blocks forever.
- `j: true` alone does not protect a write from a failover rollback.
- Read concern `local` is the default for primary and secondary reads and may return data that is later rolled back;
  `majority` returns data acknowledged by a majority (durable); `linearizable` is only for reads on the primary.

## Connection strings

| Option | Default | Pitfall |
|---|---|---|
| `replicaSet` | none | set it so every driver behaves the same |
| `directConnection` | `false` — discover all members and send operations to the primary | the driver then switches to the hostnames in the replica set config; through a port-forward to one member those names do not resolve. `true` talks only to the given host (docs: for test or development). `mongosh` adds `directConnection=true` itself for a single host without `replicaSet` or `+srv`, so a shell test can pass where the application's URI fails |
| `authSource` | the database in the URI, else `admin` | a user created in `admin` (the MCK default) fails with `AuthenticationFailed` when the URI names `orders` and no `authSource` |
| `authMechanism` | tries SCRAM-SHA-256, falls back to SCRAM-SHA-1 | |
| `tls` (Transport Layer Security) | `false` for `mongodb://`, `true` for `mongodb+srv://` | `tlsAllowInvalidHostnames=true` disables hostname checks — a vulnerability, not a fix |
| `readPreference` | `primary` | transactions with reads need `primary` |
| `retryWrites` | `true` in official drivers | |
| `serverSelectionTimeoutMS` | 30000 ms | how long the client waits for a usable member before failing |

- Percent-encode `$ : / ? # [ ] @` in the username or password.
- `mongodb+srv://`: exactly one host and no port; hosts in the SRV (DNS service) records must share the parent
  domain; a TXT record may set only
  `replicaSet` and `authSource`.

## Replication lag

- `rs.printSecondaryReplicationInfo()` is for people (run it on the primary for the freshest view); `rs.status()` is
  for scripts.
- Negative lag after an idle period is expected and does not mean a secondary is ahead. A delayed member can show 0
  when the primary has been idle longer than its delay. Lag reported by secondaries may not reflect cluster health —
  confirm with `rs.status()` member states.

## Backup approaches

| Method | Use | Consistency |
|---|---|---|
| Ops Manager / Cloud Manager (or Atlas backups) | Enterprise and hosted deployments | managed by the service |
| Filesystem snapshot | volumes that support point-in-time snapshots | journaling on, journal on the same volume as the data files; sharded: balancer off and every shard plus a config server at about the same moment |
| `cp`/`rsync` of data files | no snapshot support | stop all writes first |
| `mongodump`/`mongorestore` | small deployments | `--oplog` (full dump of a replica-set member) + `mongorestore --oplogReplay` gives one point in time |

- `mongodump --oplog` fails with `--db`, `--collection`, `--query` or `--dumpDbUsersAndRoles`, and does not work
  on a sharded cluster. On sharded clusters pause cross-shard transactions, data definition (DDL) operations and balancing during a dump.
- `mongodump` reads from the primary by default and stores index definitions in each collection's metadata file.
- A password in `--uri` or `--password` can be visible to other users through `ps`: let the tool prompt, or put it in a
  `--config` file with tight permissions.
- Prove a dump by restoring it into a throwaway instance and comparing document counts per collection. A
  `mongorestore` into a shared or production deployment is a live change (approval) with an explicit target host,
  replica set and database.

## Read-only commands

```bash
# Operator CRs and their phase
kubectl --context <ctx> -n shop get mongodbcommunity
kubectl --context <ctx> -n shop get mongodbcommunity rs0 -o jsonpath='{.status}{"\n"}'
# Compare the user's password Secret without printing it
kubectl --context <ctx> -n shop get secret app-a-password -o jsonpath='{.data.password}' | base64 -d | sha256sum
```

From a client pod in the application's namespace, with the application's connection options and the password
prompted for (`--password` with no value), never echoed:

```javascript
// mongosh, connected as the application user
db.hello()                                // isWritablePrimary, primary, hosts, me
rs.status().members.map(m => [m.name, m.stateStr, m.health, m.optimeDate])
rs.printSecondaryReplicationInfo()
db.runCommand({ connectionStatus: 1 })     // authInfo: which user and roles this session really has
```

## Practice (throwaway kind or k3d cluster)

Install MCK from its quickstart, create a three-member `MongoDBCommunity`, then: port-forward to one member and connect
with and without `directConnection=true`; connect as a user created in `admin` with a URI that names another database
and no `authSource`; step down the primary while a write loop runs and watch the retries.

## Verified References

- <https://www.mongodb.com/docs/kubernetes/current/> — MCK 1.13.0 replaces the Community and Enterprise operators;
  Community = database resource only; Enterprise needs Ops Manager or Cloud Manager
- <https://github.com/mongodb/mongodb-kubernetes-operator> — repository deprecated, best-effort support until
  November 2025, archived 12 December 2025, moved to `mongodb/mongodb-kubernetes`
- <https://raw.githubusercontent.com/mongodb/mongodb-kubernetes/1.13.0/docs/mongodbcommunity/users.md> — `spec.users`
  fields and defaults, SCRAM credential Secret, connection-string Secret, password change, deleting the password Secret
- <https://www.mongodb.com/docs/manual/core/replica-set-elections/> — heartbeats, 10 s timeout, 12 s median, no writes
  during elections, driver retry once, 50 members / 7 voting
- <https://www.mongodb.com/docs/manual/reference/command/hello/> — `hello` response fields
- <https://raw.githubusercontent.com/mongodb/mongo/master/src/mongo/base/error_codes.yml> — every error code and name in
  the table and the `NotPrimaryError`/`RetriableError` categories
- <https://www.mongodb.com/docs/manual/reference/write-concern/> — implicit default and arbiter formula, `w: 1`
  rollback, `wtimeout` does not undo writes, `j: true` limits
- <https://www.mongodb.com/docs/manual/reference/read-concern/> — `local`, `majority`, `linearizable` semantics
- <https://www.mongodb.com/docs/manual/reference/connection-string-options/> — option defaults and the
  `tlsAllowInvalidHostnames` warning; percent-encoded characters
- <https://www.mongodb.com/docs/manual/reference/connection-string-formats/> — clients switch to replica-set
  hostnames; SRV rules; default authentication database
- <https://www.mongodb.com/docs/manual/reference/method/rs.printSecondaryReplicationInfo/> — manual vs script use,
  negative lag, delayed members
- <https://www.mongodb.com/docs/manual/core/backups/> — backup methods and their consistency requirements
- <https://www.mongodb.com/docs/database-tools/mongodump/> — `--oplog` rules, password exposure and `--config`,
  sharded-cluster pauses, default read preference, index definitions
- <https://www.mongodb.com/docs/mongodb-shell/reference/options/> — `mongosh` prompts for a password when `--password`
  has no value
- <https://www.mongodb.com/docs/mongodb-shell/connect/> — `mongosh` adds `directConnection=true` for individual
  members unless `replicaSet`, `+srv`, several seed hosts or an explicit `directConnection` is given
- <https://www.mongodb.com/docs/manual/reference/command/replSetGetStatus/> — `members[].name`, `stateStr`, `health`,
  `optimeDate`
- <https://www.mongodb.com/docs/manual/reference/command/connectionStatus/> — `authInfo` users and roles of the session
