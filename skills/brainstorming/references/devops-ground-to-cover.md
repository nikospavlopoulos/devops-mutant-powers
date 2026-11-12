# Infrastructure ground to cover

**In plain terms:** the questions an infrastructure change has to answer before anyone builds it. `brainstorming` uses
them as territory while it draws out what your human partner wants; `grilling` turns the ones still open into
numbered questions. Never read the list out as a checklist, and find what you can in the repository or the pasted
material first.

- **Problem and success:** what is broken or missing today, and what success looks like to them and to their users.
- **Current state and owner:** look it up first; ask only what the repository cannot tell you.
- **Scale and constraints:** traffic, data size, team, environments; cloud provider, cost, compliance, existing stack.
- **Environments and staging order:** where it lands first, and what must be true before production.
- **Blast radius:** what breaks if this goes wrong, and for whom.
- **Reversibility:** the rollback, the restore, and the point of no return (the step after which going back means a
  restore, not a rollback). Flag irreversible steps out loud.
- **Gradual rollout:** staging first, a canary, one environment or one tenant at a time.
- **Proof:** how success is shown through the real user path, not a green status.
- **Watching the change:** which dashboard or alert shows it working or breaking while it rolls out, and who watches
  it.
- **Data safety:** a backup or restore point before any step that cannot be undone, and whether a restore from it was
  ever tested.
- **Secrets and access:** which credentials it needs, where they live, who gets access.
- **Change window and approver:** when it may happen, and who says yes.
- **Anti-goals:** "it works but sessions drop", "backups exist but no restore was ever tested", "the cutover finished
  but nobody can roll it back".

Every option you weigh should prefer the reversible path, name its blast radius, roll out in steps, and skip design
for scale nobody has asked for. In an existing environment, follow its patterns, fix what gets in the way of this
goal, and leave unrelated refactoring out.
