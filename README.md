# ansiblecolldb

A PostgreSQL container that knows every collection in the community `ansible`
package, which version of each collection shipped in every ansible release,
which ansible-core each release pins, and which ansible-core versions every
Galaxy release of those collections supports (`requires_ansible`).

Nothing is hard-coded. On first boot (and optionally on a schedule), the
container discovers everything from:

| Source | What it provides |
|---|---|
| [ansible-community/ansible-build-data](https://github.com/ansible-community/ansible-build-data) | every `ansible-X.Y.Z.deps`: bundled collection versions + pinned engine; `collection-meta.yaml`: repo, maintainers, removal schedule |
| PyPI (`ansible`, `ansible-core`, `ansible-base`) | release dates, python requirements, yanked flags; classic `ansible` <= 2.9 as engine releases |
| Galaxy v3 API | every published version of every collection, with `requires_ansible`, description, tags, license, download count, deprecation |

## Run

```sh
docker compose up -d --build        # first boot fetches data (~1-2 min)
docker compose ps                   # "healthy" once data is loaded
docker exec -it ansibledb psql -U ansible                       # search_path is preset
docker exec -it ansibledb psql -U ansible -f /opt/ansibledb/examples.sql   # guided tour
docker exec ansibledb ansibledb-refresh                         # re-fetch now
```

| Env var | Default | |
|---|---|---|
| `REFRESH_INTERVAL_HOURS` | `0` (compose: `24`) | background re-fetch interval (whole hours), 0 disables |
| `SKIP_INITIAL_LOAD` | `false` | create the schema only |
| `BUILD_DATA_REF` | `main` | git ref of ansible-build-data |
| `FETCH_WORKERS` | `8` | parallel Galaxy requests |
| `GALAXY_URL` | `https://galaxy.ansible.com` | point at a Galaxy-compatible hub |

A refresh is atomic: `CALL ansible.ingest(jsonb)` swaps the whole dataset in
one transaction, so readers never see a half-loaded state. The `environment`
table you register yourself survives refreshes.

## Inputs are forgiving

Every function that takes an ansible or core version runs it through
`resolve_ansible()` / `resolve_core()`, which accept:
`'latest'`, an exact version `'11.4.0'`, a line `'11'` / `'2.10'` / `'2.18'`
(newest GA in it), or a specifier `'>=10,<12'`.

## Query functions

| Function | Answers |
|---|---|
| `collections_for_ansible('12')` | what ships in an ansible release (plus a check that the bundled core satisfies each collection) |
| `ansible_for_collection('community.general', '==9.*')` | which ansible releases ship a collection (version spec optional) |
| `collections_for_core('2.16')` | newest Galaxy version of every collection that supports a given ansible-core |
| `core_for_collection('amazon.aws', '7.0.0')` | which core series a collection version supports |
| `ansible_for_core('2.18')` | which ansible releases bundle a core version/series |
| `collection_support_matrix('ansible.windows')` | newest version per collection major and its supported core series |
| `collection_timeline('community.docker')` | version range of a collection per ansible line |
| `ansible_diff('10', '12')` | added / removed / major / minor / patch / downgrade per collection |
| `upgrade_report('9', 'latest')` | JSON briefing: core & python change, counts, removed/added, major bumps, upcoming removals |
| `find_ansible('{"community.general": ">=10", "kubernetes.core": ">=5"}', '<2.19')` | which ansible releases satisfy *all* your collection constraints (optionally on a core spec) |
| `requirements_yml('11', ARRAY['ansible.posix'])` | a pinned `requirements.yml` straight from a release |
| `search_collections('kubernetes')` | ranked search over name, tags, description |

Building blocks: `ver_key(text)` (PEP 440/semver aware sort key),
`version_satisfies(version, spec)` (`>= <= > < == != ~=` and `.*`), `ver_bump(old, new)`.

## Views

| View | |
|---|---|
| `v_ansible_release` | every ansible release with its core, python, collection count, latest flags |
| `v_ansible_line_summary` | per ansible line: GA date, core, and how much changed vs. the previous line |
| `v_core_series` | engine series 2.9+ with the ansible lines that bundle them |
| `v_release_content` | release x collection with `requires_ansible` cross-check |
| `v_release_diff` | collection changes between every pair of consecutive GA releases |
| `v_collection_version` | every Galaxy version with `supported_core_series[]` and the ansible releases shipping it |
| `v_collection_latest` | newest GA version per collection, its support range, downloads |
| `v_collection_lifecycle` | first/last ansible release per collection, status: active / scheduled for removal / renamed / removed |
| `v_collection_matrix` | collection -> `{line: version}` JSON across all ansible lines |
| `v_collection_cadence` | release counts and average gap between releases |
| `v_bundle_conflicts` | releases that bundled a collection whose `requires_ansible` excludes the bundled core |
| `mv_spec_series_compat` | materialized: each distinct `requires_ansible` spec -> supported core series |

## Environments and drift

```sql
CALL register_environment('prod', '10', '{"community.general": "10.1.0"}', 'main fleet');
SELECT * FROM v_environment_summary;          -- how far behind each environment is
SELECT * FROM v_environment_drift WHERE environment = 'prod' AND behind_by = 'major';
CALL drop_environment('prod');
```

`pinned` lists collections you install on top of the ansible release.
`best_for_core` is the newest Galaxy version that still supports the environment's engine.

## Layout

```
Dockerfile, docker-compose.yml
docker/entrypoint.sh      wraps the postgres entrypoint and runs the optional refresh loop
initdb/01-schema.sql      tables and version helpers
initdb/02-logic.sql       ingest procedure, views, functions, environments
initdb/03-load.sh         first-boot load
loader/fetch.py           discovers and fetches all sources and emits one JSON document
bin/ansibledb-refresh     fetch + CALL ansible.ingest()
examples.sql              guided tour
```
