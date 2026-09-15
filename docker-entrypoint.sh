#!/usr/bin/env bash
# Prepare the container for PrusaLink, then drop privileges.
#
# PrusaLink in a container always runs with -f (foreground), and config.py:117
# does an unconditional getpwuid(getuid()) on that path. A UID with no
# /etc/passwd entry therefore raises KeyError before the web server ever binds.
# That is why this script *materializes* a user rather than just setuid'ing.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
DATA_DIR="${PRUSALINK_DATA_DIR:-/data}"
CONFIG_DIR="${PRUSALINK_CONFIG_DIR:-/etc/prusalink}"
CONFIG_FILE="${CONFIG_DIR}/prusalink.ini"
TEMPLATE="/usr/local/share/prusalink/prusalink.ini.template"

log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }

# Seeded once; after that the file belongs to the operator and is never
# rewritten. Shared by the root and non-root paths so the placeholder
# substitutions cannot drift out of one of them.
seed_config() {
    if [ -f "${CONFIG_FILE}" ]; then
        log "using existing ${CONFIG_FILE}"
        return 0
    fi

    if ! sed -e "s|@DATA_DIR@|${DATA_DIR}|g" \
             -e "s|@PORT@|${PRUSALINK_PORT:-8080}|g" \
             -e "s|@SERIAL_PORT@|${PRUSALINK_SERIAL_PORT:-auto}|g" \
             "${TEMPLATE}" > "${CONFIG_FILE}" 2>/dev/null; then
        rm -f "${CONFIG_FILE}"
        warn "cannot write ${CONFIG_FILE} -- is ${CONFIG_DIR} writable by $(id -u)?"
        warn "PrusaLink will fail to start without it."
        return 1
    fi
    log "seeded ${CONFIG_FILE}"
}

# If the operator already pinned a UID with `docker run --user`, we have no
# privileges left to arrange anything. Verify the one thing that will crash
# PrusaLink and hand off.
if [ "$(id -u)" -ne 0 ]; then
    if ! getent passwd "$(id -u)" >/dev/null; then
        warn "UID $(id -u) has no /etc/passwd entry."
        warn "PrusaLink calls getpwuid() at startup and will exit with KeyError."
        warn "Prefer PUID/PGID environment variables over --user, or add"
        warn "--user with a UID that exists in the image."
    fi
    seed_config || true
    exec "$@"
fi

# --- user and group -------------------------------------------------------
if ! getent group "${PGID}" >/dev/null; then
    groupadd -g "${PGID}" prusalink
fi
GROUP_NAME="$(getent group "${PGID}" | cut -d: -f1)"

if ! getent passwd "${PUID}" >/dev/null; then
    useradd -u "${PUID}" -g "${PGID}" -d "${DATA_DIR}" -M -s /usr/sbin/nologin prusalink
fi
USER_NAME="$(getent passwd "${PUID}" | cut -d: -f1)"
log "running as ${USER_NAME}(${PUID}):${GROUP_NAME}(${PGID})"

# --- serial device access -------------------------------------------------
# /dev/ttyACM0 is owned root:dialout on the host, but the dialout GID is not
# portable (20 on Debian, 18 elsewhere, different again on some Pi images), and
# only the host's numeric GID is visible from inside the container. Reading the
# GID off the device itself and joining that exact group is what makes
# privileged: true unnecessary.
join_device_group() {
    local dev="$1" gid gname
    [ -e "${dev}" ] || return 0

    gid="$(stat -c '%g' "${dev}")"
    if [ "${gid}" = "0" ]; then
        warn "${dev} is group-owned by root; refusing to add ${USER_NAME} to GID 0."
        warn "Fix the device's group on the host, or pass group_add: [...] in compose."
        return 0
    fi

    if ! getent group "${gid}" >/dev/null; then
        groupadd -g "${gid}" "serialdev${gid}"
    fi
    gname="$(getent group "${gid}" | cut -d: -f1)"

    if ! id -nG "${USER_NAME}" | tr ' ' '\n' | grep -qx "${gname}"; then
        usermod -aG "${gname}" "${USER_NAME}"
        log "granted ${dev} access via group ${gname}(${gid})"
    fi
}

shopt -s nullglob
found_device=0
for dev in /dev/ttyACM* /dev/ttyUSB* /dev/ttyAMA* /dev/serial/by-id/*; do
    join_device_group "${dev}"
    found_device=1
done
for dev in /dev/video*; do
    join_device_group "${dev}"
done
shopt -u nullglob

if [ "${found_device}" -eq 0 ]; then
    warn "no serial devices found in the container."
    warn "Pass the printer through, e.g.:"
    warn "  devices: [ \"/dev/serial/by-id/usb-Prusa_...:/dev/ttyACM0\" ]"
fi

# --- configuration --------------------------------------------------------
seed_config

# Only the top level, so a large gcode library does not make every restart
# walk the whole tree.
chown "${PUID}:${PGID}" "${DATA_DIR}" "${CONFIG_DIR}" "${CONFIG_FILE}"
find "${DATA_DIR}" -maxdepth 1 -mindepth 1 ! -user "${PUID}" \
    -exec chown -R "${PUID}:${PGID}" {} +

# /run/udev being absent is not fatal, but auto-detection cannot work without
# it: util.py:267 matches ID_VENDOR_ID/ID_MODEL_ID udev properties against
# SUPPORTED_PRINTERS, and those properties are empty when udev data is missing.
if [ ! -d /run/udev ] && grep -qE '^\s*port\s*=\s*auto' "${CONFIG_FILE}"; then
    warn "port = auto but /run/udev is not mounted; USB auto-detection will find nothing."
    warn "Add   - /run/udev:/run/udev:ro   or set an explicit port in prusalink.ini."
fi

exec gosu "${USER_NAME}" "$@"
