#!/usr/bin/env bats
# Tests for metadata/JSON helper functions in lib/common.sh:
#   _mps_read_meta_json, _mps_write_json, mps_instance_meta, mps_image_meta,
#   mps_state_dir, mps_cache_dir, mps_resolve_cloud_init,
#   mps_check_image_requirements, _mps_resolve_latest_version,
#   mps_save_instance_meta, mps_resolve_workdir, _mps_read_cached_manifest

load test_helper

setup() {
    setup_temp_dir
    # Override HOME so state/cache dirs use temp
    export REAL_HOME="$HOME"
    export HOME="${TEST_TEMP_DIR}/fakehome"
    mkdir -p "$HOME"
}

teardown() {
    export HOME="$REAL_HOME"
    teardown_temp_dir
}

# ================================================================
# _mps_read_meta_json
# ================================================================

@test "_mps_read_meta_json: reads key from JSON file" {
    echo '{"name":"test","version":"1.0.0"}' > "${TEST_TEMP_DIR}/meta.json"
    result="$(_mps_read_meta_json "${TEST_TEMP_DIR}/meta.json" '.name')"
    [[ "$result" == "test" ]]
}

@test "_mps_read_meta_json: returns empty for missing key" {
    echo '{"name":"test"}' > "${TEST_TEMP_DIR}/meta.json"
    result="$(_mps_read_meta_json "${TEST_TEMP_DIR}/meta.json" '.nonexistent')"
    [[ -z "$result" ]]
}

@test "_mps_read_meta_json: returns empty for missing file" {
    result="$(_mps_read_meta_json "${TEST_TEMP_DIR}/nonexistent.json" '.name')"
    [[ -z "$result" ]]
}

@test "_mps_read_meta_json: handles nested keys" {
    echo '{"image":{"name":"base","version":"1.0.0"}}' > "${TEST_TEMP_DIR}/meta.json"
    result="$(_mps_read_meta_json "${TEST_TEMP_DIR}/meta.json" '.image.name')"
    [[ "$result" == "base" ]]
}

# ================================================================
# _mps_write_json
# ================================================================

@test "_mps_write_json: writes JSON to file" {
    _mps_write_json "${TEST_TEMP_DIR}/out.json" '{"key":"value"}'
    [[ -f "${TEST_TEMP_DIR}/out.json" ]]
    result="$(jq -r '.key' "${TEST_TEMP_DIR}/out.json")"
    [[ "$result" == "value" ]]
}

@test "_mps_write_json: sets restrictive permissions" {
    _mps_write_json "${TEST_TEMP_DIR}/out.json" '{"secret":"data"}'
    local perms
    perms="$(stat -c '%a' "${TEST_TEMP_DIR}/out.json" 2>/dev/null || stat -f '%Lp' "${TEST_TEMP_DIR}/out.json")"
    [[ "$perms" == "600" ]]
}

@test "_mps_write_json: overwrites existing file atomically" {
    echo '{"old":"data"}' > "${TEST_TEMP_DIR}/out.json"
    _mps_write_json "${TEST_TEMP_DIR}/out.json" '{"new":"data"}'
    result="$(jq -r '.new' "${TEST_TEMP_DIR}/out.json")"
    [[ "$result" == "data" ]]
}

# ================================================================
# mps_state_dir / mps_cache_dir
# ================================================================

@test "mps_state_dir: creates directory under HOME" {
    result="$(mps_state_dir)"
    [[ -d "$result" ]]
    [[ "$result" == "${HOME}/.mps/instances" ]]
}

@test "mps_cache_dir: creates directory under HOME" {
    result="$(mps_cache_dir)"
    [[ -d "$result" ]]
    [[ "$result" == "${HOME}/.mps/cache" ]]
}

# ================================================================
# mps_instance_meta
# ================================================================

@test "mps_instance_meta: returns correct path" {
    result="$(mps_instance_meta "mydev")"
    [[ "$result" == *"/.mps/instances/mydev.json" ]]
}

# ================================================================
# mps_resolve_cloud_init
# ================================================================

@test "mps_resolve_cloud_init: resolves 'default' template" {
    result="$(mps_resolve_cloud_init "default")"
    [[ "$result" == "${MPS_ROOT}/templates/cloud-init/default.yaml" ]]
}

@test "mps_resolve_cloud_init: resolves absolute path" {
    touch "${TEST_TEMP_DIR}/custom.yaml"
    result="$(mps_resolve_cloud_init "${TEST_TEMP_DIR}/custom.yaml")"
    [[ "$result" == "${TEST_TEMP_DIR}/custom.yaml" ]]
}

@test "mps_resolve_cloud_init: resolves personal template" {
    mkdir -p "${HOME}/.mps/cloud-init"
    touch "${HOME}/.mps/cloud-init/personal.yaml"
    result="$(mps_resolve_cloud_init "personal")"
    [[ "$result" == "${HOME}/.mps/cloud-init/personal.yaml" ]]
}

@test "mps_resolve_cloud_init: dies for non-existent template" {
    run mps_resolve_cloud_init "nonexistent-template-xyz"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"not found"* ]]
}

@test "mps_resolve_cloud_init: uses MPS_CLOUD_INIT default" {
    MPS_CLOUD_INIT="" MPS_DEFAULT_CLOUD_INIT="default"
    result="$(mps_resolve_cloud_init)"
    [[ "$result" == "${MPS_ROOT}/templates/cloud-init/default.yaml" ]]
}

# ================================================================
# _mps_resolve_latest_version
# ================================================================

@test "_mps_resolve_latest_version: finds highest semver" {
    local arch
    arch="$(mps_detect_arch)"
    mkdir -p "${TEST_TEMP_DIR}/images/1.0.0" "${TEST_TEMP_DIR}/images/1.1.0" "${TEST_TEMP_DIR}/images/2.0.0"
    touch "${TEST_TEMP_DIR}/images/1.0.0/${arch}.img"
    touch "${TEST_TEMP_DIR}/images/1.1.0/${arch}.img"
    touch "${TEST_TEMP_DIR}/images/2.0.0/${arch}.img"
    result="$(_mps_resolve_latest_version "${TEST_TEMP_DIR}/images" "$arch")"
    [[ "$result" == "2.0.0" ]]
}

@test "_mps_resolve_latest_version: skips versions without matching arch" {
    mkdir -p "${TEST_TEMP_DIR}/images/1.0.0" "${TEST_TEMP_DIR}/images/2.0.0"
    touch "${TEST_TEMP_DIR}/images/1.0.0/amd64.img"
    touch "${TEST_TEMP_DIR}/images/2.0.0/arm64.img"
    result="$(_mps_resolve_latest_version "${TEST_TEMP_DIR}/images" "amd64")"
    [[ "$result" == "1.0.0" ]]
}

@test "_mps_resolve_latest_version: falls back to 'local' tag" {
    mkdir -p "${TEST_TEMP_DIR}/images/local"
    touch "${TEST_TEMP_DIR}/images/local/amd64.img"
    result="$(_mps_resolve_latest_version "${TEST_TEMP_DIR}/images" "amd64")"
    [[ "$result" == "local" ]]
}

@test "_mps_resolve_latest_version: returns empty when nothing matches" {
    mkdir -p "${TEST_TEMP_DIR}/images/1.0.0"
    touch "${TEST_TEMP_DIR}/images/1.0.0/arm64.img"
    result="$(_mps_resolve_latest_version "${TEST_TEMP_DIR}/images" "amd64")"
    [[ -z "$result" ]]
}

@test "_mps_resolve_latest_version: prefers semver over local" {
    local arch
    arch="$(mps_detect_arch)"
    mkdir -p "${TEST_TEMP_DIR}/images/1.0.0" "${TEST_TEMP_DIR}/images/local"
    touch "${TEST_TEMP_DIR}/images/1.0.0/${arch}.img"
    touch "${TEST_TEMP_DIR}/images/local/${arch}.img"
    result="$(_mps_resolve_latest_version "${TEST_TEMP_DIR}/images" "$arch")"
    [[ "$result" == "1.0.0" ]]
}

# ================================================================
# mps_check_image_requirements
# ================================================================

@test "mps_check_image_requirements: no-op for non-file URLs" {
    # Should return 0 and produce no output for stock Ubuntu images
    run mps_check_image_requirements "24.04" "2" "2G" "20G"
    [[ "$status" -eq 0 ]]
}

@test "mps_check_image_requirements: no-op when no meta file" {
    run mps_check_image_requirements "file:///nonexistent/path/img.img" "2" "2G" "20G"
    [[ "$status" -eq 0 ]]
}

@test "mps_check_image_requirements: warns when cpus below minimum" {
    mkdir -p "${TEST_TEMP_DIR}/img"
    echo '{"min_cpus": 4, "min_profile": "standard"}' > "${TEST_TEMP_DIR}/img/test.meta.json"
    run mps_check_image_requirements "file://${TEST_TEMP_DIR}/img/test.img" "2" "8G" "50G"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"vCPUs (2) below image minimum (4)"* ]]
}

@test "mps_check_image_requirements: warns when memory below minimum" {
    mkdir -p "${TEST_TEMP_DIR}/img"
    echo '{"min_memory": "8G"}' > "${TEST_TEMP_DIR}/img/test.meta.json"
    run mps_check_image_requirements "file://${TEST_TEMP_DIR}/img/test.img" "4" "2G" "50G"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Memory (2G) below image minimum (8G)"* ]]
}

@test "mps_check_image_requirements: warns when disk below minimum" {
    mkdir -p "${TEST_TEMP_DIR}/img"
    echo '{"min_disk": "50G"}' > "${TEST_TEMP_DIR}/img/test.meta.json"
    run mps_check_image_requirements "file://${TEST_TEMP_DIR}/img/test.img" "4" "8G" "20G"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Disk (20G) below image minimum (50G)"* ]]
}

@test "mps_check_image_requirements: suggests min_profile when warning" {
    mkdir -p "${TEST_TEMP_DIR}/img"
    echo '{"min_cpus": 4, "min_profile": "heavy"}' > "${TEST_TEMP_DIR}/img/test.meta.json"
    run mps_check_image_requirements "file://${TEST_TEMP_DIR}/img/test.img" "1" "2G" "20G"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Recommended minimum profile: heavy"* ]]
}

@test "mps_check_image_requirements: no warning when resources sufficient" {
    mkdir -p "${TEST_TEMP_DIR}/img"
    echo '{"min_cpus": 2, "min_memory": "2G", "min_disk": "20G"}' > "${TEST_TEMP_DIR}/img/test.meta.json"
    run mps_check_image_requirements "file://${TEST_TEMP_DIR}/img/test.img" "4" "8G" "50G"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

# ================================================================
# mps_image_meta
# ================================================================

@test "mps_image_meta: reads key from meta file" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "${cache_dir}/images/base/1.0.0"
    echo '{"sha256":"abc123def","min_cpus":4,"build_date":"2026-01-01"}' \
        > "${cache_dir}/images/base/1.0.0/amd64.meta.json"
    result="$(mps_image_meta "base" "1.0.0" "amd64" "sha256")"
    [[ "$result" == "abc123def" ]]
}

@test "mps_image_meta: reads numeric key" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "${cache_dir}/images/base/1.0.0"
    echo '{"sha256":"abc","min_cpus":4}' > "${cache_dir}/images/base/1.0.0/amd64.meta.json"
    result="$(mps_image_meta "base" "1.0.0" "amd64" "min_cpus")"
    [[ "$result" == "4" ]]
}

@test "mps_image_meta: returns empty for missing key" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "${cache_dir}/images/base/1.0.0"
    echo '{"sha256":"abc123"}' > "${cache_dir}/images/base/1.0.0/amd64.meta.json"
    result="$(mps_image_meta "base" "1.0.0" "amd64" "nonexistent")"
    [[ -z "$result" ]]
}

@test "mps_image_meta: returns empty for missing file" {
    result="$(mps_image_meta "base" "9.9.9" "amd64" "sha256")"
    [[ -z "$result" ]]
}

@test "mps_image_meta: distinguishes architectures" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "${cache_dir}/images/base/1.0.0"
    echo '{"sha256":"amd64hash"}' > "${cache_dir}/images/base/1.0.0/amd64.meta.json"
    echo '{"sha256":"arm64hash"}' > "${cache_dir}/images/base/1.0.0/arm64.meta.json"
    result_amd="$(mps_image_meta "base" "1.0.0" "amd64" "sha256")"
    result_arm="$(mps_image_meta "base" "1.0.0" "arm64" "sha256")"
    [[ "$result_amd" == "amd64hash" ]]
    [[ "$result_arm" == "arm64hash" ]]
}

# ================================================================
# _mps_read_cached_manifest
# ================================================================

@test "_mps_read_cached_manifest: reads cached manifest" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "$cache_dir"
    echo '{"images":{"base":{"latest":"1.0.0"}}}' > "${cache_dir}/manifest.json"
    result="$(_mps_read_cached_manifest)"
    [[ "$result" == *'"latest":"1.0.0"'* ]]
}

@test "_mps_read_cached_manifest: returns 1 when no cached manifest" {
    run _mps_read_cached_manifest
    [[ "$status" -eq 1 ]]
}

@test "_mps_read_cached_manifest: returns full file content" {
    local cache_dir
    cache_dir="$(mps_cache_dir)"
    mkdir -p "$cache_dir"
    local expected='{"images":{"base":{"latest":"2.0.0","versions":{"2.0.0":{"amd64":{"sha256":"abc"}}}}}}'
    echo "$expected" > "${cache_dir}/manifest.json"
    result="$(_mps_read_cached_manifest)"
    # Verify it's valid JSON with the expected key
    echo "$result" | jq -e '.images.base.latest' >/dev/null
    [[ "$(echo "$result" | jq -r '.images.base.latest')" == "2.0.0" ]]
}

# ================================================================
# mps_save_instance_meta
# ================================================================

@test "mps_save_instance_meta: creates metadata file" {
    export MPS_CPUS=4 MPS_MEMORY=8G MPS_DISK=50G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ -f "$meta_file" ]]
}

@test "mps_save_instance_meta: writes valid JSON" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    jq -e '.' "$meta_file" >/dev/null
}

@test "mps_save_instance_meta: stores name and full_name" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.name' "$meta_file")" == "testinst" ]]
    [[ "$(jq -r '.full_name' "$meta_file")" == "mps-testinst" ]]
}

@test "mps_save_instance_meta: stores resource values from env" {
    export MPS_CPUS=8 MPS_MEMORY=16G MPS_DISK=100G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.cpus' "$meta_file")" == "8" ]]
    [[ "$(jq -r '.memory' "$meta_file")" == "16G" ]]
    [[ "$(jq -r '.disk' "$meta_file")" == "100G" ]]
}

@test "mps_save_instance_meta: stores cloud_init" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=protocol-dev
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.cloud_init' "$meta_file")" == "protocol-dev" ]]
}

@test "mps_save_instance_meta: converts empty workdir to null" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.workdir' "$meta_file")" == "null" ]]
}

@test "mps_save_instance_meta: saves workdir when provided" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "/home/user/project" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.workdir' "$meta_file")" == "/home/user/project" ]]
}

@test "mps_save_instance_meta: saves image metadata object" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    local img_json='{"name":"base","version":"1.0.0","arch":"amd64"}'
    mps_save_instance_meta "testinst" "$img_json" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.image.name' "$meta_file")" == "base" ]]
    [[ "$(jq -r '.image.version' "$meta_file")" == "1.0.0" ]]
    [[ "$(jq -r '.image.arch' "$meta_file")" == "amd64" ]]
}

@test "mps_save_instance_meta: saves null image when not provided" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.image' "$meta_file")" == "null" ]]
}

@test "mps_save_instance_meta: saves port forwards array" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" '["8080:80","9090:9090"]' "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.port_forwards[0]' "$meta_file")" == "8080:80" ]]
    [[ "$(jq -r '.port_forwards[1]' "$meta_file")" == "9090:9090" ]]
}

@test "mps_save_instance_meta: saves transfers array" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" '["file1.txt","file2.tar.gz"]'
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.transfers[0]' "$meta_file")" == "file1.txt" ]]
}

@test "mps_save_instance_meta: includes created timestamp" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    local created
    created="$(jq -r '.created' "$meta_file")"
    # ISO8601 format: YYYY-MM-DDTHH:MM:SSZ
    [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "mps_save_instance_meta: sets 600 permissions" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    local perms
    perms="$(stat -c '%a' "$meta_file" 2>/dev/null || stat -f '%Lp' "$meta_file")"
    [[ "$perms" == "600" ]]
}

@test "mps_save_instance_meta: includes ssh field as null" {
    export MPS_CPUS=2 MPS_MEMORY=2G MPS_DISK=20G MPS_CLOUD_INIT=default
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.ssh' "$meta_file")" == "null" ]]
}

@test "mps_save_instance_meta: falls back to MPS_DEFAULT vars" {
    unset MPS_CPUS MPS_MEMORY MPS_DISK MPS_CLOUD_INIT
    export MPS_DEFAULT_CPUS=1 MPS_DEFAULT_MEMORY=1G MPS_DEFAULT_DISK=10G MPS_DEFAULT_CLOUD_INIT=minimal
    mps_save_instance_meta "testinst" "null" "" "[]" "[]"
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    [[ "$(jq -r '.cpus' "$meta_file")" == "1" ]]
    [[ "$(jq -r '.memory' "$meta_file")" == "1G" ]]
    [[ "$(jq -r '.disk' "$meta_file")" == "10G" ]]
    [[ "$(jq -r '.cloud_init' "$meta_file")" == "minimal" ]]
    # Restore for other tests
    export MPS_CPUS=2 MPS_MEMORY=2G
}

# ================================================================
# mps_resolve_workdir
# ================================================================

@test "mps_resolve_workdir: returns explicit workdir immediately" {
    result="$(mps_resolve_workdir "mps-test" "/home/user/project")"
    [[ "$result" == "/home/user/project" ]]
}

@test "mps_resolve_workdir: reads workdir from metadata" {
    local meta_file
    meta_file="$(mps_instance_meta "test")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"workdir":"/home/user/myproject"}' > "$meta_file"
    result="$(mps_resolve_workdir "mps-test")"
    [[ "$result" == "/home/user/myproject" ]]
}

@test "mps_resolve_workdir: returns empty when no metadata file" {
    result="$(mps_resolve_workdir "mps-nonexistent")"
    [[ -z "$result" ]]
}

@test "mps_resolve_workdir: returns empty when metadata has no workdir" {
    local meta_file
    meta_file="$(mps_instance_meta "test")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"name":"test","cpus":2}' > "$meta_file"
    result="$(mps_resolve_workdir "mps-test")"
    [[ -z "$result" ]]
}

@test "mps_resolve_workdir: returns empty when workdir is null" {
    local meta_file
    meta_file="$(mps_instance_meta "test")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"workdir":null}' > "$meta_file"
    result="$(mps_resolve_workdir "mps-test")"
    [[ -z "$result" ]]
}

@test "mps_resolve_workdir: explicit workdir takes priority over metadata" {
    local meta_file
    meta_file="$(mps_instance_meta "test")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"workdir":"/from/metadata"}' > "$meta_file"
    result="$(mps_resolve_workdir "mps-test" "/from/argument")"
    [[ "$result" == "/from/argument" ]]
}
