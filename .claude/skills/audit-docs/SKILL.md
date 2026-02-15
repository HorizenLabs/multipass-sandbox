---
name: audit-docs
description: Audit planning docs (CLAUDE.md, .planning/*) for staleness against the actual repo structure and recent git history. Run after refactoring, file moves, or feature additions.
allowed-tools: Read, Glob, Grep, Bash, Task
---

# Audit Planning Docs

Audit all planning documentation for staleness, stale references, and missing entries. Report every discrepancy found.

## Documents to Audit

- `CLAUDE.md` — Project structure, commands, conventions, build system
- `.planning/DECISIONS.md` — Architecture decisions, tool lists, verification tables
- `.planning/STATUS.md` — Phase completion status
- `.planning/PLAN.md` — Phase descriptions

## Audit Steps

### 1. Uncommitted Changes (highest priority)

Check the working tree and staging area FIRST — these are the changes about to be committed and most likely to have introduced staleness:

```
git diff --name-status          # unstaged changes
git diff --cached --name-status # staged changes
```

Apply the same rules as the git history audit below, but treat these as the **most important** signals. Any file touched here that maps to a doc section should be checked immediately.

### 2. Git History Audit

Check recent commits for changes that could affect docs, **most recent first**:

```
git log --oneline --name-status HEAD~10..HEAD
```

Focus on the last ~10 commits. If `$ARGUMENTS` is provided, use it as the commit range instead. Older commits are lower priority — assume prior runs of `/audit-docs` already caught those.

For each commit (newest first), flag if it:
- **Adds/removes/renames files** in `images/`, `bin/`, `lib/`, `commands/`, `templates/`, `config/`, `docker/` — these should be reflected in CLAUDE.md Project Structure
- **Modifies Makefile** — check if CLAUDE.md Build System examples still match actual targets
- **Modifies Dockerfile.builder or Dockerfile.linter** — check DECISIONS.md Secure Dependency Installation table
- **Modifies `images/layers/*.yaml`** — check DECISIONS.md Image Layer Contents section matches actual packages/tools
- **Modifies `images/packer.pkr.hcl`** — check DECISIONS.md Image Disk Sizing, QCOW2 extension, etc.
- **Adds/removes commands** in `commands/*.sh` — check CLAUDE.md Commands section
- **Modifies `images/manifest.json`** — check DECISIONS.md Image Flavors table
- **Modifies `config/defaults.env`** — check DECISIONS.md for referenced config variables (`MPS_*` vars)
- **Modifies `templates/cloud-init/*.yaml`** — check DECISIONS.md Cloud-init Template Restructure and AI Coding Assistants sections
- **Modifies `images/build.sh`** — check DECISIONS.md Image Flavors table (flavor-to-layer mapping)
- **Modifies `images/publish.sh`** — check DECISIONS.md Image Distribution section

### 3. File Path Verification

Extract every file/directory path referenced in the docs. For each path:
- Verify it exists in the repo (use `Glob` or `ls`)
- Flag paths that point to moved, renamed, or deleted files

Also check `git log --diff-filter=DR --name-status HEAD~10..HEAD` for recently deleted/renamed files and verify no doc still references them.

### 4. Project Structure Completeness (CLAUDE.md)

Compare CLAUDE.md "Project Structure" section against the actual repo:

```
# Check for significant files/dirs not listed in CLAUDE.md
ls bin/ lib/ commands/ templates/ images/ config/ docker/ *.sh Makefile Dockerfile.* .yamllint checkmake.ini
```

- Flag files that exist but aren't documented
- Flag documented files that don't exist
- Ignore: `.git/`, `.gitignore`, `.gitmodules`, `README.md`, `.planning/`, `.claude/`, `vendor/`, `packer_cache/`, stamp files, build artifacts

### 5. Build System Targets (CLAUDE.md)

Extract `make` targets shown in CLAUDE.md Build System section. Compare against actual Makefile:

```
grep -E '^[a-zA-Z0-9_-]+:' Makefile
```

- Flag example targets that don't exist in the Makefile
- Flag significant Makefile targets (image builds, publish, import) missing from docs
- Ignore internal/stamp targets, per-arch variants that follow obvious patterns, and clean targets

### 6. Tool & Package Lists (DECISIONS.md)

Cross-reference DECISIONS.md "Image Layer Contents" against actual layer files:

- Read each `images/layers/*.yaml`
- Extract `packages:` lists and `runcmd` tool names
- Compare against what DECISIONS.md claims each layer contains
- Flag missing or extra entries

### 7. Verification Tables (DECISIONS.md)

Check the "Secure Dependency Installation" and "Cloud-init Dependency Verification" tables:

- Read `Dockerfile.builder`, `Dockerfile.linter`, and `images/layers/*.yaml`
- Verify each tool listed in the tables is actually installed
- Flag tools that are installed but missing from the tables

### 8. Image Flavor Consistency (DECISIONS.md)

Cross-reference three sources of truth for image flavors:

- `images/build.sh` — the `case` statement mapping flavors to layer files
- `images/manifest.json` — the image registry entries
- DECISIONS.md "Image Flavors" table — the documented flavor/layer mapping

All three must agree on: flavor names, which layers each flavor includes, and layer ordering.

### 9. Config Variable Cross-Reference (DECISIONS.md)

Check that config variables referenced in DECISIONS.md exist in `config/defaults.env`:

- Extract `MPS_*` variable names from DECISIONS.md sections (Image Distribution, Mount Behavior, SSH Key Management, etc.)
- Verify each exists in `config/defaults.env`
- Flag variables documented but missing, or present in defaults.env but not mentioned anywhere in docs

### 10. DECISIONS.md Internal Consistency

Check for contradictions between sections within DECISIONS.md:

- Verify that tool/layer assignments in the "Solidity Security Tools" and "AI Coding Assistants" tables match the "Image Layer Contents" section
- Verify that disk sizes, file extensions, and other specifics are consistent across sections
- Check that the "Image Flavors" table agrees with the "Image Layer Contents" section on what each layer provides

### 11. Commands Audit (CLAUDE.md + bin/mps)

Three sources of truth for commands:

- `commands/*.sh` — extract exported `cmd_*` function names
- `bin/mps` — extract the usage text command list (the `mps_usage()` function)
- CLAUDE.md "Commands" section

All three must agree. Flag commands that exist in one source but not another.

### 12. Phase Status (STATUS.md)

- Check if STATUS.md phase descriptions match PLAN.md
- Flag completed items that reference stale file paths
- Check if "NOT STARTED" phases have actually had work done (check git log for relevant files)

## Output Format

Report findings grouped by document:

```
## CLAUDE.md
- [Project Structure] Missing: `path/to/file` (exists in repo but not listed)
- [Build System] Stale target: `make target-name` (not in Makefile)
- [Commands] Mismatch: bin/mps usage lists `foo` but CLAUDE.md does not

## DECISIONS.md
- [Image Layer Contents] base layer: `tool-name` in layers/base.yaml but not listed
- [Image Flavors] build.sh maps `flavor-x` to different layers than DECISIONS.md table
- [Internal Consistency] Section X says tool is in layer A, but Image Layer Contents says layer B

## STATUS.md
- (no issues)

## PLAN.md
- [Phase N] Description conflicts with DECISIONS.md (detail)
```

If no issues are found for a document, report "(no issues)".

End with a summary count: `N issues found across M documents`.
