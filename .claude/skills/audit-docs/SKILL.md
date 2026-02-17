---
name: audit-docs
description: Audit planning docs (CLAUDE.md, .planning/*, .github/CI.md) for staleness and context bloat. Run before/after commits.
allowed-tools: Read, Glob, Grep, Bash, Task
---

# Audit Planning Docs

Audit documentation for staleness, missing entries, and context window bloat. Report every discrepancy found.

## Documents

| Doc | Purpose | Loaded at session start? |
|---|---|---|
| `CLAUDE.md` | Project structure, commands, conventions, build system | Yes (auto) |
| `.planning/DECISIONS.md` | Architecture decisions, reference tables | Yes (manual) |
| `.planning/STATUS.md` | Phase completion status | Yes (manual) |
| `.planning/PLAN.md` | Phase descriptions (brief summaries + future phases) | Yes (manual) |
| `.github/CI.md` | CI/CD pipeline design (code reviewer reference) | No (skip — audit only when CI changes) |

## Audit Steps

### 1. Uncommitted Changes (highest priority)

```
git diff --name-status          # unstaged changes
git diff --cached --name-status # staged changes
```

Any file touched here that maps to a doc section should be checked immediately. Apply the same rules as step 2.

### 2. Git History Audit

```
git log --oneline --name-status HEAD~10..HEAD
```

Focus on the last ~10 commits. If `$ARGUMENTS` is provided, use it as the commit range instead.

For each commit (newest first), flag if it:
- **Adds/removes/renames files** in `images/`, `bin/`, `lib/`, `commands/`, `templates/`, `config/`, `docker/` — check CLAUDE.md Project Structure
- **Modifies Makefile** — check CLAUDE.md Build System targets
- **Modifies `Dockerfile.*`** — check DECISIONS.md Secure Dependency Installation table
- **Modifies `images/layers/*.yaml`** — check DECISIONS.md Image Layer Contents
- **Modifies `images/build.sh`** — check DECISIONS.md Image Flavors table
- **Modifies `images/publish.sh` or `images/update-manifest.sh`** — check DECISIONS.md Image Distribution
- **Modifies `images/packer.pkr.hcl`** — check DECISIONS.md Image Flavor Metadata (disk sizes)
- **Adds/removes commands** in `commands/*.sh` — check CLAUDE.md Commands section
- **Modifies `images/manifest.json`** — check DECISIONS.md Image Flavors table
- **Modifies `config/defaults.env`** — check DECISIONS.md for referenced `MPS_*` vars
- **Modifies `.github/workflows/*.yml`** — check `.github/CI.md` still matches (only if workflows were actually changed; skip otherwise)

### 3. File Path Verification

Extract every file/directory path referenced in docs. Verify each exists in the repo. Also check for recently deleted/renamed files:

```
git log --diff-filter=DR --name-status HEAD~10..HEAD
```

Flag paths that point to moved, renamed, or deleted files.

### 4. Project Structure Completeness (CLAUDE.md)

Compare CLAUDE.md "Project Structure" section against the actual repo:

```
ls bin/ lib/ commands/ templates/ images/ config/ docker/ *.sh Makefile Dockerfile.* .yamllint checkmake.ini
```

- Flag files that exist but aren't documented, and vice versa
- Ignore: `.git/`, `.gitignore`, `.gitmodules`, `README.md`, `.planning/`, `.claude/`, `vendor/`, `packer_cache/`, stamp files, build artifacts

### 5. Build System Targets (CLAUDE.md)

Compare `make` targets in CLAUDE.md Build System section against actual Makefile. Ignore internal/stamp targets, per-arch variants that follow obvious patterns, and clean targets.

### 6. Tool & Package Lists (DECISIONS.md)

Cross-reference DECISIONS.md "Image Layer Contents" against actual `images/layers/*.yaml` files. Extract `packages:` lists and `runcmd` tool names. Flag missing or extra entries.

### 7. Secure Dependency Installation (DECISIONS.md)

Check the "Secure Dependency Installation" table against `Dockerfile.builder`, `Dockerfile.linter`, `Dockerfile.publisher`, and `images/layers/*.yaml`. Flag tools installed but missing from the table, or listed but no longer installed.

### 8. Image Flavor Consistency (DECISIONS.md)

Cross-reference three sources of truth: `images/build.sh` (case statement), `images/manifest.json` (registry entries), DECISIONS.md "Image Flavors" table. All must agree on flavor names, layer composition, and ordering.

### 9. Config Variable Cross-Reference

Extract `MPS_*` variable names from DECISIONS.md and CLAUDE.md. Verify each exists in `config/defaults.env`. Flag variables documented but missing, or present in defaults.env but not mentioned anywhere.

### 10. Commands Audit (CLAUDE.md)

Three sources of truth: `commands/*.sh` (exported `cmd_*` functions), `bin/mps` (usage text), CLAUDE.md "Commands" section. All three must agree.

### 11. Phase Status (STATUS.md + PLAN.md)

- Flag STATUS.md completed items that reference stale file paths
- Check if "NOT STARTED" phases have had work done (check git log for relevant files)
- Verify STATUS.md phase list matches PLAN.md phase list

### 12. Context Optimization

This step monitors doc health for context window efficiency. The session-start docs (CLAUDE.md + .planning/*) are loaded into every conversation.

**Size check**: Report line counts and byte sizes for each session-start doc. Flag if total exceeds 500 lines or 30KB.

**Duplication check**: Scan for information that appears in both CLAUDE.md and DECISIONS.md. CLAUDE.md is the primary reference for conventions and structure; DECISIONS.md should only contain decisions and reference tables not already covered by CLAUDE.md. Flag any section in DECISIONS.md that substantially duplicates CLAUDE.md content.

**Relevance check**: Flag DECISIONS.md sections where:
- The decision is trivial (one-line answers that could be inline comments in code)
- The section hasn't been relevant to any commit in the last 20 commits
- The content describes "how" (implementation details in the code) rather than "what/why" (decisions that guide future work)

**STATUS.md bloat check**: Flag phases marked COMPLETE that have more than 3 lines of detail. Completed phases should be brief — the code is the record.

## Output Format

```
## CLAUDE.md
- [Section] Issue description

## DECISIONS.md
- [Section] Issue description

## STATUS.md
- Issue description

## PLAN.md
- Issue description

## Context Optimization
- [Size] Total: N lines / N KB (over/under budget)
- [Duplication] DECISIONS.md "Section X" duplicates CLAUDE.md "Section Y"
- [Relevance] DECISIONS.md "Section X" — no related commits in last 20; consider archiving
- [Bloat] STATUS.md Phase N — N lines of detail for completed phase
```

If no issues found for a document, report "(no issues)".

End with: `N issues found across M documents`.
