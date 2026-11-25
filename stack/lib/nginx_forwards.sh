#!/usr/bin/env bash
# nginx_forwards.sh — psm_nginx_forwards, and (run as a script) the check
# nginx's systemd start hook runs: exit 1, naming them, when a forward leaves
# this server. Needs nothing but bash, find, sed and awk.

# Forwards in nginx's configuration that leave this server: a proxy_pass (or
# grpc/uwsgi/scgi/fastcgi/memcached_pass), an upstream server or a stream map
# value that is not loopback or a unix socket. roomkey runs none (PSM's own
# sites and SNI routes all go to 127.0.0.1): one would make the server an open
# relay, the DMIT failure again. One line per finding; nothing when clean.
# Checked before every reload (nginx_test_reload), before nginx starts
# (PSM's systemd drop-in) and by psm guard.
psm_nginx_forwards() {   # [nginx dir]
    local dir="${1:-${PSM_FS_ROOT:-}/etc/nginx}" f t text="" rc=0
    [[ -d "$dir" ]] || return 0
    # The configuration as nginx reads it: `nginx -T` (every include, whatever
    # its name, in order) for the live tree; otherwise every file of the tree
    # (the certificate store aside), links resolved inside it.
    if [[ "$dir" == /etc/nginx ]] && command -v nginx >/dev/null 2>&1 && text=$(nginx -T 2>/dev/null) && [[ -n "$text" ]]; then
        :
    else
        text=""
        local -a list=()
        while IFS= read -r -d '' f; do
            if [[ -L "$f" ]]; then
                t=$(readlink "$f")
                case "$t" in
                    /etc/nginx/*) t="$dir/${t#/etc/nginx/}" ;;
                    /*) echo "$f: links out of the nginx tree ($t)"; continue ;;
                    *) t="$(dirname "$f")/$t" ;;
                esac
                [[ -f "$t" ]] || { echo "$f: links to a missing file ($t)"; continue; }
                list+=("$t")
            elif [[ -f "$f" ]]; then
                list+=("$f")
            fi
        done < <(find "$dir" \( -path "$dir/ssl" -prune \) -o \( -type f -o -type l \) -print0 2>/dev/null)
        (( ${#list[@]} )) || return 0
        for f in "${list[@]}"; do
            text+=$'\n'"# configuration file $f:"$'\n'
            text+=$(cat -- "$f" 2>/dev/null) || rc=1
        done
    fi
    (( rc == 0 )) || echo "$dir: its files could not all be read"
    # Tokens split on ; { } (line breaks and one-line blocks alike), comments
    # and quotes dropped; then each statement checked:
    #  - proxy/grpc/uwsgi/scgi/fastcgi/memcached_pass: its host is loopback, a
    #    unix socket, an upstream (its servers checked) or a map variable (its
    #    values checked); any other variable is a finding;
    #  - upstream { server X }: X is loopback or a unix socket;
    #  - map ... $v { }: when $v feeds a *_pass, every value is loopback, a
    #    unix socket or empty;
    #  - an include inside a map or upstream block (its values unseen).
    printf '%s\n' "$text" | awk '
        function loc(t) {
            return t == "" || t ~ /^unix:/ || t ~ /^(127\.[0-9]+\.[0-9]+\.[0-9]+|localhost|\[::1\])(:[0-9]+)?$/
        }
        function hostof(t) { sub(/^[a-z]+:\/\//, "", t); sub(/\/.*$/, "", t); return t }
        /^# configuration file / { file = $4; sub(/:$/, "", file); fid++; next }
        {
            line = $0
            sub(/(^|[ \t])#.*$/, "", line)
            gsub(/["\047]/, "", line)
            gsub(/[{};]/, " & ", line)
            n = split(line, w, /[ \t]+/)
            for (i = 1; i <= n; i++) if (w[i] != "") { T[++nt] = w[i]; F[nt] = file; G[nt] = fid }
        }
        END {
            # statements: words up to ";" or "{", with the block they sit in
            depth = 0; nw = 0; ns = 0
            for (i = 1; i <= nt; i++) {
                t = T[i]
                if (i > 1 && G[i] != G[i - 1]) { depth = 0; nw = 0 }
                if (t == ";" || t == "{") {
                    if (nw) { ns++; SN[ns] = nw; for (k = 1; k <= nw; k++) SW[ns, k] = W[k]; SC[ns] = (depth ? CTX[depth] : ""); SF[ns] = F[i] }
                    if (t == "{") {
                        c = ""
                        if (W[1] == "upstream") { c = "up"; UPS[W[2]] = 1 }
                        else if (W[1] == "map") { c = "map " W[3]; MV[W[3]] = 1 }
                        CTX[++depth] = c
                    }
                    nw = 0; continue
                }
                if (t == "}") { if (depth) depth--; nw = 0; continue }
                W[++nw] = t
            }
            # map variables some *_pass reads
            for (s = 1; s <= ns; s++) if (SW[s, 1] ~ /^(proxy|grpc|uwsgi|scgi|fastcgi|memcached)_pass$/ && SN[s] >= 2) {
                h = hostof(SW[s, 2]); if (match(h, /^\$[A-Za-z0-9_]+/)) PV[substr(h, RSTART, RLENGTH)] = 1
            }
            for (s = 1; s <= ns; s++) {
                d = SW[s, 1]; c = SC[s]
                if (d ~ /^(proxy|grpc|uwsgi|scgi|fastcgi|memcached)_pass$/ && SN[s] >= 2) {
                    h = hostof(SW[s, 2])
                    if (match(h, /^\$[A-Za-z0-9_]+/)) {
                        # a map variable (its values checked below) and nothing
                        # else; a variable no map sets is chosen by the client
                        v = substr(h, RSTART, RLENGTH)
                        if (!(v in MV) || h !~ /^\$[A-Za-z0-9_]+(:[0-9]+)?$/) print SF[s] ": " d " " h
                        continue
                    }
                    if (loc(h) || (h in UPS)) continue
                    print SF[s] ": " d " " h
                } else if (c == "up" && d == "server" && SN[s] >= 2) {
                    if (!loc(SW[s, 2])) print SF[s] ": upstream server " SW[s, 2]
                } else if (c == "up" && d == "include") {
                    print SF[s] ": include inside an upstream block (" SW[s, 2] ")"
                } else if (c ~ /^map /) {
                    v = substr(c, 5)
                    if (d == "include") { print SF[s] ": include inside a map block (" SW[s, 2] ")"; continue }
                    if (!(v in PV) || SN[s] < 2) continue                  # hostnames / volatile, or not a route
                    val = SW[s, SN[s]]
                    if (!loc(val)) print SF[s] ": map " v " value " val
                }
            }
        }' || echo "$dir: the configuration could not be read"
    return 0
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    found=$(psm_nginx_forwards "${1:-/etc/nginx}")
    if [[ -n "$found" ]]; then
        echo "PSM: nginx not started: a forward leaves this server (roomkey runs none; it would be an open relay):" >&2
        printf '  %s\n' "${found//$'\n'/$'\n'  }" >&2
        exit 1
    fi
    exit 0
fi
