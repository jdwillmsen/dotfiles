#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-monitoring.sh"
shellcheck -s bash "$script"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$script" ] || fail "provision-monitoring.sh must be executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Every root-touching command is a stub that records its argv, so the script
# runs end to end here without root and the assertions are on what it asked
# the system to do.
mkdir -p "$tmp/bin"
for c in apt-get systemctl; do
    cat >"$tmp/bin/$c" <<EOF
#!/usr/bin/env bash
echo "$c \$*" >>"$tmp/calls"
EOF
    chmod +x "$tmp/bin/$c"
done

run() {  # $1 = uid the stub id reports, rest = env assignments -> sets out, rc
    local uid="$1"
    shift
    printf '#!/usr/bin/env bash\necho %s\n' "$uid" >"$tmp/bin/id"
    chmod +x "$tmp/bin/id"
    : >"$tmp/calls"
    rm -rf "$tmp/root"
    rc=0
    out="$(env PATH="$tmp/bin:$PATH" PROVISION_ROOT="$tmp/root" "$@" \
        bash "$script" 2>&1)" || rc=$?
    calls="$(cat "$tmp/calls")"
}

# ── refuses without root, before touching anything ──
run 1000
[ "$rc" -ne 0 ] || fail "ran without root"
echo "$out" | grep -q "must run as root" || fail "no diagnostic without root" "$out"
[ -z "$calls" ] || fail "mutated the system before the root check" "$calls"

# ── default run ──
run 0
[ "$rc" -eq 0 ] || fail "default run failed" "$out"
echo "$calls" | grep -qx "apt-get install -y -qq atop" || fail "atop not installed" "$calls"

# The config is read by a shell (atop.daily) and by systemd as an
# EnvironmentFile, so it is parsed the way they parse it, not grepped.
# shellcheck disable=SC1091  # written by the run above
( . "$tmp/root/etc/default/atop"
  [ "$LOGINTERVAL" = 60 ] || fail "default interval is $LOGINTERVAL, not 60"
  [ "$LOGGENERATIONS" = 14 ] || fail "default retention is $LOGGENERATIONS, not 14"
  [ "$LOGPATH" = /var/log/atop ] || fail "default log path is $LOGPATH" )

echo "$calls" | grep -q "^systemctl enable --now .*atopacct.service" || fail "process accounting not enabled" "$calls"
echo "$calls" | grep -q "^systemctl enable --now .*atop-rotate.timer" || fail "daily rotation not enabled" "$calls"
echo "$calls" | grep -qx "systemctl enable atop.service" || fail "logger not enabled at boot" "$calls"

# A logger already running keeps its old interval until restarted, so the
# restart has to come after the config is written — i.e. after install.
install_at="$(echo "$calls" | grep -n "apt-get install" | cut -d: -f1)"
restart_at="$(echo "$calls" | grep -n "^systemctl restart atop.service$" | cut -d: -f1 || true)"
[ -n "$restart_at" ] || fail "logger not restarted, so a new interval never applies" "$calls"
[ "$restart_at" -gt "$install_at" ] || fail "logger restarted before install" "$calls"

# ── overrides ──
run 0 ATOP_INTERVAL=30 ATOP_GENERATIONS=3 ATOP_LOGPATH="$tmp/logs"
[ "$rc" -eq 0 ] || fail "override run failed" "$out"
# shellcheck disable=SC1091
( . "$tmp/root/etc/default/atop"
  if [ "$LOGINTERVAL" != 30 ] || [ "$LOGGENERATIONS" != 3 ] || [ "$LOGPATH" != "$tmp/logs" ]; then
      fail "overrides not written" "$(cat "$tmp/root/etc/default/atop")"
  fi )

# A leading zero is decimal, not octal, and is written normalised.
run 0 ATOP_INTERVAL=030 ATOP_GENERATIONS=08
[ "$rc" -eq 0 ] || fail "rejected a zero-padded value" "$out"
# shellcheck disable=SC1091
( . "$tmp/root/etc/default/atop"
  if [ "$LOGINTERVAL" != 30 ] || [ "$LOGGENERATIONS" != 8 ]; then
      fail "zero-padded values not normalised" "$(cat "$tmp/root/etc/default/atop")"
  fi )

# A bad value would be written straight into a file systemd refuses to start
# atop with, so it must stop the run before any change is made.
# shellcheck disable=SC2016  # the $(id) is a literal the script must reject
for bad in "ATOP_INTERVAL=0" "ATOP_INTERVAL=00" "ATOP_INTERVAL=1m" \
    "ATOP_GENERATIONS=-1" "ATOP_GENERATIONS=000" \
    "ATOP_LOGPATH=var/log/atop" "ATOP_LOGPATH=/var/log/at op" \
    'ATOP_LOGPATH=/var/log/$(id)' 'ATOP_LOGPATH=/var/log/a"b'; do
    run 0 "$bad"
    [ "$rc" -ne 0 ] || fail "accepted $bad"
    [ -z "$calls" ] || fail "mutated the system despite $bad" "$calls"
    [ ! -e "$tmp/root/etc/default/atop" ] || fail "wrote config despite $bad"
done

echo "PASS"
