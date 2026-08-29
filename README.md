# teslamate-maintenance

Interactive maintenance menu for a [TeslaMate](https://github.com/teslamate-org/teslamate)
installation running on docker compose. It wraps the
[maintenance chapter](https://docs.teslamate.org/docs/maintenance/backup) of the
TeslaMate docs in a single script with built-in checks and confirmations.

```
TeslaMate maintenance - /home/user/teslamate
  1) Stack status
  2) Backup database
  3) Restore database from backup
  4) Close an unfinished drive
  5) Close an unfinished charge
  6) Delete a drive
  7) Delete a charge
  8) Remove a vehicle and all its data
  9) Reindex database
 10) Upgrade PostgreSQL (major version)
  q) Quit
```

## Safety checks

- Every dump is verified (pg_dump start and end markers) before it is trusted,
  both when created and before a restore.
- Restore, vehicle removal and PostgreSQL upgrades take a verified backup of the
  current database first, automatically.
- Destructive actions require a typed confirmation: `RESTORE`, `DELETE <id>`,
  the car's VIN, or `UPGRADE`.
- Free disk space is checked against the database size before every backup.
- Closing a drive or charge is refused if it already has an end date.
- The PostgreSQL upgrade refuses to run until the image tag in
  docker-compose.yml has been changed, and aborts if the database does not use
  the standard named volume.
- A lock file prevents two instances from running at the same time.

## Install

```bash
curl -fLo ~/teslamate-maintenance.sh https://raw.githubusercontent.com/mews-se/teslamate-maintenance/main/teslamate-maintenance.sh
chmod +x ~/teslamate-maintenance.sh
```

## Usage

```bash
./teslamate-maintenance.sh          # interactive menu
./teslamate-maintenance.sh backup   # unattended backup, for cron
./teslamate-maintenance.sh status   # stack and database overview
```

Backups are written to `~/teslamate-backups` as `teslamate-YYYYMMDD-HHMMSS.bck`.
Copy them off the host - a backup on the same machine does not survive a host
failure.

## Configuration

Everything is optional and set via environment variables:

| Variable      | Default                          | Purpose                          |
| ------------- | -------------------------------- | -------------------------------- |
| `TM_DIR`      | `$PWD`, then `~/teslamate`       | compose project directory        |
| `BACKUP_DIR`  | `~/teslamate-backups`            | where backups are written        |
| `TM_WEB_PORT` | `4000`                           | host port of the TeslaMate web UI |

`TM_DB_USER` and `TM_DB_NAME` are read from the `.env` file of the compose
project, falling back to `teslamate`.

## Requirements

- Docker Compose v2 (`docker compose`, not `docker-compose`)
- A compose file with a `teslamate` service and a `database` (or `db`) service
- Run as a user that can talk to the Docker daemon

## License

[MIT](LICENSE)

## Disclaimer

This project is an unofficial community tool and is not affiliated with, endorsed by, or
supported by the official TeslaMate project.
