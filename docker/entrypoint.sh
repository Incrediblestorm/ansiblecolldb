#!/bin/bash
# Wraps the stock postgres entrypoint and, if REFRESH_INTERVAL_HOURS is set,
# keeps the data current in the background.
set -e
if [ -n "${REFRESH_INTERVAL_HOURS:-}" ] && [ "${REFRESH_INTERVAL_HOURS}" != "0" ]; then
  run_as_pg=""
  [ "$(id -u)" = "0" ] && run_as_pg="gosu postgres"
  (
    interval=$(( REFRESH_INTERVAL_HOURS * 3600 ))
    while sleep "$interval"; do
      until pg_isready -q; do sleep 5; done
      $run_as_pg /usr/local/bin/ansibledb-refresh 2>&1 | sed 's/^/[auto-refresh] /' || true
    done
  ) &
fi
exec docker-entrypoint.sh "$@"
