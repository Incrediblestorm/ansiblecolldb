-- ansiblecolldb: ingestion procedure, views and query functions

\set ON_ERROR_STOP on
SET search_path = ansible, public;

------------------------------------------------------------------------------
-- Resolvers: turn loose user input into a concrete version
------------------------------------------------------------------------------

-- Accepts: 'latest' / NULL, an exact version ('12.3.0'), a line ('12', '2.10'),
-- or a specifier ('>=10,<12'). Returns the newest *published GA* match,
-- falling back to prereleases/unpublished builds only when nothing else matches.
CREATE OR REPLACE FUNCTION resolve_ansible(p text DEFAULT 'latest')
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT version FROM (
    SELECT version, ver_key, is_prerelease, released_at,
           0 AS prio
      FROM ansible_release WHERE version = p
    UNION ALL
    SELECT version, ver_key, is_prerelease, released_at, 1
      FROM ansible_release
     WHERE p IS NULL OR lower(p) = 'latest' OR line = p
        OR (p ~ '^[<>=!~]' AND version_satisfies(version, p))
  ) c
  ORDER BY prio, (is_prerelease OR released_at IS NULL), ver_key DESC
  LIMIT 1
$$;

-- Same idea for the engine: 'latest', '2.19.5', '2.19' (series), '>=2.16,<2.18'.
CREATE OR REPLACE FUNCTION resolve_core(p text DEFAULT 'latest')
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT version FROM (
    SELECT version, ver_key, is_prerelease, yanked, 0 AS prio
      FROM core_release WHERE version = p
    UNION ALL
    SELECT version, ver_key, is_prerelease, yanked, 1
      FROM core_release
     WHERE p IS NULL OR lower(p) = 'latest' OR series = p
        OR (p ~ '^[<>=!~]' AND version_satisfies(version, p))
  ) c
  ORDER BY prio, (is_prerelease OR yanked), ver_key DESC
  LIMIT 1
$$;

------------------------------------------------------------------------------
-- Derived data
------------------------------------------------------------------------------

-- The engine series that matter for collections (2.9+), represented by the
-- newest GA patch of each series ("an up-to-date 2.17").
CREATE OR REPLACE VIEW v_core_series AS
SELECT g.series,
       lt.product,
       g.first_version,
       g.first_released,
       lt.version     AS latest_version,
       lt.released_at AS latest_released,
       g.n_releases,
       (SELECT array_agg(DISTINCT ar.line ORDER BY ar.line)
          FROM ansible_release ar
         WHERE ver_series(ar.core_version) = g.series) AS bundled_in_ansible_lines,
       lt.ver_key     AS latest_ver_key
  FROM (
    SELECT series,
           (array_agg(version ORDER BY ver_key))[1] AS first_version,
           min(released_at)                         AS first_released,
           count(*)                                 AS n_releases
      FROM core_release
     GROUP BY series
  ) g
  CROSS JOIN LATERAL (
    SELECT cr.version, cr.product, cr.released_at, cr.ver_key
      FROM core_release cr
     WHERE cr.series = g.series AND NOT cr.is_prerelease AND NOT cr.yanked
     ORDER BY cr.ver_key DESC
     LIMIT 1
  ) lt
 WHERE lt.ver_key >= ver_key('2.9');

-- Precomputed: for each distinct requires_ansible specifier, which engine
-- series (at their latest GA patch) satisfy it. Small and fast to join.
CREATE MATERIALIZED VIEW mv_spec_series_compat AS
SELECT sp.spec, cs.series, cs.latest_version AS core_version, cs.latest_ver_key AS core_ver_key
  FROM (SELECT DISTINCT coalesce(requires_ansible, '') AS spec FROM collection_version) sp
 CROSS JOIN v_core_series cs
 WHERE version_satisfies(cs.latest_version, sp.spec);
CREATE UNIQUE INDEX mv_spec_series_compat_pk ON mv_spec_series_compat (spec, series);

CREATE OR REPLACE PROCEDURE refresh_derived()
LANGUAGE plpgsql AS $$
BEGIN
  REFRESH MATERIALIZED VIEW mv_spec_series_compat;
  ANALYZE core_release, core_python, core_platform, ansible_release, collection, collection_version, release_content;
END $$;

------------------------------------------------------------------------------
-- Ingestion: the Python fetcher hands over one JSON document; this procedure
-- swaps the dataset atomically (readers keep seeing the old data until commit).
------------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE ingest(payload jsonb)
LANGUAGE plpgsql AS $$
DECLARE
  t0 timestamptz := clock_timestamp();
BEGIN
  DELETE FROM release_content;
  DELETE FROM collection_version;
  DELETE FROM collection;
  DELETE FROM ansible_release;
  DELETE FROM core_release;
  DELETE FROM core_python;
  DELETE FROM core_platform;

  INSERT INTO core_python (series, python, ver_key, controller, target)
  SELECT s->>'series', p->>'version', ver_key(p->>'version'),
         coalesce((p->>'controller')::boolean, false), coalesce((p->>'target')::boolean, true)
    FROM jsonb_array_elements(coalesce(payload->'core_support', '[]')) s,
         jsonb_array_elements(s->'python') p
   WHERE ver_key(p->>'version') IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO core_platform (series, kind, os, os_version, ver_key, python)
  SELECT s->>'series', p->>'kind', lower(p->>'os'), p->>'version', ver_key(p->>'version'),
         coalesce(ARRAY(SELECT jsonb_array_elements_text(p->'python')), '{}')
    FROM jsonb_array_elements(coalesce(payload->'core_support', '[]')) s,
         jsonb_array_elements(s->'platforms') p
  ON CONFLICT DO NOTHING;

  INSERT INTO core_release (version, product, ver_key, series, is_prerelease, released_at, requires_python, yanked)
  SELECT r->>'version', r->>'product', ver_key(r->>'version'), ver_series(r->>'version'),
         is_prerelease(r->>'version'), (r->>'released_at')::timestamptz,
         r->>'requires_python', coalesce((r->>'yanked')::boolean, false)
    FROM jsonb_array_elements(payload->'core_releases') r
   WHERE ver_key(r->>'version') IS NOT NULL
  ON CONFLICT (version) DO NOTHING;

  INSERT INTO ansible_release (version, line, ver_key, is_prerelease, released_at, core_version, core_product, requires_python)
  SELECT r->>'version',
         CASE WHEN (ver_key(r->>'version'))[1] = 2 THEN ver_series(r->>'version') ELSE ver_series(r->>'version', 1) END,
         ver_key(r->>'version'), is_prerelease(r->>'version'), (r->>'released_at')::timestamptz,
         r->>'core_version', r->>'core_product', r->>'requires_python'
    FROM jsonb_array_elements(payload->'ansible_releases') r;

  INSERT INTO collection (fqcn, namespace, name, repository, maintainers, description, license, tags,
                          dependencies, galaxy_deprecated, download_count, galaxy_found, removal)
  SELECT c->>'fqcn', split_part(c->>'fqcn', '.', 1), split_part(c->>'fqcn', '.', 2),
         c->>'repository',
         coalesce(ARRAY(SELECT jsonb_array_elements_text(c->'maintainers')), '{}'),
         c->>'description',
         coalesce(ARRAY(SELECT jsonb_array_elements_text(c->'license')), '{}'),
         coalesce(ARRAY(SELECT jsonb_array_elements_text(c->'tags')), '{}'),
         coalesce(c->'dependencies', '{}'),
         (c->>'deprecated')::boolean, (c->>'download_count')::bigint,
         coalesce((c->>'galaxy_found')::boolean, false),
         nullif(c->'removal', 'null'::jsonb)
    FROM jsonb_array_elements(payload->'collections') c;

  INSERT INTO collection_version (fqcn, version, ver_key, is_prerelease, requires_ansible, released_at, marks)
  SELECT c->>'fqcn', v->>'version', ver_key(v->>'version'), is_prerelease(v->>'version'),
         nullif(btrim(v->>'requires_ansible'), ''), (v->>'released_at')::timestamptz,
         coalesce(ARRAY(SELECT jsonb_array_elements_text(v->'marks')), '{}')
    FROM jsonb_array_elements(payload->'collections') c,
         jsonb_array_elements(c->'versions') v
  ON CONFLICT DO NOTHING;

  INSERT INTO release_content (ansible_version, fqcn, collection_version)
  SELECT r->>'version', kv.key, kv.value
    FROM jsonb_array_elements(payload->'ansible_releases') r,
         jsonb_each_text(r->'collections') kv;

  CALL refresh_derived();

  INSERT INTO load_run (duration, source, stats)
  VALUES (clock_timestamp() - t0, payload->'source', jsonb_build_object(
    'core_releases',       (SELECT count(*) FROM core_release),
    'core_support_series', (SELECT count(DISTINCT series) FROM core_python),
    'core_platforms',      (SELECT count(*) FROM core_platform),
    'ansible_releases',    (SELECT count(*) FROM ansible_release),
    'collections',         (SELECT count(*) FROM collection),
    'collection_versions', (SELECT count(*) FROM collection_version),
    'release_content',     (SELECT count(*) FROM release_content)));
END $$;

------------------------------------------------------------------------------
-- Views
------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_ansible_release AS
SELECT ar.version,
       ar.line,
       ar.is_prerelease,
       ar.released_at IS NOT NULL                                AS published,
       ar.released_at,
       ar.core_product,
       ar.core_version,
       ver_series(ar.core_version)                               AS core_series,
       ar.requires_python,
       (SELECT count(*) FROM release_content rc WHERE rc.ansible_version = ar.version) AS n_collections,
       ar.version = resolve_ansible(ar.line)                     AS is_latest_in_line,
       ar.version = resolve_ansible('latest')                    AS is_latest,
       ar.ver_key
  FROM ansible_release ar;

-- Release contents, cross-checked against each collection's own requires_ansible.
CREATE OR REPLACE VIEW v_release_content AS
SELECT rc.ansible_version,
       ar.line,
       ar.released_at                                         AS ansible_released_at,
       rc.fqcn,
       rc.collection_version,
       cv.requires_ansible,
       cv.released_at                                         AS collection_released_at,
       ar.core_version,
       version_satisfies(ar.core_version, cv.requires_ansible) AS bundled_core_satisfies,
       ar.ver_key                                             AS ansible_ver_key
  FROM release_content rc
  JOIN ansible_release ar ON ar.version = rc.ansible_version
  LEFT JOIN collection_version cv ON cv.fqcn = rc.fqcn AND cv.version = rc.collection_version;

-- Fun sanity check: releases that bundle a collection whose declared
-- requires_ansible is NOT met by the bundled engine.
CREATE OR REPLACE VIEW v_bundle_conflicts AS
SELECT ansible_version, core_version, fqcn, collection_version, requires_ansible
  FROM v_release_content
 WHERE bundled_core_satisfies IS FALSE
 ORDER BY ansible_ver_key DESC, fqcn;

-- Every Galaxy version of every collection with the engine series it supports.
CREATE OR REPLACE VIEW v_collection_version AS
SELECT cv.fqcn,
       cv.version,
       cv.is_prerelease,
       cv.released_at,
       cv.requires_ansible,
       compat.series                    AS supported_core_series,
       compat.series[1]                 AS min_core_series,
       compat.series[array_length(compat.series, 1)] AS max_core_series,
       (SELECT array_agg(rc.ansible_version ORDER BY ar.ver_key)
          FROM release_content rc JOIN ansible_release ar ON ar.version = rc.ansible_version
         WHERE rc.fqcn = cv.fqcn AND rc.collection_version = cv.version) AS shipped_in_ansible,
       cv.marks,
       cv.ver_key
  FROM collection_version cv
  LEFT JOIN LATERAL (
    SELECT array_agg(m.series ORDER BY m.core_ver_key) AS series
      FROM mv_spec_series_compat m
     WHERE m.spec = coalesce(cv.requires_ansible, '')
  ) compat ON true;

-- The newest GA version of each collection on Galaxy.
CREATE OR REPLACE VIEW v_collection_latest AS
SELECT DISTINCT ON (c.fqcn)
       c.fqcn,
       cv.version                AS latest_version,
       cv.released_at,
       (now()::date - cv.released_at::date) AS days_since_release,
       cv.requires_ansible,
       cv.min_core_series,
       cv.supported_core_series,
       c.download_count,
       c.galaxy_deprecated,
       c.description
  FROM collection c
  LEFT JOIN v_collection_version cv ON cv.fqcn = c.fqcn AND NOT cv.is_prerelease
 ORDER BY c.fqcn, cv.ver_key DESC NULLS LAST;

-- When did each collection join / leave the package, and what is its future?
CREATE OR REPLACE VIEW v_collection_lifecycle AS
WITH latest AS (SELECT resolve_ansible('latest') AS v),
span AS (
  SELECT rc.fqcn,
         (array_agg(ar.version ORDER BY ar.ver_key))[1]      AS first_ansible,
         (array_agg(ar.version ORDER BY ar.ver_key DESC))[1] AS last_ansible,
         min(ar.released_at)                                 AS first_shipped_at,
         count(*)                                            AS n_ansible_releases,
         count(DISTINCT rc.collection_version)               AS n_versions_shipped,
         bool_or(ar.version = (SELECT v FROM latest))        AS in_latest
    FROM release_content rc
    JOIN ansible_release ar ON ar.version = rc.ansible_version
   GROUP BY rc.fqcn
)
SELECT c.fqcn,
       span.first_ansible,
       span.last_ansible,
       span.first_shipped_at,
       span.n_ansible_releases,
       span.n_versions_shipped,
       span.in_latest,
       CASE
         WHEN NOT span.in_latest THEN 'removed'
         WHEN c.removal->>'reason' = 'renamed'
           THEN format('renamed to %s (old name removed in %s)', c.removal->>'new_name', c.removal->>'major_version')
         WHEN c.removal ? 'major_version'
           THEN format('scheduled for removal in %s (%s)', c.removal->>'major_version', coalesce(c.removal->>'reason', '?'))
         WHEN c.galaxy_deprecated THEN 'deprecated on galaxy'
         ELSE 'active'
       END AS status,
       c.removal,
       c.repository
  FROM collection c
  JOIN span ON span.fqcn = c.fqcn;

-- Collection x ansible line: version shipped in the newest GA of each line.
CREATE OR REPLACE VIEW v_collection_matrix AS
WITH line_latest AS (
  SELECT DISTINCT ON (line) line, version, ver_key
    FROM ansible_release
   ORDER BY line, (is_prerelease OR released_at IS NULL), ver_key DESC
)
SELECT rc.fqcn,
       jsonb_object_agg(ll.line, rc.collection_version ORDER BY ll.ver_key) AS by_line
  FROM line_latest ll
  JOIN release_content rc ON rc.ansible_version = ll.version
 GROUP BY rc.fqcn;

-- Changes between consecutive published GA releases.
CREATE OR REPLACE VIEW v_release_diff AS
WITH ga AS (
  SELECT version, ver_key, released_at,
         lag(version) OVER (ORDER BY ver_key) AS prev_version
    FROM ansible_release
   WHERE NOT is_prerelease AND released_at IS NOT NULL
)
SELECT ga.prev_version AS from_ansible,
       ga.version      AS to_ansible,
       ga.released_at,
       d.fqcn, d.from_version, d.to_version, d.change,
       ga.ver_key
  FROM ga
  CROSS JOIN LATERAL (
    SELECT coalesce(o.fqcn, n.fqcn) AS fqcn,
           o.collection_version     AS from_version,
           n.collection_version     AS to_version,
           ver_bump(o.collection_version, n.collection_version) AS change
      FROM (SELECT * FROM release_content WHERE ansible_version = ga.prev_version) o
      FULL JOIN (SELECT * FROM release_content WHERE ansible_version = ga.version) n ON n.fqcn = o.fqcn
  ) d
 WHERE ga.prev_version IS NOT NULL
   AND d.change <> 'same';

-- Release cadence per collection (Galaxy GA releases).
CREATE OR REPLACE VIEW v_collection_cadence AS
SELECT fqcn,
       count(*)                                                         AS n_ga_versions,
       count(*) FILTER (WHERE released_at > now() - interval '365 days') AS releases_last_year,
       min(released_at)                                                 AS first_release,
       max(released_at)                                                 AS last_release,
       justify_interval((max(released_at) - min(released_at)) / nullif(count(*) - 1, 0)) AS avg_gap
  FROM collection_version
 WHERE NOT is_prerelease
 GROUP BY fqcn;

------------------------------------------------------------------------------
-- Query functions
------------------------------------------------------------------------------

-- Which collections (and versions) ship in an ansible release?
--   SELECT * FROM collections_for_ansible('12');        -- newest 12.x
--   SELECT * FROM collections_for_ansible('11.4.0');
CREATE OR REPLACE FUNCTION collections_for_ansible(p_ansible text DEFAULT 'latest')
RETURNS TABLE (ansible_version text, core_version text, fqcn text, collection_version text,
               requires_ansible text, collection_released_at timestamptz, bundled_core_satisfies boolean)
LANGUAGE sql STABLE AS $$
  SELECT v.ansible_version, v.core_version, v.fqcn, v.collection_version,
         v.requires_ansible, v.collection_released_at, v.bundled_core_satisfies
    FROM v_release_content v
   WHERE v.ansible_version = resolve_ansible(p_ansible)
   ORDER BY v.fqcn
$$;

-- Which ansible releases ship a collection (optionally a version spec of it)?
--   SELECT * FROM ansible_for_collection('community.general', '>=9,<10');
CREATE OR REPLACE FUNCTION ansible_for_collection(p_fqcn text, p_spec text DEFAULT NULL, p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (ansible_version text, line text, released_at timestamptz, collection_version text, core_version text)
LANGUAGE sql STABLE AS $$
  SELECT ar.version, ar.line, ar.released_at, rc.collection_version, ar.core_version
    FROM release_content rc
    JOIN ansible_release ar ON ar.version = rc.ansible_version
   WHERE rc.fqcn = p_fqcn
     AND version_satisfies(rc.collection_version, p_spec)
     AND (p_include_prerelease OR NOT ar.is_prerelease)
   ORDER BY ar.ver_key DESC
$$;

-- For an engine version, the newest Galaxy version of every package collection
-- that declares support for it (independent of what the package bundles).
--   SELECT * FROM collections_for_core('2.16');
CREATE OR REPLACE FUNCTION collections_for_core(p_core text DEFAULT 'latest', p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (fqcn text, best_version text, requires_ansible text, released_at timestamptz,
               latest_version text, is_latest boolean, shipped_in_ansible text)
LANGUAGE sql STABLE AS $$
  WITH core AS (SELECT resolve_core(p_core) AS v)
  SELECT c.fqcn,
         best.version,
         best.requires_ansible,
         best.released_at,
         lat.latest_version,
         best.version IS NOT DISTINCT FROM lat.latest_version,
         (SELECT rc.ansible_version
            FROM release_content rc JOIN ansible_release ar ON ar.version = rc.ansible_version
           WHERE rc.fqcn = c.fqcn AND rc.collection_version = best.version
           ORDER BY ar.ver_key DESC LIMIT 1)
    FROM collection c
    JOIN v_collection_latest lat ON lat.fqcn = c.fqcn
    LEFT JOIN LATERAL (
      SELECT cv.version, cv.requires_ansible, cv.released_at
        FROM collection_version cv, core
       WHERE cv.fqcn = c.fqcn
         AND (p_include_prerelease OR NOT cv.is_prerelease)
         AND version_satisfies(core.v, cv.requires_ansible)
       ORDER BY cv.ver_key DESC
       LIMIT 1
    ) best ON true
   ORDER BY c.fqcn
$$;

-- Which engine series does a collection version support? (NULL version = latest GA)
--   SELECT * FROM core_for_collection('amazon.aws', '7.0.0');
CREATE OR REPLACE FUNCTION core_for_collection(p_fqcn text, p_version text DEFAULT NULL)
RETURNS TABLE (collection_version text, requires_ansible text, series text, core_version text, product text)
LANGUAGE sql STABLE AS $$
  WITH cv AS (
    SELECT version, requires_ansible FROM collection_version
     WHERE fqcn = p_fqcn
       AND (version = p_version OR (p_version IS NULL AND NOT is_prerelease))
     ORDER BY ver_key DESC LIMIT 1
  )
  SELECT cv.version, cv.requires_ansible, m.series, m.core_version, s.product
    FROM cv
    JOIN mv_spec_series_compat m ON m.spec = coalesce(cv.requires_ansible, '')
    JOIN v_core_series s ON s.series = m.series
   ORDER BY m.core_ver_key
$$;

-- Which ansible releases bundle a given engine version or series?
--   SELECT * FROM ansible_for_core('2.18');
CREATE OR REPLACE FUNCTION ansible_for_core(p_core text)
RETURNS TABLE (ansible_version text, released_at timestamptz, core_version text, is_prerelease boolean)
LANGUAGE sql STABLE AS $$
  SELECT version, released_at, core_version, is_prerelease
    FROM ansible_release
   WHERE core_version = p_core
      OR ver_series(core_version) = p_core
      OR (p_core ~ '^[<>=!~]' AND version_satisfies(core_version, p_core))
   ORDER BY ver_key DESC
$$;

------------------------------------------------------------------------------
-- Controller / managed-node python and platform support
------------------------------------------------------------------------------

-- Per engine series: controller pythons, managed-node pythons, tested platforms.
CREATE OR REPLACE VIEW v_core_support AS
SELECT cs.series,
       cs.latest_version,
       cs.latest_released,
       (SELECT array_agg(python ORDER BY ver_key) FROM core_python p
         WHERE p.series = cs.series AND p.controller)            AS controller_python,
       (SELECT array_agg(python ORDER BY ver_key) FROM core_python p
         WHERE p.series = cs.series AND p.target)                AS target_python,
       (SELECT array_agg(DISTINCT os || '/' || os_version) FROM core_platform f
         WHERE f.series = cs.series)                             AS tested_platforms,
       cs.bundled_in_ansible_lines,
       cs.latest_ver_key
  FROM v_core_series cs
 WHERE EXISTS (SELECT 1 FROM core_python p WHERE p.series = cs.series);

-- '7' matches 7, 7.6, 7.9; '7.9' only 7.9; NULL matches every version.
CREATE OR REPLACE FUNCTION os_version_matches(p_have text, p_want text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_want IS NULL OR p_have = p_want OR p_have LIKE p_want || '.%'
$$;

-- Which engine series support a python version on managed nodes ('target',
-- the default) or on the controller? Newest first.
--   SELECT * FROM core_for_python('2.7');
--   SELECT * FROM core_for_python('3.9', 'controller');
CREATE OR REPLACE FUNCTION core_for_python(p_python text, p_role text DEFAULT 'target')
RETURNS TABLE (series text, core_version text, released_at timestamptz, role text,
               controller_python text[], ansible_lines text[])
LANGUAGE sql STABLE AS $$
  SELECT s.series, s.latest_version, s.latest_released, lower(p_role),
         s.controller_python, s.bundled_in_ansible_lines
    FROM v_core_support s
    JOIN core_python p ON p.series = s.series AND p.python = p_python
   WHERE CASE lower(p_role) WHEN 'controller' THEN p.controller ELSE p.target END
   ORDER BY s.latest_ver_key DESC
$$;

-- Which engine series are tested against a platform? Newest first.
--   SELECT * FROM core_for_platform('rhel', '7');
--   SELECT * FROM core_for_platform('ubuntu');
CREATE OR REPLACE FUNCTION core_for_platform(p_os text, p_version text DEFAULT NULL)
RETURNS TABLE (series text, core_version text, released_at timestamptz, os text, os_version text,
               kind text, python text[], controller_python text[], ansible_lines text[])
LANGUAGE sql STABLE AS $$
  SELECT s.series, s.latest_version, s.latest_released, f.os, f.os_version, f.kind, f.python,
         s.controller_python, s.bundled_in_ansible_lines
    FROM v_core_support s
    JOIN core_platform f ON f.series = s.series
   WHERE f.os = lower(p_os) AND os_version_matches(f.os_version, p_version)
   ORDER BY s.latest_ver_key DESC, f.ver_key DESC NULLS LAST, f.kind
$$;

-- The newest engine that still supports a platform, and for it the newest
-- Galaxy version of every collection that declares support for that engine.
-- p_core narrows the engine choice ('2.15', '<2.16').
--   SELECT * FROM collections_for_platform('rhel', '7');
CREATE OR REPLACE FUNCTION collections_for_platform(p_os text, p_version text DEFAULT NULL,
                                                    p_core text DEFAULT NULL, p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (core_version text, fqcn text, best_version text, requires_ansible text, released_at timestamptz,
               latest_version text, is_latest boolean, shipped_in_ansible text)
LANGUAGE sql STABLE AS $$
  WITH core AS (
    SELECT f.core_version AS v
      FROM core_for_platform(p_os, p_version) f
     WHERE p_core IS NULL OR f.series = p_core OR f.core_version = p_core
        OR (p_core ~ '^[<>=!~]' AND version_satisfies(f.core_version, p_core))
     ORDER BY ver_key(f.core_version) DESC
     LIMIT 1
  )
  SELECT core.v, c.* FROM core, collections_for_core(core.v, p_include_prerelease) c
$$;

-- Same, starting from the python on the managed nodes (or the controller).
--   SELECT * FROM collections_for_python('2.7');
CREATE OR REPLACE FUNCTION collections_for_python(p_python text, p_role text DEFAULT 'target',
                                                  p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (core_version text, fqcn text, best_version text, requires_ansible text, released_at timestamptz,
               latest_version text, is_latest boolean, shipped_in_ansible text)
LANGUAGE sql STABLE AS $$
  WITH core AS (SELECT f.core_version AS v FROM core_for_python(p_python, p_role) f LIMIT 1)
  SELECT core.v, c.* FROM core, collections_for_core(core.v, p_include_prerelease) c
$$;

-- Which ansible package releases bundle an engine that is tested against a
-- platform? Newest first; feed the first row to requirements_yml().
--   SELECT * FROM ansible_for_platform('rhel', '7') LIMIT 1;
CREATE OR REPLACE FUNCTION ansible_for_platform(p_os text, p_version text DEFAULT NULL,
                                                p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (ansible_version text, released_at timestamptz, core_version text, controller_python text[])
LANGUAGE sql STABLE AS $$
  SELECT ar.version, ar.released_at, ar.core_version, s.controller_python
    FROM ansible_release ar
    JOIN v_core_support s ON s.series = ver_series(ar.core_version)
   WHERE (p_include_prerelease OR NOT ar.is_prerelease)
     AND EXISTS (SELECT 1 FROM core_platform f
                  WHERE f.series = s.series AND f.os = lower(p_os)
                    AND os_version_matches(f.os_version, p_version))
   ORDER BY ar.ver_key DESC
$$;

-- Diff two ansible releases (any resolvable inputs).
--   SELECT * FROM ansible_diff('10', '12') WHERE change = 'major';
CREATE OR REPLACE FUNCTION ansible_diff(p_from text, p_to text)
RETURNS TABLE (fqcn text, from_version text, to_version text, change text)
LANGUAGE sql STABLE AS $$
  WITH a AS (SELECT fqcn, collection_version FROM release_content WHERE ansible_version = resolve_ansible(p_from)),
       b AS (SELECT fqcn, collection_version FROM release_content WHERE ansible_version = resolve_ansible(p_to))
  SELECT coalesce(a.fqcn, b.fqcn), a.collection_version, b.collection_version,
         ver_bump(a.collection_version, b.collection_version)
    FROM a FULL JOIN b ON a.fqcn = b.fqcn
   ORDER BY array_position(ARRAY['removed','added','major','downgrade','minor','patch','prerelease','same'],
                           ver_bump(a.collection_version, b.collection_version)),
            coalesce(a.fqcn, b.fqcn)
$$;

-- A one-shot upgrade briefing between two ansible releases, as JSON.
--   SELECT jsonb_pretty(upgrade_report('9', 'latest'));
CREATE OR REPLACE FUNCTION upgrade_report(p_from text, p_to text DEFAULT 'latest')
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH f AS (SELECT * FROM ansible_release WHERE version = resolve_ansible(p_from)),
       t AS (SELECT * FROM ansible_release WHERE version = resolve_ansible(p_to)),
       d AS (SELECT * FROM ansible_diff(p_from, p_to))
  SELECT jsonb_build_object(
    'from', jsonb_build_object('ansible', f.version, 'core', f.core_version, 'python', f.requires_python, 'released_at', f.released_at),
    'to',   jsonb_build_object('ansible', t.version, 'core', t.core_version, 'python', t.requires_python, 'released_at', t.released_at),
    'core_change', ver_bump(f.core_version, t.core_version),
    'counts', (SELECT jsonb_object_agg(change, n) FROM (SELECT change, count(*) n FROM d GROUP BY change) x),
    'removed_collections', (SELECT coalesce(jsonb_agg(fqcn ORDER BY fqcn), '[]') FROM d WHERE change = 'removed'),
    'added_collections',   (SELECT coalesce(jsonb_agg(fqcn ORDER BY fqcn), '[]') FROM d WHERE change = 'added'),
    'major_bumps',         (SELECT coalesce(jsonb_object_agg(fqcn, from_version || ' -> ' || to_version), '{}') FROM d WHERE change = 'major'),
    'upcoming_removals',   (SELECT coalesce(jsonb_object_agg(c.fqcn, c.removal), '{}')
                              FROM collection c JOIN release_content rc ON rc.fqcn = c.fqcn AND rc.ansible_version = t.version
                             WHERE c.removal IS NOT NULL),
    'days_between', (t.released_at::date - f.released_at::date))
  FROM f, t
$$;

-- Which ansible releases satisfy ALL of a set of collection requirements?
--   SELECT * FROM find_ansible('{"community.general": ">=9", "amazon.aws": ">=8,<9"}');
--   SELECT * FROM find_ansible('{"kubernetes.core": ">=5"}', p_core_spec => '<2.19');
CREATE OR REPLACE FUNCTION find_ansible(p_requirements jsonb, p_core_spec text DEFAULT NULL, p_include_prerelease boolean DEFAULT false)
RETURNS TABLE (ansible_version text, released_at timestamptz, core_version text, matched jsonb)
LANGUAGE sql STABLE AS $$
  SELECT ar.version, ar.released_at, ar.core_version,
         jsonb_object_agg(rc.fqcn, rc.collection_version)
    FROM ansible_release ar
    JOIN jsonb_each_text(p_requirements) req ON true
    JOIN release_content rc ON rc.ansible_version = ar.version AND rc.fqcn = req.key
   WHERE version_satisfies(rc.collection_version, req.value)
     AND version_satisfies(ar.core_version, p_core_spec)
     AND (p_include_prerelease OR NOT ar.is_prerelease)
   GROUP BY ar.version, ar.released_at, ar.core_version, ar.ver_key
  HAVING count(*) = (SELECT count(*) FROM jsonb_object_keys(p_requirements))
   ORDER BY ar.ver_key DESC
$$;

-- Emit a ready-to-use requirements.yml pinning an ansible release's collections.
--   SELECT requirements_yml('11', ARRAY['community.general','ansible.posix']);
CREATE OR REPLACE FUNCTION requirements_yml(p_ansible text DEFAULT 'latest', p_only text[] DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT format(E'# Collections from ansible %s (ansible-core %s)\n# generated by ansiblecolldb %s\ncollections:\n',
                ar.version, ar.core_version, to_char(now(), 'YYYY-MM-DD'))
      || string_agg(format(E'  - name: %s\n    version: "==%s"\n', rc.fqcn, rc.collection_version), '' ORDER BY rc.fqcn)
    FROM ansible_release ar
    JOIN release_content rc ON rc.ansible_version = ar.version
   WHERE ar.version = resolve_ansible(p_ansible)
     AND (p_only IS NULL OR rc.fqcn = ANY (p_only))
   GROUP BY ar.version, ar.core_version
$$;

-- Per ansible line, which versions of a collection shipped.
--   SELECT * FROM collection_timeline('community.docker');
CREATE OR REPLACE FUNCTION collection_timeline(p_fqcn text)
RETURNS TABLE (line text, first_ansible text, last_ansible text, min_version text, max_version text, core_series text[])
LANGUAGE sql STABLE AS $$
  SELECT ar.line,
         (array_agg(ar.version ORDER BY ar.ver_key))[1],
         (array_agg(ar.version ORDER BY ar.ver_key DESC))[1],
         (array_agg(rc.collection_version ORDER BY ver_key(rc.collection_version)))[1],
         (array_agg(rc.collection_version ORDER BY ver_key(rc.collection_version) DESC))[1],
         array_agg(DISTINCT ver_series(ar.core_version))
    FROM release_content rc
    JOIN ansible_release ar ON ar.version = rc.ansible_version
   WHERE rc.fqcn = p_fqcn AND NOT ar.is_prerelease
   GROUP BY ar.line
   ORDER BY min(ar.ver_key)
$$;

-- Support matrix for a collection: newest version of each of its major lines
-- and the engine series it supports.
--   SELECT * FROM collection_support_matrix('ansible.windows');
CREATE OR REPLACE FUNCTION collection_support_matrix(p_fqcn text)
RETURNS TABLE (collection_major bigint, latest_version text, released_at timestamptz,
               requires_ansible text, supported_core_series text[])
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT ON ((ver_key)[1])
         (ver_key)[1], version, released_at, requires_ansible, supported_core_series
    FROM v_collection_version
   WHERE fqcn = p_fqcn AND NOT is_prerelease
   ORDER BY (ver_key)[1] DESC, ver_key DESC
$$;

-- Fuzzy search by name, description, tags, namespace.
--   SELECT * FROM search_collections('kubernetes');
CREATE OR REPLACE FUNCTION search_collections(p_term text)
RETURNS TABLE (fqcn text, status text, latest_version text, description text, score int)
LANGUAGE sql STABLE AS $$
  SELECT c.fqcn, lc.status, l.latest_version, c.description,
         (CASE WHEN c.fqcn ILIKE '%' || p_term || '%' THEN 10 ELSE 0 END
        + CASE WHEN p_term ILIKE ANY (c.tags) THEN 5 ELSE 0 END
        + CASE WHEN c.description ILIKE '%' || p_term || '%' THEN 2 ELSE 0 END) AS score
    FROM collection c
    LEFT JOIN v_collection_latest l ON l.fqcn = c.fqcn
    LEFT JOIN v_collection_lifecycle lc ON lc.fqcn = c.fqcn
   WHERE c.fqcn ILIKE '%' || p_term || '%'
      OR c.description ILIKE '%' || p_term || '%'
      OR p_term ILIKE ANY (c.tags)
   ORDER BY score DESC, c.download_count DESC NULLS LAST
$$;

------------------------------------------------------------------------------
-- Environments: register what you run, then watch the drift
------------------------------------------------------------------------------

--   CALL register_environment('prod', '10', '{"community.general": "9.5.0"}', 'main fleet');
CREATE OR REPLACE PROCEDURE register_environment(p_name text, p_ansible text, p_pinned jsonb DEFAULT '{}', p_notes text DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
  v text := resolve_ansible(p_ansible);
BEGIN
  IF v IS NULL THEN
    RAISE EXCEPTION 'unknown ansible version: %', p_ansible;
  END IF;
  INSERT INTO environment (name, ansible_version, pinned, notes)
  VALUES (p_name, v, coalesce(p_pinned, '{}'), p_notes)
  ON CONFLICT (name) DO UPDATE
     SET ansible_version = EXCLUDED.ansible_version, pinned = EXCLUDED.pinned,
         notes = coalesce(EXCLUDED.notes, environment.notes), registered_at = now();
  RAISE NOTICE 'environment % -> ansible % (%)', p_name, v,
    (SELECT core_version FROM ansible_release WHERE version = v);
END $$;

CREATE OR REPLACE PROCEDURE drop_environment(p_name text)
LANGUAGE sql AS $$
  DELETE FROM environment WHERE name = p_name;
$$;

-- Per environment and collection: what's installed vs. what you could have.
CREATE OR REPLACE VIEW v_environment_drift AS
SELECT e.name                      AS environment,
       e.ansible_version,
       ar.core_version,
       inst.fqcn,
       inst.installed,
       line_latest.collection_version AS latest_in_line,
       best.best_version              AS best_for_core,
       ver_bump(inst.installed, best.best_version) AS behind_by,
       lc.status
  FROM environment e
  JOIN ansible_release ar ON ar.version = e.ansible_version
  CROSS JOIN LATERAL (
    SELECT coalesce(p.fqcn, rc.fqcn) AS fqcn, coalesce(p.version, rc.collection_version) AS installed
      FROM (SELECT * FROM release_content WHERE ansible_version = e.ansible_version) rc
      FULL JOIN (SELECT key AS fqcn, value AS version FROM jsonb_each_text(e.pinned)) p ON p.fqcn = rc.fqcn
  ) inst
  LEFT JOIN release_content line_latest
         ON line_latest.ansible_version = resolve_ansible(ar.line) AND line_latest.fqcn = inst.fqcn
  LEFT JOIN LATERAL (
    SELECT cv.version AS best_version FROM collection_version cv
     WHERE cv.fqcn = inst.fqcn AND NOT cv.is_prerelease
       AND version_satisfies(ar.core_version, cv.requires_ansible)
     ORDER BY cv.ver_key DESC LIMIT 1
  ) best ON true
  LEFT JOIN v_collection_lifecycle lc ON lc.fqcn = inst.fqcn;

CREATE OR REPLACE VIEW v_environment_summary AS
SELECT environment, ansible_version, core_version,
       resolve_ansible('latest') AS newest_ansible,
       count(*)                                        AS n_collections,
       count(*) FILTER (WHERE behind_by = 'major')     AS behind_major,
       count(*) FILTER (WHERE behind_by = 'minor')     AS behind_minor,
       count(*) FILTER (WHERE behind_by = 'patch')     AS behind_patch,
       count(*) FILTER (WHERE status <> 'active')      AS at_risk
  FROM v_environment_drift
 GROUP BY environment, ansible_version, core_version;

-- One row per ansible line: how big a step is it from the previous line?
CREATE OR REPLACE VIEW v_ansible_line_summary AS
WITH lines AS (
  SELECT line,
         min(ver_key)                                                       AS line_key,
         min(released_at) FILTER (WHERE NOT is_prerelease)                  AS ga_released_at,
         resolve_ansible(line)                                              AS latest_version,
         count(*) FILTER (WHERE NOT is_prerelease AND released_at IS NOT NULL) AS n_ga_releases
    FROM ansible_release GROUP BY line
), ordered AS (
  SELECT l.*, lag(latest_version) OVER (ORDER BY line_key) AS prev_latest FROM lines l
)
SELECT o.line,
       o.ga_released_at,
       o.latest_version,
       o.n_ga_releases,
       ar.core_version AS latest_core_version,
       (SELECT array_agg(DISTINCT ver_series(x.core_version)) FROM ansible_release x WHERE x.line = o.line) AS core_series,
       (SELECT count(*) FROM release_content WHERE ansible_version = o.latest_version) AS n_collections,
       d.added, d.removed, d.major_bumps, d.minor_bumps, d.patch_bumps
  FROM ordered o
  JOIN ansible_release ar ON ar.version = o.latest_version
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE change = 'added')   AS added,
           count(*) FILTER (WHERE change = 'removed') AS removed,
           count(*) FILTER (WHERE change = 'major')   AS major_bumps,
           count(*) FILTER (WHERE change = 'minor')   AS minor_bumps,
           count(*) FILTER (WHERE change = 'patch')   AS patch_bumps
      FROM ansible_diff(o.prev_latest, o.latest_version)
     WHERE o.prev_latest IS NOT NULL
  ) d ON true
 ORDER BY o.line_key;
