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

mkdir -p build
for f in ha-config/mqtt.yaml ha-config/automations-energomonitor.yaml; do
    out="build/$(basename "$f")"
    sed -f "$SUBS" "$f" > "$out"
    left=$(grep -c "0123456789ABCDEF" "$out" || true)
    if [ "$left" != "0" ]; then
        echo "error: $out still contains the placeholder serial - check $SUBS" >&2
        exit 1
    fi
    printf "rendered %-46s %s lines\n" "$out" "$(wc -l < "$out")"
done

if [ "$RENDER_ONLY" = "1" ]; then
    echo
    echo "render only - nothing copied."
    exit 0
fi

SSH="ssh -i $HA_KEY -o BatchMode=yes $HA_USER@$HA_HOST"
STAMP=$(date +%Y%m%d-%H%M%S)

echo
echo "backing up on $HA_HOST"
$SSH "cp -a /config/mqtt.yaml /config/mqtt.yaml.bak-$STAMP 2>/dev/null || true"
$SSH "cp -a /config/automations.yaml /config/automations.yaml.bak-$STAMP 2>/dev/null || true"

echo "copying"
scp -i "$HA_KEY" -q build/mqtt.yaml "$HA_USER@$HA_HOST:/config/mqtt.yaml"
scp -i "$HA_KEY" -q build/automations-energomonitor.yaml "$HA_USER@$HA_HOST:/config/automations.yaml"

echo "validating"
$SSH "ha core check"

cat <<'MSG'

Done. Two reloads are still needed in the Home Assistant UI:
  Developer Tools > YAML > Reload Automations
  Developer Tools > YAML > Manually configured MQTT entities
MSG
