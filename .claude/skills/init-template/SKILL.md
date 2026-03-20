---
name: init-template
description: Create a cloud-init template for MPS sandboxes (personal or project-shared).
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Create MPS Cloud-Init Template

Interactive skill that guides developers through creating a cloud-init template and sandbox configuration for MPS. Templates are always based on the shipped default template (`templates/cloud-init/default.yaml`).

## Conventions

- **[INTERNAL]** blocks are instructions for you (Claude). Never show their content to the developer.
- **Always use the `AskUserQuestion` tool** for questions. Never ask questions as inline text — the developer expects interactive menus they can navigate.
- Use `multiSelect: true` when the developer can pick multiple options (e.g., plugins).
- Batch related questions into a single `AskUserQuestion` call when they're independent (up to 4 questions per call).

## Workflow

Follow these steps in order.

### Step 1 — Determine scope

Use `AskUserQuestion` to ask:

**Question 1** — "What scope should this template have?"
- **Personal**: Stored at `~/mps/cloud-init/<name>.yaml`, applies to all your sandboxes unless overridden per-project. Not checked into any repo.
- **Project**: Stored at `<project>/.mps/<name>.yaml`, checked into git and shared with the team.

If **project** scope, use `AskUserQuestion` to ask two follow-up questions:
1. Which project directory to configure.
2. A template name — "What should this template be called? This name appears in the sandbox name (`<project>-<template>`), so pick something descriptive." Suggest a sensible default based on the project (e.g., `dev`, `audit`, `testnet`).

> [INTERNAL] Do NOT assume CWD is the target project — the developer may be running this skill from the MPS repo while configuring a different project.
>
> The template name becomes the filename (`<project>/.mps/<name>.yaml`) and the value for `MPS_CLOUD_INIT` in `.mps.env` (e.g., `MPS_CLOUD_INIT=.mps/dev.yaml`). It flows into the sandbox auto-naming as the template component. Suggest short, lowercase, descriptive names without spaces or special characters. IMPORTANT: Never include the `mps-` prefix in user-facing output — the prefix is an internal implementation detail that users never see.

If **personal** scope, use `AskUserQuestion` to ask for a template name (e.g., `personal`, `security`, `web-dev`) with the same note about auto-naming.

> [INTERNAL] The name becomes the filename (`~/mps/cloud-init/<name>.yaml`) and the value for `MPS_DEFAULT_CLOUD_INIT` in `~/mps/config`.

### Step 2 — Choose target image flavor

Use `AskUserQuestion`:

**Question** — "Which pre-built image flavor should this sandbox use?"
- `base` — Ubuntu 24.04 + Docker + Node.js + Python + dev tools + AI assistants (min: micro)
- `protocol-dev` — base + C/C++ toolchain + Go + Rust (min: lite)
- `smart-contract-dev` — protocol-dev + Solana/Anchor (amd64) + Foundry + Hardhat (min: lite)
- `smart-contract-audit` — smart-contract-dev + Slither + Echidna + Medusa + more (min: standard)

> [INTERNAL] After the developer chooses, silently read the corresponding layer file(s) from `images/layers/` to build awareness of pre-installed packages. Each flavor includes everything from its parent:
>
> - `base` → read `images/layers/base.yaml`
> - `protocol-dev` → read `images/layers/base.yaml` + `images/layers/protocol-dev.yaml`
> - `smart-contract-dev` → read all three above + `images/layers/smart-contract-dev.yaml`
> - `smart-contract-audit` → read all four layer files
>
> Extract the `packages:` lists and review the corresponding install scripts in `images/scripts/install-*.sh` for tool installations. Use this knowledge to warn if the developer tries to install something already baked in.

### Step 3 — Read the default template

> [INTERNAL] Read `templates/cloud-init/default.yaml`. This is the starting base for every generated template. Parse its structure to understand:
>
> - The active `runcmd:` section with HorizenLabs plugin installs (enabled by default)
> - The commented-out sections: Trail of Bits, GSD, SuperClaude, Superpowers, BMAD, GitHub Spec Kit
> - The commented-out `packages:`, `write_files:`, `hostname:`, `timezone:` sections
>
> Do not tell the developer you're reading this — just proceed to step 4 with the knowledge.

### Step 4 — Guide cloud-init customization

#### 4a. Claude Code plugins and frameworks

> [INTERNAL] `AskUserQuestion` supports max 4 options per question and max 4 questions per call. Free-text "Other" answers conflict with `multiSelect` — avoid combining them. Split plugins/frameworks across multiple single-select questions instead.
>
> The install commands for each framework are in the default template's commented-out `runcmd:` blocks. Copy them exactly when enabling — do not paraphrase or rewrite. The commands, paths, and flags are tested and correct.

Use `AskUserQuestion` with up to 4 questions in a single call (all single-select, no `multiSelect`):

**Question 1** — "Enable HorizenLabs product ideation skills?" (discovery workflow, market research, PRD generator, tech specs, personas, user flows, stakeholder decks, mockup briefs)
- **Yes** — Install `hl-product-ideation`
- **No** — Skip

**Question 2** — "Enable zkVerify development skills?" (proof submission, SDK, smart contracts, RPC, pallet dev, Groth16/FFLONK/SP1/Noir/RISC Zero/Plonky2/EZKL builders)
- **Yes** — Install `zkverify-product-development`
- **No** — Skip

**Question 3** — "Enable zkVerify verifier assessment skills?" (Rust stable toolchain compat, no_std support, verifier pallet integration feasibility)
- **Yes** — Install `zkverify-verifier-assessment`
- **No** — Skip

**Question 4** — "Enable context handoff utilities?" (save/resume work across sessions)
- **Yes** — Install `context-utils`
- **No** — Skip

Then a second `AskUserQuestion` call for third-party plugins and frameworks:

**Question 1** — "Enable Trail of Bits security skills?" (~20 security-focused plugins)
- **All** — Install all ~20 Trail of Bits plugins
- **Pick a subset** — Choose specific plugins in the next step
- **No** — Skip Trail of Bits

**Question 2** — "Enable GSD framework?" (meta-prompting and spec-driven development)
- **Yes** — Enable GSD
- **No** — Skip

**Question 3** — "Enable SuperClaude framework?" (slash commands and MCP servers)
- **Yes** — Enable SuperClaude
- **No** — Skip

**Question 4** — "Enable Superpowers?" (plugin marketplace skills)
- **Yes** — Enable Superpowers
- **No** — Skip

Then a third `AskUserQuestion` call for remaining frameworks:

**Question 1** — "Enable BMAD Method?" (spec-driven development methodology)
- **Yes** — Enable BMAD
- **No** — Skip

**Question 2** — "Enable GitHub Spec Kit?" (spec-driven CLI for AI coding agents)
- **Yes** — Enable Spec Kit
- **No** — Skip

> [INTERNAL] If the developer selected "Pick a subset" for Trail of Bits, list all ~20 plugin names from the default template and ask them to specify which ones they want. Use a follow-up text question for this since there are too many options for `AskUserQuestion`.

#### 4b–4e. Additional customization

Use `AskUserQuestion` with 4 single-select questions in one call:

**Question 1** — "Need extra apt packages?" (e.g., postgresql-client, redis-tools, nmap)
- **Yes** — I'll specify packages next
- **No** — Skip

**Question 2** — "Need custom first-boot commands?" (e.g., install pip/npm packages, clone repos, run setup scripts)
- **Yes** — I'll specify commands next
- **No** — Skip

**Question 3** — "Need config files dropped into the VM?" (e.g., .env files, tool configs)
- **Yes** — I'll specify files next
- **No** — Skip

**Question 4** — "Set a timezone for the sandbox?"
- **UTC (Recommended)** — Consistent across all machines
- **Inherit from host** — Use whatever the host machine is set to
- **No** — Skip

> [INTERNAL] For each "Yes" answer, follow up with a text-based `AskUserQuestion` (single question, let them type via "Other"):
>
> - **Packages**: Ask which packages. If any are already in the target image layer (from step 2), tell them it's pre-installed and skip it.
> - **Run commands**: Ask what commands to run.
> - **Config files**: Ask for paths and content. Remind about `owner: ubuntu:ubuntu` and `permissions: '0600'` for sensitive files.
> - **Timezone Q4**: For **project** templates, make "UTC" the first/recommended option. For **personal** templates, make "Inherit from host" the first/recommended option.
>
> If the developer answers "No" to all, skip straight to step 5.

### Step 5 — Generate the cloud-init YAML

> [INTERNAL] Build the template starting from the default template's structure:
>
> 1. Always start with `#cloud-config` header
> 2. Add a comment identifying it as generated (e.g., `# Generated by /init-template — based on default.yaml`)
> 3. If packages were requested, add an active `packages:` section (uncommented)
> 4. Build the `runcmd:` section:
>    - Include enabled plugins/frameworks (uncommented from the default template — copy the exact `sudo -u ubuntu bash -c '...'` blocks)
>    - Do NOT include commented-out sections the developer didn't select
>    - Add any custom runcmd entries
> 5. If write_files were requested, add an active `write_files:` section
> 6. Add hostname/timezone if requested
>
> **Important**: Copy the exact command blocks from the default template for plugins/frameworks — do not paraphrase or rewrite them.

### Step 6 — Write the template file

> [INTERNAL]
>
> - **Personal**: Write to `~/mps/cloud-init/<name>.yaml`. Create the directory if it doesn't exist (`mkdir -p`).
> - **Project**: Write to `<project-dir>/.mps/<name>.yaml`. Create the `.mps/` directory if it doesn't exist (`mkdir -p`).

### Step 7 — Configure sandbox settings

#### For project scope

Use `AskUserQuestion` to ask about sandbox settings for `.mps.env`:

**Question 1** — "Which resource profile should this project use?"
- `micro` — 1/8 CPU, 1/16 mem (lightweight tasks)
- `lite` — 1/4 CPU, 1/6 mem (default, most development)
- `standard` — 1/3 CPU, 1/4 mem (recommended for smart-contract-audit)
- `custom` — Set CPU, memory, and disk manually

> [INTERNAL] Suggest the minimum profile from the image metadata as the recommended option. `heavy` (1/2 CPU, 1/3 mem) is available too — if there are only 4 slots, drop `micro` and keep `heavy` when the image min profile is `lite` or higher.
>
> If the developer selects **custom**, follow up with `AskUserQuestion` asking 3 questions:
> - "How many vCPUs?" — options: `2`, `4`, `8`, `Custom` (type a number)
> - "How much memory?" — options: `4G`, `8G`, `16G`, `Custom` (type a value like `12G`)
> - "How much disk?" — options: `20G`, `40G`, `75G`, `Custom` (type a value like `100G`)
>
> Write the custom values as `MPS_CPUS`, `MPS_MEMORY`, `MPS_DISK` in `.mps.env` (no profile needed).

**Question 2** — "Do you need port forwarding? If so, which host:guest pairs?" (use AskUserQuestion with an "Other" option so they can type ports, or offer common presets like `3000:3000`, `8080:8080`)

**Question 3** — "Do you need extra mounts beyond the auto-mount?" (CWD is mounted automatically)

**Question 4** — "Do you want a fixed sandbox name or auto-naming?"
- **Auto-naming (Recommended)** — Named from folder + template
- **Fixed name** — Always use the same name for this project's sandbox

> [INTERNAL] Always set these in `.mps.env` (they ensure all developers use the same sandbox configuration):
> - `MPS_CLOUD_INIT=.mps/<name>.yaml` (using the template name from step 1)
> - `MPS_PROFILE=<chosen profile>` — ALWAYS set this, even if it's `lite`. Personal `~/mps/config` defaults could override a missing profile, causing different devs to get different instance specs. Pinning the profile in `.mps.env` prevents "works on my machine" issues.
> - `MPS_IMAGE=<flavor>` — ALWAYS set this, even if it's `base`. Same reason as profile — a developer's personal config could override the default, putting them on a different image than the rest of the team.
>
> Only write other settings (ports, mounts, name) if they differ from defaults. Comment out optional settings with explanations.
>
> Mention: if `.mps.env` contains developer-specific overrides (like `MPS_NAME`), consider adding it to `.gitignore` and committing only `.mps/<name>.yaml`. Alternatively, commit `.mps.env` with shared defaults and let developers override via `~/mps/config`.

#### For personal scope

Use `AskUserQuestion`:

**Question** — "Set this as your default template? It will apply to all new sandboxes unless a project overrides it with its own `.mps.env`."
- **Yes** — Set as default in `~/mps/config`
- **No** — Save the template but don't change defaults. Use it explicitly with `--cloud-init <name>`.

> [INTERNAL] If yes, update `~/mps/config` (create if needed) to set `MPS_DEFAULT_CLOUD_INIT=<name>`. If the file already has a `MPS_DEFAULT_CLOUD_INIT` line, replace it. Mention what the previous default was (if any) so the developer knows what changed.
>
> If no, just confirm the template was saved and remind them how to use it: `mps create --cloud-init <name>` or `MPS_DEFAULT_CLOUD_INIT=<name>` in `~/mps/config` later.

Then ask if they want to configure other personal defaults in `~/mps/config`:

**Question** — "Want to set any other personal defaults in `~/mps/config`? These apply to all sandboxes unless overridden per-project."
- **Yes** — Configure additional defaults
- **No** — Skip, move on

> [INTERNAL] If yes, use `AskUserQuestion` calls to walk through the same settings as the project `.mps.env` flow — but framed as personal defaults:
>
> **Question 1** — "Default image flavor?"
> - `base` (current default)
> - `protocol-dev`
> - `smart-contract-dev`
> - `smart-contract-audit`
>
> **Question 2** — "Default resource profile?"
> - `micro`, `lite` (current default), `standard`, `heavy`
>
> **Question 3** — "Default port forwarding?" (e.g., `3000:3000 8080:8080`)
> - **None (Recommended)** — No default ports
> - **Yes** — Specify ports (let them type via "Other")
>
> **Question 4** — "Disable CLI update checks?"
> - **No (Recommended)** — Keep update checks enabled
> - **Yes** — Set `MPS_CHECK_UPDATES=false`
>
> Only write settings that differ from defaults. If `~/mps/config` already exists, read it first and preserve existing values the developer doesn't change. Add comments for each setting.

### Step 8 — Print summary

Show what was created:
- Template file path and what's enabled in it
- Config file path and what was set
- How to use it: `mps up` (project) or `mps create` (any directory, for personal)
- How to test: `mps create --profile micro --name test-template && mps destroy --force --name test-template`
