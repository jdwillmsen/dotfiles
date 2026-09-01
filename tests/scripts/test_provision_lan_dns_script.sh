#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the script under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-lan-dns.sh"
shellcheck -s bash "$script"

grep -q '\[ "\$(id -u)" = 0 \] ||' "$script" || { echo "FAIL: no root check"; exit 1; }
root_line=$(grep -n '\[ "\$(id -u)" = 0 \] ||' "$script" | head -1 | cut -d: -f1)
write_line=$(grep -n '^\s*printf .* >"\$DROPIN"' "$script" | head -1 | cut -d: -f1)
[ -n "$write_line" ] || { echo "FAIL: no drop-in write found"; exit 1; }
[ "$root_line" -lt "$write_line" ] || { echo "FAIL: root check must run before writing under /etc"; exit 1; }

# A bare DNS= with no Domains= replaces the machine's default nameservers, which
# takes all resolution down with the HAProxy VM instead of just jdwlabs.com.
grep -q '^Domains=~\$DOMAIN$' "$script" || { echo "FAIL: drop-in must scope DNS to a routing domain"; exit 1; }
grep -q '^DNS=\$RESOLVER \$FALLBACK$' "$script" || { echo "FAIL: drop-in must list the gateway as a fallback resolver"; exit 1; }

# Writing the file proves nothing about which resolver actually wins the lookup.
grep -q 'resolvectl query' "$script" || { echo "FAIL: no live resolution check"; exit 1; }
verify_line=$(grep -n 'resolvectl query' "$script" | head -1 | cut -d: -f1)
[ "$write_line" -lt "$verify_line" ] || { echo "FAIL: verification must follow the write"; exit 1; }

for var in RESOLVER FALLBACK DOMAIN DROPIN; do
    grep -q "^$var=\${$var:-" "$script" || { echo "FAIL: no $var override"; exit 1; }
done

grep -q 'Remove .* and restart systemd-resolved' "$script" || { echo "FAIL: no rollback instruction"; exit 1; }
echo "PASS"
