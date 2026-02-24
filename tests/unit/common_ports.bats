#!/usr/bin/env bats
# Tests for port forwarding helper functions in lib/common.sh:
#   mps_ports_file, mps_port_socket, mps_port_forward_count,
#   mps_collect_port_specs

load ../test_helper

setup()    { setup_home_override; }
teardown() { teardown_home_override; }

# ================================================================
# mps_ports_file
# ================================================================

@test "mps_ports_file: returns correct path" {
    result="$(mps_ports_file "mydev")"
    [[ "$result" == *"/.mps/instances/mydev.ports.json" ]]
}

# ================================================================
# mps_port_socket
# ================================================================

@test "mps_port_socket: returns socket path with instance and port" {
    result="$(mps_port_socket "mydev" "8080")"
    [[ "$result" == "${HOME}/.mps/sockets/mydev-8080.sock" ]]
}

@test "mps_port_socket: creates sockets directory" {
    mps_port_socket "mydev" "8080" >/dev/null
    [[ -d "${HOME}/.mps/sockets" ]]
}

# ================================================================
# mps_port_forward_count
# ================================================================

@test "mps_port_forward_count: returns 0 when no ports file" {
    result="$(mps_port_forward_count "noinstance")"
    [[ "$result" == "0" ]]
}

@test "mps_port_forward_count: counts entries in ports file" {
    local pf_file
    pf_file="$(mps_ports_file "mydev")"
    mkdir -p "$(dirname "$pf_file")"
    echo '{"8080":{"guest_port":80},"9090":{"guest_port":90}}' > "$pf_file"
    result="$(mps_port_forward_count "mydev")"
    [[ "$result" == "2" ]]
}

# ================================================================
# mps_collect_port_specs
# ================================================================

@test "mps_collect_port_specs: returns empty when no ports configured" {
    unset MPS_PORTS
    result="$(mps_collect_port_specs "noinstance")"
    [[ -z "$result" ]]
}

@test "mps_collect_port_specs: collects from MPS_PORTS" {
    export MPS_PORTS="8080:80 9090:9090"
    result="$(mps_collect_port_specs "noinstance")"
    [[ "$result" == *"8080:80"* ]]
    [[ "$result" == *"9090:9090"* ]]
}

@test "mps_collect_port_specs: deduplicates by host port" {
    export MPS_PORTS="8080:80 8080:8080"
    result="$(mps_collect_port_specs "noinstance")"
    local count
    count="$(echo "$result" | grep -c "8080:")"
    [[ "$count" -eq 1 ]]
}

@test "mps_collect_port_specs: merges config and metadata sources" {
    export MPS_PORTS="8080:80"
    # Create instance metadata with port_forwards
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"port_forwards":["9090:9090"]}' > "$meta_file"

    result="$(mps_collect_port_specs "testinst")"
    [[ "$result" == *"8080:80"* ]]
    [[ "$result" == *"9090:9090"* ]]
}

@test "mps_collect_port_specs: config ports take priority over metadata" {
    export MPS_PORTS="8080:80"
    # Metadata has same host port but different guest port
    local meta_file
    meta_file="$(mps_instance_meta "testinst")"
    mkdir -p "$(dirname "$meta_file")"
    echo '{"port_forwards":["8080:8888"]}' > "$meta_file"

    result="$(mps_collect_port_specs "testinst")"
    [[ "$result" == *"8080:80"* ]]
    # Should NOT contain the metadata version
    local count
    count="$(echo "$result" | grep -c "8080:")"
    [[ "$count" -eq 1 ]]
}

# ================================================================
# mps_cleanup_port_sockets
# ================================================================

@test "mps_cleanup_port_sockets: removes sockets for instance" {
    local sock_dir="${HOME}/.mps/sockets"
    mkdir -p "$sock_dir"
    touch "${sock_dir}/mydev-8080.sock"
    touch "${sock_dir}/mydev-9090.sock"
    mps_cleanup_port_sockets "mydev"
    [[ ! -e "${sock_dir}/mydev-8080.sock" ]]
    [[ ! -e "${sock_dir}/mydev-9090.sock" ]]
}

@test "mps_cleanup_port_sockets: preserves other instances' sockets" {
    local sock_dir="${HOME}/.mps/sockets"
    mkdir -p "$sock_dir"
    touch "${sock_dir}/mydev-8080.sock"
    touch "${sock_dir}/other-8080.sock"
    mps_cleanup_port_sockets "mydev"
    [[ ! -e "${sock_dir}/mydev-8080.sock" ]]
    [[ -e "${sock_dir}/other-8080.sock" ]]
}

@test "mps_cleanup_port_sockets: handles no matching sockets" {
    mkdir -p "${HOME}/.mps/sockets"
    run mps_cleanup_port_sockets "nonexistent"
    [[ "$status" -eq 0 ]]
}

@test "mps_cleanup_port_sockets: handles missing sockets directory" {
    run mps_cleanup_port_sockets "anyname"
    [[ "$status" -eq 0 ]]
}

@test "mps_cleanup_port_sockets: removes multiple sockets for same instance" {
    local sock_dir="${HOME}/.mps/sockets"
    mkdir -p "$sock_dir"
    touch "${sock_dir}/dev-3000.sock"
    touch "${sock_dir}/dev-3001.sock"
    touch "${sock_dir}/dev-8080.sock"
    touch "${sock_dir}/dev-9090.sock"
    mps_cleanup_port_sockets "dev"
    local remaining
    remaining="$(ls "${sock_dir}"/dev-*.sock 2>/dev/null | wc -l)"
    [[ "$remaining" -eq 0 ]]
}
