# Reviewer brief (shared by every batch reviewer)

You are a REVIEWER for writer changes in the worktree and branch named in your assignment (uncommitted working-tree
changes for the skills you are given). You may fix problems directly in those skill directories; never commit and
never run git commands that write. Same hard rules as `writer-common.md` (read it): no cluster/cloud CLIs
(`KUBECONFIG=/nonexistent`), never open `evals/`, `tests/test_runs/` or `*-scenarios.md`, no secrets.

Check, per skill (`git diff -- skills/<skill>` plus new files):
1. **Accuracy:** sample the riskiest claims (numbers, defaults, flags, version behaviour) and re-verify each against
   its cited official URL (WebFetch/context7). Fix or delete anything unsupported.
2. **Public-ready:** no company/client/person/"my stack" framing, no hostnames outside RFC 2606/5737, no reasons for
   tool choice.
3. **Shape:** frontmatter unchanged unless assigned (description ≤ 300 chars); existing Core Rules not reworded;
   an `## Output Contract` with domain-specific proof / owner / approval / durability items; new references indexed
   with "when to load"; state-changing commands marked (approval); explicit targets on commands.
4. **Fit:** no duplication with existing text; SKILL.md growth proportionate (depth in references); every
   `devops-mutant-powers:<skill>` cross-reference names a skill that exists under `skills/`.
5. Run `bash tests/validate.sh` (ALL OK) and `bash scripts/scan-sensitive.sh --tree` (clean) at the end.

Reply in ≤ 30 lines: per skill PASS / FIXED (what) / BLOCK (why), the claims you re-verified with URLs, and residual
doubts.
