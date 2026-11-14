FROM postgres:17-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-yaml ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV POSTGRES_DB=ansible \
    REFRESH_INTERVAL_HOURS=0 \
    BUILD_DATA_REF=main \
    FETCH_WORKERS=8

COPY loader/fetch.py            /opt/ansibledb/fetch.py
COPY bin/ansibledb-refresh      /usr/local/bin/ansibledb-refresh
COPY docker/entrypoint.sh       /usr/local/bin/ansibledb-entrypoint.sh
COPY initdb/                    /docker-entrypoint-initdb.d/
COPY examples.sql               /opt/ansibledb/examples.sql

HEALTHCHECK --interval=10s --timeout=5s --start-period=10m --retries=5 \
  CMD pg_isready -q -U "${POSTGRES_USER:-postgres}" -d "$POSTGRES_DB" && \
      psql -XtAq -U "${POSTGRES_USER:-postgres}" -d "$POSTGRES_DB" -c 'SELECT 1 FROM ansible.load_run LIMIT 1' | grep -q 1

ENTRYPOINT ["ansibledb-entrypoint.sh"]
CMD ["postgres"]
