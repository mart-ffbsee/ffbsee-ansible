#!/bin/bash
# Shared VXLAN functions for backbone but also normal nodes setup- scripts


# Interface checks

vx_exists() {
    local iface="$1"
    [ -d "/sys/class/net/$iface" ]
}

vx_link_up() {
    local iface="$1"

    if ! vx_exists "$iface"; then
        return 1
    fi

    ip link show dev "$iface" | grep -q "UP"
}

vx_added_to_bat() {
    local iface="$1"
    local meshif="${2:-bat0}"
    local batctlcmd="${BATCTL_CMD:-/usr/local/sbin/batctl}"

    "$batctlcmd" meshif "$meshif" if | grep -q "^$iface: active"
}

vx_any_problem() {
    local iface="$1"
    local meshif="${2:-bat0}"

    if ! vx_exists "$iface"; then
        return 0
    fi

    if ! vx_link_up "$iface"; then
        return 0
    fi

    if ! vx_added_to_bat "$iface" "$meshif"; then
        return 0
    fi

    return 1
}


# VXLAN FDB helpers

vxlan_current_fdb_endpoints() {
    local iface="$1"

    bridge fdb show dev "$iface" |
        awk '/00:00:00:00:00:00/ && /dst/ {
            for (i=1; i<=NF; i++) {
                if ($i == "dst") print $(i+1)
            }
        }' |
        sort -u
}

vxlan_sync_fdb() {
    local iface="$1"
    local own_ip="$2"
    shift 2

    local endpoints current expected missing obsolete dst

    echo "checking FDB entries for $iface..."

    current="$(vxlan_current_fdb_endpoints "$iface")"

    expected="$(
        printf "%s\n" "$@" |
            sed '/^[[:space:]]*$/d' |
            grep -v -F "$own_ip" |
            sort -u
    )"

    missing="$(comm -13 <(printf "%s\n" "$current") <(printf "%s\n" "$expected"))"
    obsolete="$(comm -23 <(printf "%s\n" "$current") <(printf "%s\n" "$expected"))"

    for dst in $missing; do
        echo "FDB missing for $dst, adding it"
        bridge fdb append to 00:00:00:00:00:00 dst "$dst" dev "$iface"
    done

    for dst in $obsolete; do
        echo "FDB entry for $dst is obsolete, deleting it"
        bridge fdb del to 00:00:00:00:00:00 dst "$dst" dev "$iface" || true
    done
}

vxlan_add_fdb_endpoint() {
    local iface="$1"
    local dst="$2"

    if bridge fdb show dev "$iface" | grep -q "00:00:00:00:00:00.*dst $dst"; then
        echo "FDB entry for $dst already exists on $iface"
    else
        echo "Adding FDB endpoint $dst to $iface"
        bridge fdb append to 00:00:00:00:00:00 dst "$dst" dev "$iface"
    fi
}

vxlan_remove_fdb_endpoint() {
    local iface="$1"
    local dst="$2"

    echo "Removing FDB endpoint $dst from $iface"
    bridge fdb del to 00:00:00:00:00:00 dst "$dst" dev "$iface" || true
}


# Node peer state helpers (for normal nodes)

node_state_endpoints_from_json() {
    local state_dir="$1"

    [ -d "$state_dir" ] || return 0

    for file in "$state_dir"/*.json; do
        [ -e "$file" ] || continue

        python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    node_ip = data.get("node_ip")
    if node_ip:
        print(node_ip)

except Exception:
    pass
PY
    done | sort -u
}

vxlan_sync_fdb_from_node_state() {
    local iface="$1"
    local own_ip="$2"
    local state_dir="$3"

    local endpoints

    mapfile -t endpoints < <(node_state_endpoints_from_json "$state_dir")

    vxlan_sync_fdb "$iface" "$own_ip" "${endpoints[@]}"
}


# Interface setup helper

vxlan_create_if_missing() {
    local iface="$1"
    local vni="$2"
    local dstport="$3"
    local underlay_if="$4"
    local mac="$5"
    local mtu="$6"

    if vx_exists "$iface"; then
        echo "$iface already exists"
        return 0
    fi

    echo "Creating VXLAN interface $iface"

    ip -6 link add "$iface" type vxlan id "$vni" dstport "$dstport" dev "$underlay_if"
    ip -6 link set dev "$iface" address "$mac"
    ip -6 link set up dev "$iface"

    ip -6 addr flush dev "$iface"
    ip -6 link set mtu "$mtu" dev "$iface"
}

vxlan_ensure_up() {
    local iface="$1"

    if ! vx_link_up "$iface"; then
        echo "$iface is down, setting it up"
        ip link set up dev "$iface"
    fi
}

vxlan_ensure_added_to_bat() {
    local iface="$1"
    local meshif="${2:-bat0}"
    local throughput_override="${3:-}"
    local batctlcmd="${BATCTL_CMD:-/usr/local/sbin/batctl}"

    if ! vx_added_to_bat "$iface" "$meshif"; then
        echo "$iface not added to $meshif yet, adding it"
        "$batctlcmd" meshif "$meshif" if add "$iface"
    else
        echo "$iface already added to $meshif"
    fi

    if [ -n "$throughput_override" ]; then
        "$batctlcmd" meshif "$meshif" hardif "$iface" throughput_override "$throughput_override"
    fi
}
