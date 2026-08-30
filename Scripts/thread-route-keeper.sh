#!/bin/bash
#
# thread-route-keeper — keep this Mac's route into the Thread mesh alive.
#
# This Mac is not a Thread device: it reaches Thread nodes only over a route
# the border routers announce in their Router Advertisements (a Route
# Information Option for the mesh's OMR prefix). That route has a lifetime and
# has to be refreshed. When the refresh stops — the BRs drop the RIO during
# prefix churn, or the RAs get lost — macOS expires the route and every Thread
# device becomes unreachable *from this Mac* while Apple Home, whose hubs sit
# in the mesh themselves, keeps working perfectly. Seen repeatedly through
# August 2026; each time a hand-installed route fixed it instantly.
#
# So: find the mesh prefix, check whether we can actually reach it, and if not,
# install a route via whichever border router answers. The prefix is discovered
# fresh every run and never hardcoded — it has changed six times here (fdd2 →
# fdc0 → fd5a → fd4c → fd76 → fd26), so a pinned one would be worse than none.
#
# Runs as root from a LaunchDaemon (see de.nicx.thread-route-keeper.plist);
# installing a route needs root, and a daemon also survives reboots, which a
# hand-typed `route add` does not.

set -u

IFACE="${THREAD_ROUTE_IFACE:-en9}"
LOG="${THREAD_ROUTE_LOG:-/var/log/thread-route-keeper.log}"
BROWSE_SECONDS=4
RESOLVE_SECONDS=3
# How many advertised Matter services to resolve. Only enough to out-vote the
# handful of Matter-over-WiFi devices, whose addresses sit on the LAN prefix.
SAMPLE_INSTANCES=4

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Run a streaming dns-sd command for a fixed time and capture its output.
dns_sd_capture() {
    local seconds="$1" out="$2"; shift 2
    "$@" > "$out" 2>&1 &
    local pid=$!
    sleep "$seconds"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

# Every /64 prefix currently advertised on-link (from a PIO) or otherwise
# directly attached. Those need no gateway, and one of them is the border
# routers' own on-link prefix — excluding them leaves the mesh prefix.
onlink_prefixes() {
    netstat -rn -f inet6 2>/dev/null \
        | awk -v ifc="$IFACE" '$1 ~ /::\/64$/ && $2 ~ /^link#/ && $NF == ifc {sub(/::\/64$/, "", $1); print tolower($1)}'
}

# The mesh prefix and one address inside it we can ping, discovered from what
# the devices themselves advertise over mDNS. Prints "<prefix> <address>".
discover_mesh() {
    dns_sd_capture "$BROWSE_SECONDS" "$TMP/browse" dns-sd -B _matter._tcp local.
    local instances
    instances=$(grep -a ' Add ' "$TMP/browse" | awk '{print $NF}' | sort -u | head -"$SAMPLE_INSTANCES")
    [ -z "$instances" ] && return 1

    local onlink
    onlink=$(onlink_prefixes)

    : > "$TMP/addrs"
    local inst host
    for inst in $instances; do
        dns_sd_capture "$RESOLVE_SECONDS" "$TMP/srv" dns-sd -L "$inst" _matter._tcp local.
        host=$(grep -aoE '[0-9A-Fa-f]{12,16}\.local' "$TMP/srv" | head -1)
        [ -z "$host" ] && continue
        dns_sd_capture "$RESOLVE_SECONDS" "$TMP/aaaa" dns-sd -G v6 "$host"
        grep -a ' Add ' "$TMP/aaaa" | awk '{print $6}' | sed 's/%.*//' >> "$TMP/addrs"
    done
    [ -s "$TMP/addrs" ] || return 1

    # Group the discovered addresses by /64 and drop anything already on-link
    # (the LAN itself, and the BRs' on-link prefix). The most common survivor
    # is the mesh.
    #
    # Hextets are stripped of leading zeros so the result is spelled the way
    # netstat and route do it (fd26:5a55:2bf9:1, not …:0001); otherwise the
    # on-link comparison below and the route lookup later silently never match.
    local prefix addr p skip
    while read -r addr; do
        [ -z "$addr" ] && continue
        p=$(echo "$addr" | tr 'A-F' 'a-f' | awk -F: '{
            out = ""
            for (i = 1; i <= 4; i++) {
                h = $i
                sub(/^0+/, "", h)
                if (h == "") h = "0"
                out = (i == 1) ? h : out ":" h
            }
            print out
        }')
        skip=0
        for o in $onlink; do
            [ "$p" = "$o" ] && skip=1 && break
        done
        [ "$skip" = "1" ] && continue
        echo "$p|$addr"
    done < "$TMP/addrs" | sort > "$TMP/candidates"
    [ -s "$TMP/candidates" ] || return 1

    prefix=$(cut -d'|' -f1 "$TMP/candidates" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
    addr=$(grep "^$prefix|" "$TMP/candidates" | head -1 | cut -d'|' -f2)
    echo "$prefix $addr"
}

reachable() {
    ping6 -c 2 "$1" > /dev/null 2>&1
}

main() {
    local discovered prefix probe
    discovered=$(discover_mesh) || { log "no Matter services advertised — nothing to do"; exit 0; }
    prefix=$(echo "$discovered" | awk '{print $1}')
    probe=$(echo "$discovered" | awk '{print $2}')

    # The common case: the route the border routers announced is there and
    # works. Say nothing, so the log only ever holds real events.
    if reachable "$probe"; then
        exit 0
    fi

    log "mesh $prefix::/64 unreachable (probe $probe) — looking for a working gateway"

    # Every router that has recently sent us an RA is a candidate. Try the one
    # already installed first, if any: when it works again after a blip, that
    # avoids pointlessly moving the route somewhere else.
    local current candidates gw
    current=$(netstat -rn -f inet6 2>/dev/null | awk -v p="$prefix::/64" '$1 == p {print $2}' | head -1)
    candidates=$(ndp -rn 2>/dev/null | awk -v ifc="%$IFACE" '$1 ~ ifc {print $1}')
    [ -n "$current" ] && candidates="$current $(echo "$candidates" | grep -vFx "$current")"
    [ -z "$candidates" ] && { log "no border routers are advertising — giving up this round"; exit 0; }

    for gw in $candidates; do
        route delete -inet6 "$prefix::/64" > /dev/null 2>&1
        route add -inet6 "$prefix::/64" "$gw" > /dev/null 2>&1 || continue
        if reachable "$probe"; then
            log "route installed: $prefix::/64 via $gw — mesh reachable again"
            exit 0
        fi
    done

    # Nothing worked. Leave no half-broken route behind: without one, macOS can
    # still pick the prefix up again on its own from the next usable RA.
    route delete -inet6 "$prefix::/64" > /dev/null 2>&1
    log "no gateway could reach $prefix::/64 (tried: $(echo $candidates | tr '\n' ' ')) — left routing to the system"
}

main "$@"
