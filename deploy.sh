#!/usr/bin/env bash
# Render the published templates with the real device identity and deploy them.
#
# The files in this repo carry placeholder serials so the repo can be public.
# local/substitutions.sed (gitignored) maps them back to the real device. See
# local/README.md.
#
#   ./deploy.sh            render to build/ and copy to the Pi
#   ./deploy.sh --render   render only, copy nothing
#
# Override the target with environment variables:
#   HA_HOST=192.168.0.25 HA_KEY=~/.ssh/id_ed25519 ./deploy.sh

set -euo pipefail

HA_HOST="${HA_HOST:-192.168.0.25}"
HA_USER="${HA_USER:-root}"
HA_KEY="${HA_KEY:-$HOME/.ssh/private-key_HomeAssistant_ed25519}"
SUBS="local/substitutions.sed"
RENDER_ONLY=0
[ "${1:-}" = "--render" ] && RENDER_ONLY=1

cd "$(dirname "$0")"

if [ ! -f "$SUBS" ]; then
    cat >&2 <<'MSG'
error: local/substitutions.sed not found.

The files in this repo use placeholder serials. Create local/substitutions.sed
mapping them to your own device, one sed expression per line, for example:

    s/0123456789ABCDEF/YOUR16HEXSERIAL0/g
    s/01000001/YOURELEC/g

See local/README.md for how to recover the real values from the Pi.
MSG
    exit 1
fi

# The placeholders are read out of the templates themselves: every serial-shaped
# token in ha-config/ must be gone from the rendered output.  Deriving the list
# here rather than from substitutions.sed is deliberate - a mapping file that is
# simply missing a rule would otherwise define the placeholder out of existence
# and be checked for nothing, deploying an entity that still filters on a
# placeholder serial: matching no message, and raising no error to say so.
SERIAL_RE='[0-9A-Fa-f]{16}|(01|02|08)[0-9A-Fa-f]{6}'

mkdir -p build
for f in ha-config/mqtt.yaml ha-config/automations-energomonitor.yaml; do
    out="build/$(basename "$f")"
    sed -f "$SUBS" "$f" > "$out"
    for p in $(grep -ohE "$SERIAL_RE" "$f" | sort -u); do
        if grep -q "$p" "$out"; then
            echo "error: $out still contains the placeholder '$p' - add a rule for it to $SUBS" >&2
            exit 1
        fi
    done
    printf "rendered %-46s %s lines\n" "$out" "$(wc -l < "$out")"
done

if [ "$RENDER_ONLY" = "1" ]; then
    echo
    echo "render only - nothing copied."
    exit 0
fi

SSH="ssh -i $HA_KEY -o BatchMode=yes $HA_USER@$HA_HOST"
STAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# /config/automations.yaml is not ours alone: Home Assistant's own automation
# editor writes every UI-created automation into that same file.  Copying over
# it - which this script used to do - deletes them silently, and there is no
# error to notice, only an automation that has quietly stopped existing.
#
# So the EnergoMonitor blocks are fenced between markers and only that fenced
# region is replaced.  Blocks carrying one of our ids but no fence are dropped
# too: that is what migrates an installation deployed by the older script,
# which wrote the blocks bare.
# ---------------------------------------------------------------------------
BEGIN_MARK="# >>> energomonitor - managed by deploy.sh, do not edit by hand >>>"
END_MARK="# <<< energomonitor - managed by deploy.sh <<<"

echo
echo "backing up on $HA_HOST"
$SSH "cp -a /config/mqtt.yaml /config/mqtt.yaml.bak-$STAMP 2>/dev/null || true"
$SSH "cp -a /config/automations.yaml /config/automations.yaml.bak-$STAMP 2>/dev/null || true"

echo "merging automations"
$SSH "cat /config/automations.yaml 2>/dev/null || true" > build/automations.remote.yaml

# Our own ids, read from the rendered file so adding a fourth automation needs
# no change here.
OUR_IDS=$(sed -nE "s/^- id: *//p" build/automations-energomonitor.yaml \
          | tr -d "\"'" | paste -sd, -)

# An empty automations.yaml is the literal "[]"; carrying that through would
# produce a list marker followed by a list.
grep -vE '^\[\]$' build/automations.remote.yaml > build/automations.stripped.yaml || true

awk -v DROP="$OUR_IDS" -v BM="$BEGIN_MARK" -v EM="$END_MARK" '
function flush(   i) {
    if (nb == 0) return
    if (id != "" && (id in drop)) { dropped++ }
    else {
        for (i = 1; i <= nb; i++) print buf[i]
        if (id != "") kept++
    }
    nb = 0; id = ""
}
BEGIN {
    n = split(DROP, list, ",")
    for (i = 1; i <= n; i++) drop[list[i]] = 1
    nb = 0; id = ""; kept = 0; dropped = 0; fenced = 0
}
$0 == BM { flush(); fenced = 1; next }
$0 == EM { fenced = 0; next }
fenced   { next }
/^- /    { flush() }
{
    buf[++nb] = $0
    if (id == "") {
        line = $0
        # \047 is a single quote - written octal to keep this awk program
        # embeddable in a single-quoted shell string.
        if (nb == 1 && sub(/^- +id: */, "", line)) {
            gsub(/^["\047]|["\047]$/, "", line); id = line
        } else if (sub(/^  id: */, "", line)) {
            gsub(/^["\047]|["\047]$/, "", line); id = line
        }
    }
}
END {
    flush()
    printf "  %d automation(s) preserved, %d EnergoMonitor block(s) replaced\n",
           kept, dropped > "/dev/stderr"
}
' build/automations.stripped.yaml > build/automations.merged.yaml

{
    echo "$BEGIN_MARK"
    cat build/automations-energomonitor.yaml
    echo "$END_MARK"
} >> build/automations.merged.yaml

echo "copying"
scp -i "$HA_KEY" -q build/mqtt.yaml "$HA_USER@$HA_HOST:/config/mqtt.yaml"
scp -i "$HA_KEY" -q build/automations.merged.yaml "$HA_USER@$HA_HOST:/config/automations.yaml"

echo "validating"
$SSH "ha core check"

cat <<'MSG'

Done. Two reloads are still needed in the Home Assistant UI:
  Developer Tools > YAML > Reload Automations
  Developer Tools > YAML > Manually configured MQTT entities
MSG
