#!/usr/bin/env bats
# Tests for CLI update check and instance staleness warning functions:
#   _mps_check_cli_update, _mps_cli_update_warn, _mps_warn_instance_staleness

load ../test_helper

setup()    { setup_home_override; }
teardown() { teardown_home_override; }

# Create instance metadata for staleness checks
# Usage: _create_staleness_meta <short_name> [sha256] [img_name] [version]
_create_staleness_meta() {
    local short_name="$1"
    local sha="${2:-sha1}"
    local img_name="${3-base}"
    local ver="${4-1.0.0}"
    mkdir -p "${HOME}/mps/instances"
    cat > "${HOME}/mps/instances/${short_name}.json" <<EOF
{
    "name": "${short_name}",
    "full_name": "mps-${short_name}",
    "image": {"name": "${img_name}", "version": "${ver}", "arch": "amd64", "sha256": "${sha}", "source": "pulled"}
}
EOF
}

# ================================================================
# _mps_cli_update_warn
# ================================================================

@test "_mps_cli_update_warn: emits update warning when remote version is newer" {
    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    printf '{"version":"2.0.0","tag":"v2.0.0","commit_sha":"abc1234"}\n' > "$cache_file"

    export MPS_VERSION="1.0.0"
    run _mps_cli_update_warn "$cache_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"update available"* ]]
    [[ "$output" == *"1.0.0"* ]]
    [[ "$output" == *"2.0.0"* ]]
}

@test "_mps_cli_update_warn: no warning when versions are equal and sha is ancestor" {
    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    # Use HEAD's own sha so merge-base --is-ancestor succeeds
    local head_sha
    head_sha="$(git -C "$MPS_ROOT" rev-parse HEAD 2>/dev/null)" || head_sha="0000000"
    printf '{"version":"0.0.0","tag":"v0.0.0-test","commit_sha":"%s"}\n' "$head_sha" > "$cache_file"

    export MPS_VERSION="0.0.0"
    run _mps_cli_update_warn "$cache_file"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_cli_update_warn: no warning for missing cache file" {
    run _mps_cli_update_warn "${HOME}/mps/cache/nonexistent.json"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_cli_update_warn: no warning when remote version is older" {
    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    printf '{"version":"0.1.0","tag":"v0.1.0","commit_sha":"abc1234"}\n' > "$cache_file"

    export MPS_VERSION="1.0.0"
    run _mps_cli_update_warn "$cache_file"
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"update available"* ]]
}

# ================================================================
# _mps_check_cli_update
# ================================================================

@test "_mps_check_cli_update: warns when cached release is newer" {
    export MPS_CHECK_UPDATES=true
    export MPS_VERSION="1.0.0"
    export MPS_IMAGE_BASE_URL="http://example.com"

    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    printf '{"version":"2.0.0","tag":"v2.0.0","commit_sha":"abc1234"}\n' > "$cache_file"

    # Stub _mps_remote_fetch to no-op (cache already exists and is fresh)
    _mps_remote_fetch() { return 0; }
    export -f _mps_remote_fetch

    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"update available"* ]]
    [[ "$output" == *"2.0.0"* ]]
}

@test "_mps_check_cli_update: silent when MPS_CHECK_UPDATES=false" {
    export MPS_CHECK_UPDATES=false
    export MPS_VERSION="1.0.0"
    export MPS_IMAGE_BASE_URL="http://example.com"

    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    printf '{"version":"2.0.0","tag":"v2.0.0","commit_sha":"abc1234"}\n' > "$cache_file"

    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_check_cli_update: silent when MPS_VERSION is not SemVer" {
    export MPS_CHECK_UPDATES=true
    export MPS_VERSION="unknown"
    export MPS_IMAGE_BASE_URL="http://example.com"

    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_check_cli_update: silent when MPS_IMAGE_BASE_URL is empty" {
    export MPS_CHECK_UPDATES=true
    export MPS_VERSION="1.0.0"
    export MPS_IMAGE_BASE_URL=""

    run _mps_check_cli_update
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ================================================================
# _mps_warn_instance_staleness
# ================================================================

@test "_mps_warn_instance_staleness: emits warning for stale instance" {
    export MPS_IMAGE_CHECK_UPDATES=true

    # Create metadata
    _create_staleness_meta "test-stale" "old-sha"

    # Mock _mps_check_instance_staleness to return "stale"
    _mps_check_instance_staleness() { echo "stale"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-stale"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"older build"* ]]
    [[ "$output" == *"test-stale"* ]]
}

@test "_mps_warn_instance_staleness: emits update warning with new version" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-update"

    _mps_check_instance_staleness() { echo "update:2.0.0"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-update"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2.0.0"* ]]
    [[ "$output" == *"available locally"* ]]
}

@test "_mps_warn_instance_staleness: silent when up-to-date" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-ok"

    _mps_check_instance_staleness() { echo "up-to-date"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-ok"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_warn_instance_staleness: silent when MPS_IMAGE_CHECK_UPDATES=false" {
    export MPS_IMAGE_CHECK_UPDATES=false

    _create_staleness_meta "test-opt"

    _mps_check_instance_staleness() { echo "stale"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-opt"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_warn_instance_staleness: --skip-manifest suppresses manifest staleness" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-skip"

    _mps_check_instance_staleness() { echo "stale:manifest"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-skip" "--skip-manifest"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_warn_instance_staleness: manifest update suppressed by --skip-manifest" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-skip2"

    _mps_check_instance_staleness() { echo "update:manifest:2.0.0"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-skip2" "--skip-manifest"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "_mps_warn_instance_staleness: manifest staleness shown without --skip-manifest" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-noskip"

    _mps_check_instance_staleness() { echo "stale:manifest"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-noskip"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"older build"* ]]
}

@test "_mps_warn_instance_staleness: update:manifest shows update available with pull command" {
    export MPS_IMAGE_CHECK_UPDATES=true

    _create_staleness_meta "test-mup"

    _mps_check_instance_staleness() { echo "update:manifest:2.0.0"; }
    export -f _mps_check_instance_staleness

    run _mps_warn_instance_staleness "test-mup"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"2.0.0"* ]]
    [[ "$output" == *"mps image pull"* ]]
}

# ================================================================
# _mps_check_instance_staleness: missing fields
# ================================================================

@test "_mps_check_instance_staleness: unknown when img_name is empty" {
    _create_staleness_meta "test-noname" "abc123" ""
    run _mps_check_instance_staleness "test-noname"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

@test "_mps_check_instance_staleness: unknown when cache meta missing" {
    _create_staleness_meta "test-nocache" "abc123" "base" "9.9.9"
    # No cache meta for base:9.9.9
    run _mps_check_instance_staleness "test-nocache"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "unknown" ]]
}

# ================================================================
# _mps_cli_update_warn: short/missing commit_sha
# ================================================================

@test "_mps_cli_update_warn: silent when commit_sha is too short" {
    local cache_file="${HOME}/mps/cache/mps-release.json"
    mkdir -p "$(dirname "$cache_file")"
    printf '{"version":"0.0.0","tag":"v0.0.0-test","commit_sha":"abc"}\n' > "$cache_file"

    export MPS_VERSION="0.0.0"
    run _mps_cli_update_warn "$cache_file"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}
