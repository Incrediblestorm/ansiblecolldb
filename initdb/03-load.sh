#!/bin/bash
# First boot: populate the database. A failed fetch leaves an empty (but
# usable) schema; run `ansibledb-refresh` later to retry.
if [ "${SKIP_INITIAL_LOAD:-false}" = "true" ]; then
  echo "[initdb] SKIP_INITIAL_LOAD=true, not fetching data"
  exit 0
fi
/usr/local/bin/ansibledb-refresh || echo "[initdb] WARNING: initial load failed; run ansibledb-refresh to retry" >&2
