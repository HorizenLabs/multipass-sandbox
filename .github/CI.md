# GitHub Actions CI/CD Pipeline

## Context

The mpsandbox project uses a fully containerized build system (Makefile + Docker) with GitHub Actions CI/CD for lint/test on push/PR, image build/publish on tag push + weekly cron, and tool releases. WarpBuild runners provide native KVM for fast QEMU builds on amd64; arm64 runners lack KVM, so arm64 builds use TCG emulation with a parallel from-scratch strategy.

## Workflows

1. `.github/workflows/ci.yml` — lint + test + e2e
2. `.github/workflows/images.yml` — image build + publish + CF cache purge
3. `.github/workflows/release.yml` — tool release
4. `.github/workflows/update-submodule.yml` — automated submodule update PRs

## Workflow 1: `ci.yml` — Lint + Test

**Triggers**: Push to `main`, PRs to `main` (excludes tags)
**Runner**: `warp-ubuntu-latest-x64-2x`
**Concurrency**: Cancel in-progress runs per-ref

**Permissions**: `contents: read`, `pull-requests: write` (for PR coverage comments)

### Job: `lint-and-test` (always runs)
Runner: `warp-ubuntu-latest-x64-2x` — Environment: *(none)*

Steps:
1. `actions/checkout@v6` (no submodules — lint/test don't need them)
2. `make lint` (builds linter Docker image automatically via stamp dep)
3. `make test` (runs all tests with coverage; enforces 90% minimum threshold via `coverage-report.sh`)
4. Coverage job summary — appends `coverage/summary.md` to `$GITHUB_STEP_SUMMARY` (all events)
5. Coverage PR comment — `zgosalvez/github-actions-report-lcov@v4` posts/updates a coverage summary comment on PRs (`GITHUB_TOKEN`, `minimum-coverage: 90`, `update-comment: true`). PR events only.
6. Upload `coverage/` directory as artifact (30-day retention)

### Job: `changes` (always runs)
Runner: `warp-ubuntu-latest-x64-2x` — Environment: *(none)*

Detects whether the commit(s) include e2e-affecting changes. Runs on both push and PR events. Uses `.github/scripts/ci-detect-e2e.sh` which:
1. Runs `.github/scripts/e2e-image-drift.sh` — compares HEAD against the latest `images/v*` tag for image-affecting paths (`images/layers/`, `images/scripts/`, `images/build.sh`, `images/packer.pkr.hcl`, `images/packer-user-data.pkrtpl.hcl`, `images/arch-config.sh`, `vendor/`)
2. Checks for `templates/cloud-init/` changes (via `gh api` for PRs, `git diff` for pushes)

Outputs:
- `needs_e2e` — true if any e2e-triggering change detected (cloud-init OR image drift)
- `needs_image_build` — true if image-affecting files changed (requires local image build)

### Job: `build-and-e2e` (conditional, needs: lint-and-test + changes)
Runner: `warp-ubuntu-latest-x64-4x` — Environment: `build`

Runs when `needs_image_build == true` AND the event is a push to main or a same-repo PR (checked via `github.event.pull_request.head.repo.full_name == github.repository`). Fork PRs are excluded — they don't get `build` environment secrets. Checks out with submodules (uses `SUBMODULE_DEPLOY_KEY`), builds the base image locally via `make image-base-amd64`, then runs E2E against the local artifact with `MPS_E2E_IMAGE`.

### Job: `e2e` (conditional, needs: lint-and-test + changes)
Runner: `warp-ubuntu-latest-x64-2x` — Environment: *(none)*

Runs when `needs_e2e == true` AND `needs_image_build != true` (CDN image is sufficient). No submodules, no secrets — E2E pulls the base image from the public CDN registry. Uses `MPS_E2E_INSTALL=true` to install multipass+jq on the runner. Validates that cloud-init templates work against the current published image.

## Workflow 2: `images.yml` — Build + Publish

**Triggers**:
- `images/v*` tag push → build all flavors at tag version
- Weekly cron (Sunday 03:00 UTC) → rebuild at latest `images/v*` tag
- `workflow_dispatch` → optional `version` and `flavors` inputs

**Concurrency**: `group: images`, `cancel-in-progress: false` (builds are long, don't cancel)

### GPG Tag Verification (shared by images.yml and release.yml)

Both `images.yml` and `release.yml` verify the triggering tag is GPG-signed by an authorized maintainer before any work begins. This runs as the first step of the `resolve` job (images) or the `release` job (release).

**Mechanism:**
- `MAINTAINER_KEYS` — GitHub Actions **repository variable** (not secret). Space-separated full GPG fingerprints. Configured at Settings > Secrets and variables > Actions > Variables.
- Public keys fetched by fingerprint from keyservers with fallback chain: `keys.openpgp.org` → `keyserver.ubuntu.com` → `pgp.mit.edu` → `keys.gnupg.net`
- `git verify-tag $TAG` checks the signature; then the signing key's fingerprint is validated against `MAINTAINER_KEYS`
- Workflow fails immediately if the tag is unsigned or signed by an unknown key
- **All triggers verify**: tag push verifies the pushed tag; cron/dispatch resolve the latest `images/v*` tag (or `images/v<input>`), checkout that ref, and verify its signature. This is defense-in-depth — catches tampered/force-pushed tags.

```bash
# Import each maintainer key from keyservers (try multiple)
KEYSERVERS="keys.openpgp.org keyserver.ubuntu.com pgp.mit.edu keys.gnupg.net"
for fpr in $MAINTAINER_KEYS; do
  imported=false
  for ks in $KEYSERVERS; do
    if gpg --keyserver "$ks" --recv-keys "$fpr" 2>/dev/null; then
      imported=true; break
    fi
  done
  if [[ "$imported" != "true" ]]; then
    echo "::error::Failed to import key $fpr from any keyserver"
    exit 1
  fi
done

# Verify the tag signature
TAG="${GITHUB_REF#refs/tags/}"
if ! git verify-tag "$TAG" 2>/dev/null; then
  echo "::error::Tag $TAG is not GPG-signed or signature is invalid"
  exit 1
fi

# Extract signing key fingerprint and check against allowed list
SIGNING_FPR="$(git verify-tag --raw "$TAG" 2>&1 | grep '^\[GNUPG:\] VALIDSIG' | awk '{print $3}')"
if ! echo " $MAINTAINER_KEYS " | grep -q " $SIGNING_FPR "; then
  echo "::error::Tag $TAG signed by unknown key: $SIGNING_FPR"
  exit 1
fi
echo "Tag $TAG verified: signed by $SIGNING_FPR"
```

### Job: `resolve`
Runner: `warp-ubuntu-latest-x64-2x`
- Checkout with `fetch-depth: 0` + `fetch-tags: true` (need all tags)
- Extract version from tag ref, `inputs.version`, or latest `images/v*` tag (for cron)
- Validate SemVer format
- **Verify GPG signature** on the resolved tag (all triggers — tag push, cron, dispatch)
- Resolve flavors list (from input or default: all 4)
- Outputs: `version`, `tag` (e.g., `images/v1.0.0`), `flavors_json`
- Downstream `build` jobs checkout the verified tag ref (not `main`)

### Job: `build-amd64` (single job, layered chain)
Runner: `warp-ubuntu-latest-x64-4x`
Environment: `build` — Timeout: 240 min
- Checkout at tag ref `${{ needs.resolve.outputs.tag }}` with submodules (uses `SUBMODULE_DEPLOY_KEY` from `build` environment)
- Verify submodule initialized, verify `/dev/kvm` available
- `make build-docker-builder` + `make build-docker-publisher` (both upfront, so stamps exist for uploads)
- **Pipelined build+upload**: overlap each flavor's upload with the next flavor's build. Uploads are network-bound, builds are CPU-bound — they don't contend. Saves ~15-30 min (3 upload times hidden behind builds).

When only specific flavors are requested, the loop skips non-requested flavors (but Make auto-builds chain deps via stamp rules). Safe because: publisher Docker image is pre-built, each `docker run --rm` is isolated, uploads target different B2 paths.

### Job: `build-arm64` (matrix by flavor, parallel from-scratch)
Runner: `warp-ubuntu-latest-arm64-8x` — one job per flavor
Environment: `build` — Timeout: 300 min — `fail-fast: false`
Strategy: `matrix.flavor: ${{ fromJson(needs.resolve.outputs.flavors_json) }}`

**Why parallel from-scratch instead of layered chain:**
ARM64 CI runners (GitHub/WarpBuild) lack KVM/nested virtualization, forcing TCG emulation. Benchmarks on a 16-vCPU arm64 runner show ~1h per from-scratch build (4T→1:24h, 8T→1:04h, 12T→1h, 16T→1:10h), making the serial 4-flavor layered chain take 5+ hours. Fanning out to 4 parallel jobs — each building one flavor from scratch — runs all flavors in ~1h wall time.

- Each matrix job: `make image-<flavor>-arm64` (from-scratch via Makefile CUMULATIVE_LAYERS) + `upload_with_retry`
- Same checkout, submodule, secrets validation, KVM check steps as amd64
- Simpler upload — only one flavor per job, no pipelining needed

### Job: `publish` (needs: resolve, build-amd64, build-arm64)
Runner: `warp-ubuntu-latest-x64-2x`
Environment: `publish` — Condition: `always() && needs.resolve.result == 'success' && !(both builds cancelled)`
- `make build-docker-publisher`
- `make update-manifest VERSION=...` (downloads `.meta.json` sidecars from B2, skips missing archs gracefully; calls `generate-index.sh` automatically)
- Cloudflare cache purge (same step, runs only if manifest update succeeded):
  - Build URL list: `manifest.json`, root `index.html`, per-flavor indexes, per-version indexes, `.sha256` + `.meta.json` sidecars (26 URLs at 4 flavors × 2 arches). Batched in chunks of 30 (CF API limit) for future-proofing.
  - `POST /zones/{zone_id}/purge_cache` with `files` array
  - Uses `CF_ZONE_ID` + `CF_API_TOKEN` secrets
  - Non-fatal on failure (cache expires naturally at 1d edge TTL)

**Per-upload CF purge**: Build jobs also purge `.sha256` and `.meta.json` sidecar URLs immediately after upload via `_cf_purge_urls()` in `publish.sh --upload-only`. This ensures clients fetching `.meta.json` for SHA256 verification get the latest data without waiting for the fan-in manifest update. Requires `CF_ZONE_ID` + `CF_API_TOKEN` in the `build` environment.

### Slack Failure Notifications (per-job, not a separate job)
Each job in `images.yml` has a final `if: always() && !success()` step that posts to Slack via `SLACK_WEBHOOK_URL` (repo-level secret). This catches both failures and cancellations. Fires as soon as a job fails and includes the specific job name in the notification. No separate `notify` job needed.

## Workflow 3: `release.yml` — Tool Release

**Trigger**: `mps/v*` tag push
**Runner**: `warp-ubuntu-latest-x64-4x`
**Permissions**: `contents: write`

### Job: `release`
Runner: `warp-ubuntu-latest-x64-4x`
Environment: `publish`

Steps:
1. Checkout with full history and tags (`fetch-depth: 0`, `fetch-tags: true`)
2. **Verify GPG-signed tag** (same logic as images.yml — uses `MAINTAINER_KEYS` variable, keyserver fallback chain)
3. Snap confinement preflight
4. Validate tag version matches `VERSION` file
5. Validate required secrets (B2 + CF via `_validate_required_vars`)
6. **Detect image drift** — runs `.github/scripts/e2e-image-drift.sh` to check if image-affecting files changed since the latest `images/v*` tag
7. **Conditional local image build** — if drift detected: configure SSH deploy key, init submodules, check KVM, `make image-base-amd64`. Requires `SUBMODULE_DEPLOY_KEY` in the `publish` environment.
8. `make lint` + `make test`
9. E2E test — uses `MPS_E2E_IMAGE` (local artifact) when image was built, otherwise pulls from CDN
10. Coverage aggregation + upload
11. Create GitHub Release via `softprops/action-gh-release@v2` with `install.sh`, `install.ps1`, `VERSION`
12. `make publish-release-meta VERSION=<version>` — resolves `git rev-parse mps/v<version>^0` on host, runs `images/publish-release-meta.sh` inside publisher container (generates `mps-release.json`, uploads to B2, cleans old versions, purges CF cache)

**`mps-release.json` format:**
```json
{
  "version": "0.3.0",
  "tag": "mps/v0.3.0",
  "commit_sha": "9220b15a..."
}
```

Clients fetch this file (at most once per 24h) to compare against the local `VERSION` file. If the remote version is newer, or the `commit_sha` doesn't match (force-pushed tag), a one-line warning is printed to stderr with update instructions.

## Workflow 4: `update-submodule.yml` — Automated Submodule Updates

**Trigger**: `workflow_dispatch` (manual) or scheduled
**Runner**: `warp-ubuntu-latest-x64-2x`

### Job: `update-submodule`
Runner: `warp-ubuntu-latest-x64-2x`
Environment: `submodule`

Checks the `vendor/hl-claude-marketplace` submodule for upstream updates. If the remote HEAD has advanced, creates a PR via the GitHub API using the `mpsandbox[bot]` GitHub App. Uses `SUBMODULE_DEPLOY_KEY` for submodule checkout and `MPS_BOT_APP_ID` + `MPS_BOT_PRIVATE_KEY` for PR creation with signed commits via the Git Data API.

## Pipeline Architecture

```
                    ┌─────────────────────┐
                    │      resolve        │  x64-2x
                    │  version + GPG      │  no env
                    └──────────┬──────────┘
                               │
    ┌──────────────┬───────────┼───────────┬──────────────┐
    │              │           │           │              │
┌───▼───┐   ┌─────▼────┐ ┌───▼────┐ ┌────▼───┐ ┌───────▼──────┐
│build  │   │build-arm │ │  arm   │ │  arm   │ │    arm       │
│amd64  │   │  base    │ │ p-dev  │ │  scd   │ │    sca       │
│x64-4x │   │arm64-8x │ │arm64-8x│ │arm64-8x│ │  arm64-8x   │
│layered│   │scratch   │ │scratch │ │scratch │ │  scratch     │
└───┬───┘   └─────┬────┘ └───┬────┘ └────┬───┘ └───────┬──────┘
    │              │          │           │              │
    └──────────────┴──────────┼───────────┴──────────────┘
                              │
                   ┌──────────▼──────────┐
                   │      publish        │  x64-2x
                   │  manifest + CF purge│  env: publish
                   └─────────────────────┘
```

## Required GitHub Configuration

### Repository Variable (Settings > Variables > Actions)

| Variable | Purpose |
|---|---|
| `MAINTAINER_KEYS` | Space-separated GPG fingerprints of authorized tag signers |

### Repository-Level Secret (available to all jobs)

| Secret | Purpose |
|---|---|
| `SLACK_WEBHOOK_URL` | Slack incoming webhook for failure notifications |

### Environment: `build` (used by `build` jobs in images.yml)

| Secret | Purpose |
|---|---|
| `SUBMODULE_DEPLOY_KEY` | SSH private key for `HorizenLabs/hl-claude-marketplace` |
| `B2_APPLICATION_KEY_ID` | Backblaze B2 key ID (for uploading images) |
| `B2_APPLICATION_KEY` | Backblaze B2 key secret |
| `CF_ZONE_ID` | Cloudflare zone ID (for per-upload sidecar cache purge) |
| `CF_API_TOKEN` | Cloudflare API token with Zone Cache Purge permission |

### Environment: `publish` (used by `publish` in images.yml + `release` in release.yml)

| Secret | Purpose |
|---|---|
| `B2_APPLICATION_KEY_ID` | Backblaze B2 key ID (manifest update, mps-release.json upload) |
| `B2_APPLICATION_KEY` | Backblaze B2 key secret |
| `CF_ZONE_ID` | Cloudflare zone ID for `horizenlabs.io` |
| `CF_API_TOKEN` | Cloudflare API token with Zone Cache Purge permission |
| `SUBMODULE_DEPLOY_KEY` | SSH private key for `HorizenLabs/hl-claude-marketplace` (conditional image build in release.yml) |

### Environment: `submodule` (used by `update-submodule` job in update-submodule.yml)

| Secret | Purpose |
|---|---|
| `SUBMODULE_DEPLOY_KEY` | SSH private key for `HorizenLabs/hl-claude-marketplace` |
| `MPS_BOT_APP_ID` | GitHub App ID for `mpsandbox[bot]` (PR creation) |
| `MPS_BOT_PRIVATE_KEY` | GitHub App private key for `mpsandbox[bot]` (PR creation) |

### Job → Environment Mapping

| Workflow | Job | Environment | Secrets Accessible |
|---|---|---|---|
| `ci.yml` | `lint-and-test` | *(none)* | SLACK_WEBHOOK_URL, GITHUB_TOKEN (auto, PR comments) |
| `ci.yml` | `changes` | *(none)* | GITHUB_TOKEN (auto, PR file list + git diff) |
| `ci.yml` | `build-and-e2e` | `build` | SUBMODULE_DEPLOY_KEY, GITHUB_TOKEN |
| `ci.yml` | `e2e` | *(none)* | GITHUB_TOKEN (auto) |
| `images.yml` | `resolve` | *(none)* | SLACK_WEBHOOK_URL + MAINTAINER_KEYS var |
| `images.yml` | `build-amd64` | `build` | B2, CF, deploy key, SLACK_WEBHOOK_URL |
| `images.yml` | `build-arm64` | `build` | B2, CF, deploy key, SLACK_WEBHOOK_URL |
| `images.yml` | `publish` | `publish` | B2, CF, SLACK_WEBHOOK_URL |
| `release.yml` | `release` | `publish` | B2, CF, SLACK_WEBHOOK_URL + MAINTAINER_KEYS var |
| `update-submodule.yml` | `update-submodule` | `submodule` | deploy key, MPS_BOT app token, SLACK_WEBHOOK_URL |

## Deploy Key Setup

```bash
# 1. Generate key pair
ssh-keygen -t ed25519 -C "multipass-sandbox-ci-submodule" -f mps-submodule-deploy-key -N ""

# 2. Add public key to submodule repo as read-only deploy key
#    https://github.com/HorizenLabs/hl-claude-marketplace/settings/keys
#    Title: "multipass-sandbox CI (read-only)", paste .pub, uncheck write access

# 3. Add private key as repo secret on main repo (in both "build" and "submodule" environments)
#    https://github.com/HorizenLabs/multipass-sandbox/settings/environments
#    Environment: build     → Add secret → Name: SUBMODULE_DEPLOY_KEY, paste entire private key
#    Environment: submodule → Add secret → Name: SUBMODULE_DEPLOY_KEY, paste entire private key

# 4. Delete local key files
rm mps-submodule-deploy-key mps-submodule-deploy-key.pub
```

## E2E Test Integration

### Image Drift Detection (`.github/scripts/e2e-image-drift.sh`)

Compares HEAD against the latest `images/v*` tag. If any image-affecting paths changed, outputs `true` — the e2e must build a local image rather than pulling from CDN. Image-affecting paths: `images/layers/`, `images/scripts/`, `images/build.sh`, `images/packer.pkr.hcl`, `images/packer-user-data.pkrtpl.hcl`, `images/arch-config.sh`, `vendor/`.

`templates/cloud-init/` is NOT considered image drift — these are VM launch templates, not baked image content. Cloud-init changes trigger the CDN-image e2e job.

Called by `.github/scripts/ci-detect-e2e.sh` (ci.yml `changes` job wrapper) and directly by release.yml.

### CI Change Detection (`.github/scripts/ci-detect-e2e.sh`)

Wrapper for the ci.yml `changes` job. Handles both push and PR event types:
1. Runs `e2e-image-drift.sh` for image drift → sets `needs_image_build`
2. For PRs: checks PR files via `gh api` for `templates/cloud-init/` changes
3. For pushes: checks `git diff $BEFORE_SHA..HEAD` for `templates/cloud-init/` changes
4. `needs_e2e = cloud_init_changed OR needs_image_build`

Security: fork PRs with image drift get `needs_image_build=true` but the `build-and-e2e` job won't run (gates on same-repo origin). Same-repo PRs (e.g., submodule bot) get the full local-build e2e via the `build` environment.

### Snap Confinement Preflight (`.github/scripts/ci-preflight.sh`)

Fail-fast script that runs early in both `release.yml` and `images.yml` (amd64 job), before any substantive work. Checks:
1. **AppArmor kernel module** — `/sys/module/apparmor/parameters/enabled == Y`
2. **Snap strict confinement** — `snap debug confinement == strict`
3. **Snap seed loaded** — `sudo snap wait system seed.loaded` (prevents snap install hangs on GH runners)

Shellchecked via `BASH_SCRIPTS` in the Makefile. Not subject to Bash 3.2 compat (runs only on Ubuntu CI runners with Bash 5+).

### `release.yml` — E2E Gate

After validation and before "Create GitHub Release":
1. **Detect image drift** — `.github/scripts/e2e-image-drift.sh` checks if image-affecting files changed since latest `images/v*` tag
2. **Conditional local build** — if drift detected: SSH deploy key setup, submodule init, KVM check, `make image-base-amd64`
3. `MPS_E2E_INSTALL=true make test-e2e` — uses local artifact (`MPS_E2E_IMAGE`) when available, otherwise pulls from CDN
4. `make test-e2e-report` — merges coverage from all three tiers (unit/integration/e2e) into `coverage/lcov.info` + `coverage/summary.md`, enforcing 90% aggregate threshold.
5. Coverage summary appended to `$GITHUB_STEP_SUMMARY`; artifacts uploaded (30-day retention).

No PR comment step — releases are tag-triggered, not PRs.

### `images.yml` — Build→E2E→Upload Pipeline (amd64)

The amd64 build loop is restructured from build→upload to build→e2e→upload:

```
for flavor in CHAIN:
    make image-<flavor>-amd64        # foreground (Docker/Packer, CPU-bound)
    wait_prev                        # wait for previous background e2e+upload
    e2e_and_upload <flavor> &        # background (e2e THEN upload, sequential)
```

The `e2e_and_upload()` function:
1. Runs `MPS_E2E_IMAGE=images/artifacts/mps-<flavor>-amd64.qcow2.img MPS_E2E_INSTALL=true make test-e2e`
2. If E2E passes → runs `upload_with_retry` (existing retry logic with 3 attempts + exponential backoff)
3. If E2E fails → returns 1 (blocks upload, propagates failure via `wait_prev`)

**Concurrency guarantees:**
- `wait_prev` before starting next background task ensures only one E2E at a time
- E2E for flavor N overlaps with BUILD for flavor N+1 (not another E2E)
- Multipass VM (micro profile: 1 CPU, ~256M) and Docker/Packer build coexist on 4x runner

**Timing:** 4 flavors × (15min build + 10min e2e + 3min upload) with overlap ≈ 73min. ARM64 matrix takes ~80min → x86 still fits within the critical path.

**ARM64:** No E2E on arm64 (no KVM on arm64 CI runners — Multipass requires KVM for VM creation).

### `MPS_E2E_INSTALL=true` Environment Variable

When set, `tests/e2e.sh` runs `install.sh`/`uninstall.sh` as Phase 0/15 bookends. In CI, this serves dual purpose:
- Installs `multipass` + `jq` dependencies on the runner (exercising the installer E2E)
- Validates the installer itself works on a fresh system

## Verification

1. Push a commit to `main` → CI workflow runs lint successfully
2. Push signed tag `images/v1.0.0` → full image pipeline (GPG verify, preflight, build both archs, E2E validate amd64, upload, manifest, CF purge)
3. Push signed tag `mps/v0.1.0` → release workflow (GPG verify, preflight, lint, test, E2E, create GH release)
4. Push unsigned tag → workflow fails at GPG verification step
5. Wait for Sunday cron → weekly rebuild picks up latest tag, verifies its signature
6. Manual dispatch with `version: 1.0.0`, `flavors: base` → single-flavor rebuild
