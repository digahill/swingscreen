#!/usr/bin/env bash
set -euo pipefail

SWING_SERIAL="GHHYS83"
PERSONAL_SERIAL="5F19TJ3"

# Dell S2421HS VCP 0x60 values
DP_INPUT=0x0f
HDMI_INPUT=0x11

# Known native modes
PERSONAL_WIDTH=1920
PERSONAL_HEIGHT=1080
PERSONAL_RATE="60.000"

SWING_WIDTH=1920
SWING_HEIGHT=1080
SWING_RATE="60.000"


get_info_by_serial() {
    local wanted="$1"

    gdctl show | awk -v wanted="$wanted" '
        /Monitor [^ ]+/ {
            line=$0
            sub(/^.*Monitor /,"",line)
            sub(/ .*/,"",line)
            connector=line
            vendor=""
            product=""
        }
        /Vendor:/ {
            line=$0
            sub(/^.*Vendor:[[:space:]]*/,"",line)
            vendor=line
        }
        /Product:/ {
            line=$0
            sub(/^.*Product:[[:space:]]*/,"",line)
            product=line
        }
        /Serial:/ {
            line=$0
            sub(/^.*Serial:[[:space:]]*/,"",line)
            serial=line

            if (serial == wanted) {
                print connector "|" vendor "|" product "|" serial
                exit
            }
        }
    '
}


get_builtin_info() {
    gdctl show | awk '
        /Monitor [^ ]+/ {
            line=$0
            sub(/^.*Monitor /,"",line)
            sub(/ .*/,"",line)
            connector=line
            vendor=""
            product=""
        }
        /Vendor:/ {
            line=$0
            sub(/^.*Vendor:[[:space:]]*/,"",line)
            vendor=line
        }
        /Product:/ {
            line=$0
            sub(/^.*Product:[[:space:]]*/,"",line)
            product=line
        }
        /Serial:/ {
            line=$0
            sub(/^.*Serial:[[:space:]]*/,"",line)
            serial=line

            if (connector ~ /^eDP-/) {
                print connector "|" vendor "|" product "|" serial
                exit
            }
        }
    '
}


monitor_is_active() {
    local connector="$1"

    gdctl show |
        sed -n '/^Logical monitors:/,$p' |
        grep -Fq -- "$connector ("
}


monitor_is_primary() {
    local connector="$1"

    gdctl show | awk -v wanted="$connector" '
        /^Logical monitors:/ {
            logical=1
            next
        }

        !logical { next }

        /Logical monitor #[0-9]+/ {
            primary=0
        }

        /Primary: yes/ {
            primary=1
        }

        index($0, wanted " (") && primary {
            ok=1
        }

        END {
            exit(ok ? 0 : 1)
        }
    '
}


logical_monitor_count() {
    gdctl show |
        sed -n '/^Logical monitors:/,$p' |
        grep -c 'Logical monitor #[0-9]' || true
}


set_swing_input() {
    local input="$1"
    local attempts="${2:-1}"

    for ((i=1; i<=attempts; i++)); do
        if ddcutil --sn "$SWING_SERIAL" setvcp 60 "$input"; then
            return 0
        fi
        sleep 0.25
    done

    return 1
}


save_verified_layout() {
    local layout="$1"

    LAYOUT="$layout" \
    SWING_CONNECTOR="$SWING" \
    SWING_VENDOR="$SWING_VENDOR" \
    SWING_PRODUCT="$SWING_PRODUCT" \
    SWING_SERIAL="$SWING_SERIAL" \
    PERSONAL_CONNECTOR="$PERSONAL" \
    PERSONAL_VENDOR="$PERSONAL_VENDOR" \
    PERSONAL_PRODUCT="$PERSONAL_PRODUCT" \
    PERSONAL_SERIAL="$PERSONAL_SERIAL" \
    BUILTIN_CONNECTOR="$BUILTIN" \
    BUILTIN_VENDOR="$BUILTIN_VENDOR" \
    BUILTIN_PRODUCT="$BUILTIN_PRODUCT" \
    BUILTIN_SERIAL="$BUILTIN_SERIAL" \
    PERSONAL_WIDTH="$PERSONAL_WIDTH" \
    PERSONAL_HEIGHT="$PERSONAL_HEIGHT" \
    PERSONAL_RATE="$PERSONAL_RATE" \
    SWING_WIDTH="$SWING_WIDTH" \
    SWING_HEIGHT="$SWING_HEIGHT" \
    SWING_RATE="$SWING_RATE" \
    python3 <<'PY'
import os
import shutil
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

layout = os.environ["LAYOUT"]

def env_monitor(prefix, include_mode=False):
    m = {
        "connector": os.environ.get(f"{prefix}_CONNECTOR", ""),
        "vendor": os.environ.get(f"{prefix}_VENDOR", ""),
        "product": os.environ.get(f"{prefix}_PRODUCT", ""),
        "serial": os.environ.get(f"{prefix}_SERIAL", ""),
    }
    if include_mode:
        m.update({
            "width": os.environ[f"{prefix}_WIDTH"],
            "height": os.environ[f"{prefix}_HEIGHT"],
            "rate": os.environ[f"{prefix}_RATE"],
        })
    return m

swing = env_monitor("SWING", True)
personal = env_monitor("PERSONAL", True)
builtin = env_monitor("BUILTIN", False)

config_dir = Path(
    os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))
)
config_dir.mkdir(parents=True, exist_ok=True)

path = config_dir / "monitors.xml"
backup = config_dir / "monitors.xml.before-swing-monitor"

if path.exists():
    try:
        tree = ET.parse(path)
        root = tree.getroot()
    except Exception as exc:
        raise SystemExit(f"Refusing to overwrite invalid {path}: {exc}")

    if root.tag != "monitors" or root.get("version") != "2":
        raise SystemExit(f"Unexpected monitors.xml format in {path}")

    if not backup.exists():
        shutil.copy2(path, backup)
else:
    root = ET.Element("monitors", {"version": "2"})
    tree = ET.ElementTree(root)


def serials_in(configuration):
    return {
        e.text.strip()
        for e in configuration.findall(".//monitorspec/serial")
        if e.text
    }


# Mutter supports one saved configuration per hardware set.
# Replace old configurations involving this exact pair of
# external monitors, but preserve unrelated configurations.
for config in list(root.findall("configuration")):
    serials = serials_in(config)
    if swing["serial"] in serials and personal["serial"] in serials:
        root.remove(config)


configuration = ET.SubElement(root, "configuration")
ET.SubElement(configuration, "layoutmode").text = "logical"


def add_spec(parent, m):
    spec = ET.SubElement(parent, "monitorspec")
    ET.SubElement(spec, "connector").text = m["connector"]
    ET.SubElement(spec, "vendor").text = m["vendor"]
    ET.SubElement(spec, "product").text = m["product"]
    ET.SubElement(spec, "serial").text = m["serial"]


def add_logical(m, x, y, primary):
    lm = ET.SubElement(configuration, "logicalmonitor")
    ET.SubElement(lm, "x").text = str(x)
    ET.SubElement(lm, "y").text = str(y)
    ET.SubElement(lm, "scale").text = "1"

    if primary:
        ET.SubElement(lm, "primary").text = "yes"

    mon = ET.SubElement(lm, "monitor")
    add_spec(mon, m)

    mode = ET.SubElement(mon, "mode")
    ET.SubElement(mode, "width").text = m["width"]
    ET.SubElement(mode, "height").text = m["height"]
    ET.SubElement(mode, "rate").text = m["rate"]


def add_disabled(m):
    if not m["connector"]:
        return
    disabled = ET.SubElement(configuration, "disabled")
    add_spec(disabled, m)


if layout == "single":
    add_logical(personal, 0, 0, True)
    add_disabled(swing)
    add_disabled(builtin)

elif layout == "dual":
    add_logical(personal, 0, 0, False)
    add_logical(swing, int(personal["width"]), 0, True)
    add_disabled(builtin)

else:
    raise SystemExit(f"Unknown layout: {layout}")


if hasattr(ET, "indent"):
    ET.indent(tree, space="  ")

fd, temp_name = tempfile.mkstemp(
    prefix=".monitors.xml.",
    dir=config_dir,
)
os.close(fd)
temp_path = Path(temp_name)

try:
    tree.write(
        temp_path,
        encoding="UTF-8",
        xml_declaration=True,
    )

    # Validate our own output before replacing the real file.
    ET.parse(temp_path)

    os.chmod(temp_path, 0o600)
    os.replace(temp_path, path)

finally:
    if temp_path.exists():
        temp_path.unlink()

print(f"Saved verified {layout} layout to {path}")
PY
}


# ------------------------------------------------------------
# Discover current connector names and monitor metadata.
# ------------------------------------------------------------

SWING_INFO="$(get_info_by_serial "$SWING_SERIAL")"
PERSONAL_INFO="$(get_info_by_serial "$PERSONAL_SERIAL")"
BUILTIN_INFO="$(get_builtin_info || true)"

if [[ -z "$SWING_INFO" ]]; then
    echo "✗ Could not find swing monitor serial $SWING_SERIAL"
    exit 1
fi

if [[ -z "$PERSONAL_INFO" ]]; then
    echo "✗ Could not find personal monitor serial $PERSONAL_SERIAL"
    exit 1
fi

IFS='|' read -r SWING SWING_VENDOR SWING_PRODUCT _ <<< "$SWING_INFO"
IFS='|' read -r PERSONAL PERSONAL_VENDOR PERSONAL_PRODUCT _ <<< "$PERSONAL_INFO"

BUILTIN=""
BUILTIN_VENDOR=""
BUILTIN_PRODUCT=""
BUILTIN_SERIAL=""

if [[ -n "$BUILTIN_INFO" ]]; then
    IFS='|' read -r \
        BUILTIN BUILTIN_VENDOR BUILTIN_PRODUCT BUILTIN_SERIAL \
        <<< "$BUILTIN_INFO"
fi


echo
echo "Swing:     $SWING_SERIAL -> $SWING"
echo "Personal:  $PERSONAL_SERIAL -> $PERSONAL"
[[ -n "$BUILTIN" ]] && echo "Built-in:  $BUILTIN_SERIAL -> $BUILTIN"
echo


# ============================================================
# DUAL -> SINGLE
# ============================================================

if monitor_is_active "$SWING"; then

    echo "Giving swing monitor to Windows..."
    echo

    if ! set_swing_input "$DP_INPUT"; then
        echo "✗ Failed to switch swing monitor to DisplayPort"
        exit 1
    fi

    echo "✓ Swing monitor switched to DisplayPort"
    sleep 0.4

    # Temporary apply = no Keep/Revert prompt.
    gdctl set \
        --logical-monitor \
        --primary \
        --monitor "$PERSONAL"

    sleep 0.3

    # Safety and correctness checks before persistence.
    monitor_is_active "$PERSONAL" || {
        echo "✗ Safety check failed: personal monitor is not active"
        exit 1
    }

    if monitor_is_active "$SWING"; then
        echo "✗ Verification failed: swing monitor is still active"
        exit 1
    fi

    [[ "$(logical_monitor_count)" -eq 1 ]] || {
        echo "✗ Verification failed: expected exactly one logical monitor"
        exit 1
    }

    monitor_is_primary "$PERSONAL" || {
        echo "✗ Verification failed: personal monitor is not primary"
        exit 1
    }

    echo "✓ Single-monitor layout verified"

    save_verified_layout single

    echo "✓ Single-monitor layout saved without GNOME confirmation prompt"
    echo
    echo "Ubuntu is now in single-monitor mode."
    exit 0
fi


# ============================================================
# SINGLE -> DUAL
# ============================================================

echo "Taking swing monitor back for Ubuntu..."
echo

# Temporary apply = no Keep/Revert prompt.
gdctl set \
    --logical-monitor \
    --monitor "$PERSONAL" \
    --logical-monitor \
    --primary \
    --monitor "$SWING" \
    --right-of "$PERSONAL"

sleep 0.4

# Safety and correctness checks before persistence.
monitor_is_active "$PERSONAL" || {
    echo "✗ Safety check failed: personal monitor is not active"
    exit 1
}

monitor_is_active "$SWING" || {
    echo "✗ Verification failed: swing monitor is not active"
    exit 1
}

[[ "$(logical_monitor_count)" -eq 2 ]] || {
    echo "✗ Verification failed: expected exactly two logical monitors"
    exit 1
}

monitor_is_primary "$SWING" || {
    echo "✗ Verification failed: swing monitor is not primary"
    exit 1
}

echo "✓ Dual-monitor layout verified"

save_verified_layout dual

echo "✓ Dual-monitor layout saved without GNOME confirmation prompt"

if ! set_swing_input "$HDMI_INPUT" 8; then
    echo "✗ Layout is active, but DDC could not switch swing monitor to HDMI"
    exit 1
fi

echo "✓ Swing monitor switched to HDMI"
echo
echo "Ubuntu is now in dual-monitor mode."
