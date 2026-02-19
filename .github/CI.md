# GitHub Actions CI/CD Pipeline (Phase 7)

## Context

The mpsandbox project has a mature, fully containerized build system (Makefile + Docker) but no CI/CD. Phase 7 adds GitHub Actions workflows for lint/test on push/PR, image build/publish on tag push + weekly cron, and tool releases. WarpBuild runners provide native KVM for fast QEMU builds on amd64; arm64 runners lack KVM, so arm64 builds use TCG emulation with a parallel from-scratch strategy.

## Files to Create

1. `.github/workflows/ci.yml` — lint + test
2. `.github/workflows/images.yml` — image build + publish + CF cache purge
3. `.github/workflows/release.yml` — tool release

## Workflow 1: `ci.yml` — Lint + Test

**Triggers**: Push to `main`, PRs to `main` (excludes tags)
**Runner**: `warp-ubuntu-latest-x64-2x`
**Concurrency**: Cancel in-progress runs per-ref

Steps:
1. `actions/checkout@v4` (no submodules — lint/test don't need them)
2. `make lint` (builds linter Docker image automatically via stamp dep)
3. `make test` (skip gracefully if `tests/` doesn't exist yet)

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
**Runner**: `warp-ubuntu-latest-x64-2x`
**Permissions**: `contents: write`

Steps:
1. Checkout (no submodules)
2. **Verify GPG-signed tag** (same logic as images.yml — uses `MAINTAINER_KEYS` variable, keyserver fallback chain)
3. Validate tag version matches `VERSION` file
4. `make lint` + `make test` (skip if no tests)
5. Create GitHub Release via `softprops/action-gh-release@v2` with `install.sh`, `install.ps1`, `VERSION`

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

### Environment: `publish` (used by `publish` job in images.yml)

| Secret | Purpose |
|---|---|
| `B2_APPLICATION_KEY_ID` | Backblaze B2 key ID (for manifest update) |
| `B2_APPLICATION_KEY` | Backblaze B2 key secret |
| `CF_ZONE_ID` | Cloudflare zone ID for `horizenlabs.io` |
| `CF_API_TOKEN` | Cloudflare API token with Zone Cache Purge permission |

### Environment: `submodule` (used by `update-submodule` job in update-submodule.yml)

| Secret | Purpose |
|---|---|
| `SUBMODULE_DEPLOY_KEY` | SSH private key for `HorizenLabs/hl-claude-marketplace` |

### Job → Environment Mapping

| Workflow | Job | Environment | Secrets Accessible |
|---|---|---|---|
| `ci.yml` | `lint-and-test` | *(none)* | SLACK_WEBHOOK_URL |
| `images.yml` | `resolve` | *(none)* | SLACK_WEBHOOK_URL + MAINTAINER_KEYS var |
| `images.yml` | `build-amd64` | `build` | B2, CF, deploy key, SLACK_WEBHOOK_URL |
| `images.yml` | `build-arm64` | `build` | B2, CF, deploy key, SLACK_WEBHOOK_URL |
| `images.yml` | `publish` | `publish` | B2, CF, SLACK_WEBHOOK_URL |
| `release.yml` | `release` | *(none)* | SLACK_WEBHOOK_URL + MAINTAINER_KEYS var |
| `update-submodule.yml` | `update-submodule` | `submodule` | deploy key, SLACK_WEBHOOK_URL |

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

## Verification

1. Push a commit to `main` → CI workflow runs lint successfully
2. Push signed tag `images/v1.0.0` → full image pipeline (GPG verify, build both archs, upload, manifest, CF purge)
3. Push signed tag `mps/v0.1.0` → release workflow (GPG verify, lint, create GH release)
4. Push unsigned tag → workflow fails at GPG verification step
5. Wait for Sunday cron → weekly rebuild picks up latest tag, verifies its signature
6. Manual dispatch with `version: 1.0.0`, `flavors: base` → single-flavor rebuild
