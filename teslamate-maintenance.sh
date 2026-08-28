#!/usr/bin/env bash
# Interactive maintenance menu for a docker compose TeslaMate installation.
# Covers the tasks from https://docs.teslamate.org/ under Maintenance:
# backup, restore, closing/deleting drives and charges, removing a vehicle,
# reindexing and major PostgreSQL upgrades.
#
# Configuration (environment variables, all optional):
#   TM_DIR       compose project directory (default: autodetect, see below)
#   BACKUP_DIR   where backups are written (default: $HOME/teslamate-backups)
#   TM_WEB_PORT  host port of the TeslaMate web UI (default: 4000)

set -u -o pipefail

TM_DIR=${TM_DIR:-}
BACKUP_DIR=${BACKUP_DIR:-$HOME/teslamate-backups}
TM_WEB_PORT=${TM_WEB_PORT:-4000}

if [ -t 1 ]; then
    BOLD=$'\e[1m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
else
    BOLD=""; RED=""; YELLOW=""; RESET=""
fi

msg()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${YELLOW}$*${RESET}"; }
err()  { printf '%s\n' "${RED}$*${RESET}" >&2; }
die()  { err "$*"; exit 1; }

pause() { read -rp "Press Enter to continue " || true; }

# yes/no prompt, defaults to no
confirm() {
    local answer
    read -rp "$1 [y/N] " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# require the exact word to be typed, used before destructive actions
confirm_typed() {
    local word=$1 answer
    read -rp "Type ${BOLD}${word}${RESET} to proceed: " answer
    [ "$answer" = "$word" ]
}

dc()  { docker compose "$@"; }

# exec calls that take no input get </dev/null - docker compose exec forwards
# and thereby swallows queued terminal input otherwise
sql() { dc exec -T "$DB_SVC" psql -U "$DB_USER" -d "$DB_NAME" -tAX -c "$1" </dev/null; }

# aligned output with headers, for showing rows to the user
sql_show() { dc exec -T "$DB_SVC" psql -U "$DB_USER" -d "$DB_NAME" -X -P pager=off -c "$1" </dev/null; }

env_get() { sed -n "s/^$1=//p" "$TM_DIR/.env" 2>/dev/null | tail -1 | tr -d '\r"'; }

db_running() { dc ps --status running --services 2>/dev/null | grep -qx "$DB_SVC"; }

ensure_db_running() {
    db_running || die "Database service '$DB_SVC' is not running. Start the stack first: docker compose up -d"
}

app_services() { dc config --services | grep -vx "$DB_SVC"; }

newest_position() { sql "SELECT COALESCE(max(date)::text, 'none') FROM positions" 2>/dev/null || echo "unknown"; }

wait_for_web() {
    command -v curl >/dev/null || { warn "curl not found on host, skipping web UI check"; return 0; }
    local i
    for i in $(seq 1 30); do
        if curl -fs -o /dev/null "http://localhost:$TM_WEB_PORT"; then
            msg "TeslaMate web UI is answering on port $TM_WEB_PORT."
            return 0
        fi
        sleep 2
    done
    warn "TeslaMate web UI did not answer on port $TM_WEB_PORT within 60 s - check: docker compose logs teslamate"
    return 1
}

# ---------------------------------------------------------------- environment

find_tm_dir() {
    local d
    for d in "$PWD" "$HOME/teslamate"; do
        if [ -f "$d/docker-compose.yml" ] || [ -f "$d/compose.yaml" ] || [ -f "$d/compose.yml" ]; then
            TM_DIR=$d
            return 0
        fi
    done
    die "No compose file found in current directory or ~/teslamate. Set TM_DIR."
}

setup() {
    docker compose version >/dev/null 2>&1 || die "docker compose (v2) is required and must be runnable by this user."
    [ -n "$TM_DIR" ] || find_tm_dir
    cd "$TM_DIR" || die "Cannot enter $TM_DIR"

    local services
    services=$(dc config --services 2>/dev/null) || die "docker compose config failed in $TM_DIR"

    if echo "$services" | grep -qx database; then
        DB_SVC=database
    elif echo "$services" | grep -qx db; then
        DB_SVC=db
    else
        die "Found neither a 'database' nor a 'db' service in the compose file."
    fi
    echo "$services" | grep -qx teslamate || die "No 'teslamate' service in the compose file."

    DB_USER=$(env_get TM_DB_USER); DB_USER=${DB_USER:-teslamate}
    DB_NAME=$(env_get TM_DB_NAME); DB_NAME=${DB_NAME:-teslamate}

    mkdir -p "$BACKUP_DIR" || die "Cannot create $BACKUP_DIR"

    # refuse to run twice at the same time
    exec 9>"$BACKUP_DIR/.maintenance.lock"
    flock -n 9 || die "Another instance of this script is already running."
}

# -------------------------------------------------------------------- backup

verify_dump() {
    local f=$1
    [ -s "$f" ] || { err "Dump $f is empty."; return 1; }
    head -c 4096 "$f" | grep -q "PostgreSQL database dump" || { err "Dump $f does not look like a pg_dump file."; return 1; }
    tail -n 5 "$f" | grep -q "PostgreSQL database dump complete" || { err "Dump $f is incomplete (no end marker)."; return 1; }
    return 0
}

# creates a verified dump; sets BACKUP_FILE on success
do_backup() {
    ensure_db_running

    local db_size free
    db_size=$(sql "SELECT pg_database_size('$DB_NAME')") || die "Could not read database size."
    free=$(df -B1 --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ')
    msg "Database size: $(numfmt --to=iec "$db_size"), free space in $BACKUP_DIR: $(numfmt --to=iec "$free")"
    if [ "$free" -lt "$db_size" ]; then
        die "Not enough free space for a backup. Free up space or set BACKUP_DIR elsewhere."
    fi

    BACKUP_FILE="$BACKUP_DIR/teslamate-$(date +%Y%m%d-%H%M%S).bck"
    msg "Dumping to $BACKUP_FILE ..."
    if ! dc exec -T "$DB_SVC" pg_dump -U "$DB_USER" "$DB_NAME" </dev/null > "$BACKUP_FILE"; then
        rm -f "$BACKUP_FILE"
        die "pg_dump failed, backup removed."
    fi
    verify_dump "$BACKUP_FILE" || { rm -f "$BACKUP_FILE"; die "Verification failed, backup removed."; }
    msg "Backup OK: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
}

menu_backup() {
    do_backup
    msg ""
    msg "Backups in $BACKUP_DIR:"
    ls -lht "$BACKUP_DIR"/*.bck 2>/dev/null | awk '{print "  " $5 "\t" $9}'
    warn "Copy the backup off this host - a backup on the same machine does not survive a host failure."
}

# ------------------------------------------------------------------- restore

# loads a verified dump into the database, docs recipe; services must be handled by caller
restore_into_db() {
    local f=$1
    msg "Dropping and reinitializing schemas ..."
    dc exec -T "$DB_SVC" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<'SQL' || return 1
DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS private CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION cube WITH SCHEMA public;
CREATE EXTENSION earthdistance WITH SCHEMA public;
SQL
    msg "Loading dump (this can take a few minutes) ..."
    dc exec -T "$DB_SVC" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$f" >/dev/null || return 1
    return 0
}

menu_restore() {
    ensure_db_running

    local files=() f i choice
    while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/*.bck 2>/dev/null)

    if [ "${#files[@]}" -gt 0 ]; then
        msg "Backups in $BACKUP_DIR (newest first):"
        for i in "${!files[@]}"; do
            printf '  %2d) %s  (%s, %s)\n' "$((i+1))" "$(basename "${files[$i]}")" \
                "$(du -h "${files[$i]}" | cut -f1)" "$(date -r "${files[$i]}" '+%Y-%m-%d %H:%M')"
        done
    else
        msg "No backups found in $BACKUP_DIR."
    fi
    read -rp "Number to restore, or full path to a dump file (empty to abort): " choice
    [ -n "$choice" ] || return 0

    if [[ $choice =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
        f=${files[$((choice-1))]}
    else
        f=$choice
    fi
    [ -f "$f" ] || { err "No such file: $f"; return 1; }
    verify_dump "$f" || return 1

    msg ""
    msg "About to restore: ${BOLD}$f${RESET}"
    msg "  dump file dated: $(date -r "$f" '+%Y-%m-%d %H:%M')"
    msg "  current database: newest position $(newest_position), $(sql "SELECT count(*) FROM drives") drives, $(sql "SELECT count(*) FROM charging_processes") charges"
    warn "This REPLACES everything recorded after the dump was taken."
    confirm_typed RESTORE || { msg "Aborted."; return 0; }

    msg ""
    msg "Taking a safety backup of the current database first ..."
    do_backup
    local safety=$BACKUP_FILE

    local apps
    apps=$(app_services)
    msg "Stopping application services: $(echo "$apps" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    dc stop $apps || { err "Could not stop services."; return 1; }
    sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME' AND pid <> pg_backend_pid()" >/dev/null

    if ! restore_into_db "$f"; then
        err "RESTORE FAILED. Application services are left stopped."
        err "The database may be incomplete. A safety backup of the pre-restore state is at:"
        err "  $safety"
        err "Restore it with this script once the cause is fixed, then: docker compose up -d"
        exit 1
    fi

    msg "Starting application services ..."
    # shellcheck disable=SC2086
    dc start $apps
    wait_for_web || true
    msg "Restore done. Newest position now: $(newest_position)"
    msg "Safety backup of the replaced state: $safety"
}

# ------------------------------------------------- close/delete drives/charges

# args: table, label, id -> prints the row, returns 1 if it does not exist
show_row() {
    local table=$1 label=$2 id=$3
    local exists
    exists=$(sql "SELECT count(*) FROM $table WHERE id = $id")
    if [ "$exists" != "1" ]; then
        err "No $label with id $id."
        return 1
    fi
    sql_show "SELECT * FROM $table WHERE id = $id"
}

read_id() {
    local id
    read -rp "$1 (empty to abort): " id
    [ -n "$id" ] || return 1
    [[ $id =~ ^[0-9]+$ ]] || { err "Not a numeric id."; return 1; }
    printf '%s' "$id"
}

menu_close() {
    local kind=$1 table module fn label
    if [ "$kind" = drive ]; then
        table=drives; module=Drive; fn=close_drive; label=drive
    else
        table=charging_processes; module=ChargingProcess; fn=complete_charging_process; label=charge
    fi
    ensure_db_running
    dc ps --status running --services | grep -qx teslamate || die "The teslamate service must be running for this."

    msg "Unfinished ${label}s (no end date):"
    sql_show "SELECT id, car_id, start_date FROM $table WHERE end_date IS NULL ORDER BY start_date DESC LIMIT 20"

    local id
    id=$(read_id "Id of the $label to close") || return 0
    show_row "$table" "$label" "$id" || return 1

    local end_date
    end_date=$(sql "SELECT COALESCE(end_date::text, '') FROM $table WHERE id = $id")
    if [ -n "$end_date" ]; then
        err "This $label already has an end date ($end_date) - closing is only for unfinished ones."
        return 1
    fi

    confirm "Close $label $id?" || { msg "Aborted."; return 0; }
    dc exec -T teslamate bin/teslamate rpc \
        "TeslaMate.Repo.get!(TeslaMate.Log.$module, $id) |> TeslaMate.Log.$fn()" </dev/null || {
        err "rpc call failed."; return 1; }
    msg "Done. The $label is now:"
    show_row "$table" "$label" "$id" 2>/dev/null \
        || msg "(gone - TeslaMate removes a $label that has no recorded data when closing it)"
}

menu_delete() {
    local kind=$1 table label
    if [ "$kind" = drive ]; then table=drives; label=drive; else table=charging_processes; label=charge; fi
    ensure_db_running

    local id
    id=$(read_id "Id of the $label to DELETE") || return 0
    show_row "$table" "$label" "$id" || return 1

    warn "Deleting a $label cannot be undone without a backup."
    confirm_typed "DELETE $id" || { msg "Aborted."; return 0; }
    if confirm "Take a backup first? (recommended)"; then
        do_backup
    fi

    dc exec -T "$DB_SVC" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" \
        -c "DELETE FROM $table WHERE id = $id" </dev/null >/dev/null || { err "Delete failed."; return 1; }
    msg "Deleted $label $id."
}

# ------------------------------------------------------------- remove vehicle

menu_remove_vehicle() {
    ensure_db_running
    msg "Cars in the database:"
    sql_show "SELECT id, name, vin FROM cars ORDER BY id"

    local id
    id=$(read_id "Id of the car to REMOVE, with all its data") || return 0
    local vin
    vin=$(sql "SELECT COALESCE(vin,'') FROM cars WHERE id = $id")
    [ -n "$vin" ] || { err "No car with id $id (or it has no VIN)."; return 1; }

    warn "This removes the car AND all its drives, charges, positions, states and updates."
    msg "Confirm by typing the car's VIN."
    confirm_typed "$vin" || { msg "Aborted."; return 0; }
    msg "A backup is mandatory for this operation."
    do_backup

    dc exec -T "$DB_SVC" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" <<SQL || { err "Removal failed, transaction rolled back."; return 1; }
BEGIN;
DELETE FROM cars WHERE id = $id;
DELETE FROM car_settings WHERE id = $id;
DELETE FROM charges WHERE charging_process_id IN (SELECT id FROM charging_processes WHERE car_id = $id);
DELETE FROM charging_processes WHERE car_id = $id;
DELETE FROM drives WHERE car_id = $id;
DELETE FROM positions WHERE car_id = $id;
DELETE FROM states WHERE car_id = $id;
DELETE FROM updates WHERE car_id = $id;
COMMIT;
SQL
    msg "Car $id removed. Restart the stack so TeslaMate picks up the change: docker compose restart teslamate"
}

# ------------------------------------------------------------------- reindex

menu_reindex() {
    ensure_db_running
    msg "Reindexing rebuilds all indexes. Only useful after large amounts of updates or"
    msg "deletions (data imports, removed vehicles). It locks tables while running."
    confirm "Run REINDEX DATABASE $DB_NAME now?" || { msg "Aborted."; return 0; }
    local before after start
    before=$(sql "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))")
    start=$(date +%s)
    dc exec -T "$DB_SVC" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "REINDEX DATABASE $DB_NAME" \
        </dev/null || { err "Reindex failed."; return 1; }
    after=$(sql "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))")
    msg "Reindex done in $(( $(date +%s) - start )) s. Database size $before -> $after."
}

# ---------------------------------------------------------------- pg upgrade

menu_pg_upgrade() {
    ensure_db_running

    local running_major compose_image compose_major
    running_major=$(sql "SHOW server_version" | cut -d. -f1 | tr -d ' ')
    compose_image=$(dc config --images | grep -E '(^|/)postgres:' | head -1)
    compose_major=$(echo "$compose_image" | sed 's/.*postgres://' | grep -o '^[0-9]*')
    msg "Running PostgreSQL major version: $running_major"
    msg "Compose file image:               $compose_image (major $compose_major)"

    if [ -z "$compose_major" ]; then
        die "Could not read a postgres version from the compose file."
    fi
    if [ "$running_major" = "$compose_major" ]; then
        msg ""
        msg "Nothing to do - the compose file matches the running version."
        msg "To upgrade: edit the postgres image tag in docker-compose.yml first, then rerun this."
        return 0
    fi

    local vols vol project real_vol
    vols=$(dc config --volumes | grep -i db || true)
    if [ "$(echo "$vols" | grep -c .)" != "1" ]; then
        err "Expected exactly one compose volume matching 'db', found:"
        err "${vols:-  (none - the database may use a bind mount)}"
        err "This upgrade path only supports the standard named volume - do it manually per the docs."
        return 1
    fi
    vol=$vols
    project=${COMPOSE_PROJECT_NAME:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')}
    real_vol="${project}_${vol}"
    docker volume inspect "$real_vol" >/dev/null 2>&1 || { err "Volume $real_vol not found."; return 1; }

    msg ""
    warn "This upgrades PostgreSQL $running_major -> $compose_major by DELETING volume $real_vol"
    warn "and restoring from a fresh backup. The whole stack will be down meanwhile."
    if [ "$compose_major" -ge 18 ] && [ "$running_major" -lt 18 ]; then
        warn "postgres 18 changed the data path: the volume must be mounted at"
        warn "/var/lib/postgresql (not .../data) in docker-compose.yml. Verify before continuing."
    fi
    confirm_typed UPGRADE || { msg "Aborted."; return 0; }

    msg "Taking the pre-upgrade backup ..."
    do_backup
    local dump=$BACKUP_FILE

    msg "Stopping the stack ..."
    dc down || { err "docker compose down failed."; return 1; }
    docker volume rm "$real_vol" || { err "Could not remove $real_vol. Stack is down; investigate, then docker compose up -d."; exit 1; }

    msg "Starting the new database ..."
    dc up -d "$DB_SVC" || { err "Could not start $DB_SVC. Dump is at $dump."; exit 1; }
    local i ready=0
    for i in $(seq 1 60); do
        if dc exec -T "$DB_SVC" pg_isready -U "$DB_USER" -d "$DB_NAME" </dev/null >/dev/null 2>&1 \
           && sql "SELECT 1" >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 2
    done
    [ "$ready" = 1 ] || { err "New database did not become ready. Dump is at $dump."; exit 1; }
    sleep 3   # let the entrypoint finish its init restart before loading

    if ! restore_into_db "$dump"; then
        err "RESTORE INTO THE NEW DATABASE FAILED. The stack is down except the database."
        err "Your data is safe in the dump: $dump"
        err "Fix the cause and restore with this script, or follow the docs manually."
        exit 1
    fi

    msg "Starting the full stack ..."
    dc up -d
    wait_for_web || true
    msg "PostgreSQL upgrade done. Now running: $(sql "SHOW server_version"). Pre-upgrade dump: $dump"
}

# -------------------------------------------------------------------- status

menu_status() {
    msg "${BOLD}Compose project:${RESET} $TM_DIR (db service: $DB_SVC, db: $DB_NAME, user: $DB_USER)"
    msg ""
    dc ps
    msg ""
    if db_running; then
        msg "PostgreSQL:      $(sql "SELECT version()" | cut -d, -f1)"
        msg "Database size:   $(sql "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))")"
        msg "Newest position: $(newest_position)"
        msg "Open drives:     $(sql "SELECT count(*) FROM drives WHERE end_date IS NULL")"
        msg "Open charges:    $(sql "SELECT count(*) FROM charging_processes WHERE end_date IS NULL")"
    else
        warn "Database service is not running."
    fi
    local latest
    latest=$(ls -1t "$BACKUP_DIR"/*.bck 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        msg "Latest backup:   $latest ($(date -r "$latest" '+%Y-%m-%d %H:%M'))"
    else
        warn "No backups in $BACKUP_DIR yet."
    fi
}

# ---------------------------------------------------------------------- menu

main_menu() {
    while true; do
        msg ""
        msg "${BOLD}TeslaMate maintenance${RESET} - $TM_DIR"
        msg "  1) Stack status"
        msg "  2) Backup database"
        msg "  3) Restore database from backup"
        msg "  4) Close an unfinished drive"
        msg "  5) Close an unfinished charge"
        msg "  6) Delete a drive"
        msg "  7) Delete a charge"
        msg "  8) Remove a vehicle and all its data"
        msg "  9) Reindex database"
        msg " 10) Upgrade PostgreSQL (major version)"
        msg "  q) Quit"
        local choice
        read -rp "> " choice || exit 0
        case $choice in
            1)  menu_status ;;
            2)  menu_backup ;;
            3)  menu_restore ;;
            4)  menu_close drive ;;
            5)  menu_close charge ;;
            6)  menu_delete drive ;;
            7)  menu_delete charge ;;
            8)  menu_remove_vehicle ;;
            9)  menu_reindex ;;
            10) menu_pg_upgrade ;;
            q|Q) exit 0 ;;
            *)  warn "No such choice." ; continue ;;
        esac
        pause
    done
}

setup
case ${1:-} in
    "")      [ -t 0 ] || die "No terminal. For unattended use, run: $0 backup"
             main_menu ;;
    backup)  do_backup
             msg "Remember to copy the backup off this host." ;;
    status)  menu_status ;;
    *)       die "Usage: $0 [backup|status]  (no argument starts the menu)" ;;
esac
