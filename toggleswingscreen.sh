#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Configuration
# ============================================================

SWING_SERIAL="GHHYS83"
PERSONAL_SERIAL="5F19TJ3"

# Dell S2421HS VCP 0x60 input values
#
# DisplayPort = Windows
# HDMI        = Ubuntu
DP_INPUT=0x0f
HDMI_INPUT=0x11


# ============================================================
# Helpers
# ============================================================

# Resolve the current Linux connector name (DP-7, DP-8, etc.)
# from the monitor's EDID serial number.
get_connector_by_serial() {
    local serial="$1"

    gdctl show | awk -v wanted="$serial" '
        /Monitor [^ ]+/ {
            line = $0
            sub(/^.*Monitor /, "", line)
            sub(/ .*/, "", line)
            connector = line
        }

        /Serial:/ {
            line = $0
            sub(/^.*Serial:[[:space:]]*/, "", line)

            if (line == wanted) {
                print connector
                exit
            }
        }
    '
}


# Return success if a connector is currently part of the
# active GNOME logical-monitor topology.
monitor_is_active() {
    local connector="$1"

    gdctl show |
        sed -n '/^Logical monitors:/,$p' |
        grep -Fq -- "$connector ("
}


# Retry DDC switching because a newly enabled monitor can take
# a moment to expose its DDC interface again.
set_swing_input() {
    local input="$1"
    local attempts="${2:-1}"

    for ((i = 1; i <= attempts; i++)); do

        if ddcutil \
            --sn "$SWING_SERIAL" \
            setvcp 60 "$input"
        then
            return 0
        fi

        sleep 0.25
    done

    return 1
}


# ============================================================
# Discover monitors
# ============================================================

SWING="$(get_connector_by_serial "$SWING_SERIAL")"
PERSONAL="$(get_connector_by_serial "$PERSONAL_SERIAL")"

if [[ -z "$SWING" ]]; then
    echo "✗ Could not find swing monitor serial $SWING_SERIAL"
    exit 1
fi

if [[ -z "$PERSONAL" ]]; then
    echo "✗ Could not find personal monitor serial $PERSONAL_SERIAL"
    exit 1
fi

echo
echo "Swing monitor:"
echo "  $SWING_SERIAL -> $SWING"
echo
echo "Personal monitor:"
echo "  $PERSONAL_SERIAL -> $PERSONAL"
echo


# ============================================================
# Toggle
# ============================================================

if monitor_is_active "$SWING"; then

    # ========================================================
    # Ubuntu currently owns the swing monitor.
    #
    # Give it to Windows:
    #
    #   1. Switch physical monitor HDMI -> DP
    #   2. Remove swing monitor from Ubuntu topology
    #   3. Personal monitor becomes Ubuntu's only/primary screen
    # ========================================================

    echo "Giving swing monitor to Windows..."
    echo

    if ! set_swing_input "$DP_INPUT"; then
        echo "✗ Failed to switch swing monitor to DisplayPort"
        exit 1
    fi

    echo "✓ Swing monitor switched to DisplayPort"

    sleep 0.4

    gdctl set \
        --logical-monitor \
        --primary \
        --monitor "$PERSONAL"

    echo "✓ $SWING removed from Ubuntu desktop"
    echo "✓ $PERSONAL is now Ubuntu's single primary display"

    echo
    echo "Ubuntu is now in single-monitor mode."
    echo

else

    # ========================================================
    # Ubuntu currently does NOT own the swing monitor.
    #
    # Take it back:
    #
    #   1. Restore Ubuntu dual-monitor topology
    #   2. Personal monitor stays primary
    #   3. Swing monitor returns to right side
    #   4. Switch physical monitor DP -> HDMI
    # ========================================================

    echo "Taking swing monitor back for Ubuntu..."
    echo

    gdctl set \
        --logical-monitor \
        --primary \
        --monitor "$PERSONAL" \
        --logical-monitor \
        --monitor "$SWING" \
        --right-of "$PERSONAL"

    echo "✓ Ubuntu dual-monitor layout restored"

    sleep 0.5

    if ! set_swing_input "$HDMI_INPUT" 8; then
        echo "✗ Ubuntu restored $SWING, but DDC could not switch it to HDMI"
        exit 1
    fi

    echo "✓ Swing monitor switched to HDMI"

    echo
    echo "Ubuntu is now in dual-monitor mode."
    echo

fi