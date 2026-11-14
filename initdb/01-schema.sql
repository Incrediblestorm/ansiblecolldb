-- ansiblecolldb schema
-- Everything lives in the "ansible" schema; the database search_path is set so
-- you can just type `SELECT * FROM v_ansible_release;`.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS ansible;
SET search_path = ansible, public;

DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET search_path = ansible, public', current_database());
END $$;

------------------------------------------------------------------------------
-- Version helpers
------------------------------------------------------------------------------

-- Turn a PEP 440 / semver-ish version string into a sortable array:
--   [major, minor, patch, micro, pre_rank, pre_num, post]
-- pre_rank: dev=-4, a/alpha=-3, b/beta=-2, rc/c/pre=-1, final=0
-- so '2.19.0b1' < '2.19.0rc1' < '2.19.0' < '2.19.0.post1'.
CREATE OR REPLACE FUNCTION ver_key(v text)
RETURNS bigint[] LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
  m    text[];
  nums bigint[];
BEGIN
  m := regexp_match(lower(btrim(v)),
    '^v?(\d+(?:\.\d+)*)(?:[-._]?(dev|a|alpha|b|beta|c|rc|pre|preview)[-._]?(\d*))?(?:[-._]?(?:post|r)(\d+))?(?:\+.*)?$');
  IF m IS NULL THEN
    RETURN NULL;
  END IF;
  nums := string_to_array(m[1], '.')::bigint[];
  WHILE coalesce(array_length(nums, 1), 0) < 4 LOOP
    nums := nums || 0::bigint;
  END LOOP;
  RETURN nums[1:4] || ARRAY[
    CASE m[2]
      WHEN 'dev' THEN -4
      WHEN 'a' THEN -3 WHEN 'alpha' THEN -3
      WHEN 'b' THEN -2 WHEN 'beta' THEN -2
      WHEN 'c' THEN -1 WHEN 'rc' THEN -1 WHEN 'pre' THEN -1 WHEN 'preview' THEN -1
      ELSE 0
    END,
    coalesce(nullif(m[3], '')::bigint, 0),
    coalesce(m[4]::bigint, 0)
  ]::bigint[];
END $$;

CREATE OR REPLACE FUNCTION is_prerelease(v text)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT (ansible.ver_key(v))[5] < 0
$$;

-- '2.19.5' -> '2.19', '12.3.0' -> '12'  (series granularity is a parameter)
CREATE OR REPLACE FUNCTION ver_series(v text, parts int DEFAULT 2)
RETURNS text LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
  SELECT array_to_string((ansible.ver_key(v))[1:parts], '.')
$$;

-- Classify the jump between two versions: major / minor / patch / prerelease / same / downgrade
CREATE OR REPLACE FUNCTION ver_bump(old_v text, new_v text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN old_v IS NULL AND new_v IS NULL THEN NULL
    WHEN old_v IS NULL THEN 'added'
    WHEN new_v IS NULL THEN 'removed'
    WHEN ansible.ver_key(new_v) = ansible.ver_key(old_v) THEN 'same'
    WHEN ansible.ver_key(new_v) < ansible.ver_key(old_v) THEN 'downgrade'
    WHEN (ansible.ver_key(new_v))[1] <> (ansible.ver_key(old_v))[1] THEN 'major'
    WHEN (ansible.ver_key(new_v))[2] <> (ansible.ver_key(old_v))[2] THEN 'minor'
    WHEN (ansible.ver_key(new_v))[3:4] <> (ansible.ver_key(old_v))[3:4] THEN 'patch'
    ELSE 'prerelease'
  END
$$;

-- Does version v satisfy a PEP 440 style specifier like '>=2.15.0,<2.20' ?
-- Supports >=, <=, >, <, ==, =, ===, !=, ~= and trailing '.*' wildcards.
-- NULL/empty/'*' spec means "anything goes".
CREATE OR REPLACE FUNCTION version_satisfies(v text, spec text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
  clause text;
  m      text[];
  op     text;
  target text;
  vk     bigint[];
  tk     bigint[];
  n      int;
BEGIN
  IF v IS NULL THEN
    RETURN NULL;
  END IF;
  IF spec IS NULL OR btrim(spec) IN ('', '*') THEN
    RETURN true;
  END IF;
  vk := ansible.ver_key(v);
  IF vk IS NULL THEN
    RETURN NULL;
  END IF;

  FOREACH clause IN ARRAY string_to_array(spec, ',') LOOP
    clause := btrim(clause);
    CONTINUE WHEN clause = '';
    m := regexp_match(clause, '^(~=|===|==|!=|<=|>=|<|>|=)?\s*(.+)$');
    op := coalesce(m[1], '==');
    target := btrim(m[2]);

    IF target LIKE '%.*' THEN
      tk := string_to_array(left(target, -2), '.')::bigint[];
      n := array_length(tk, 1);
      IF op IN ('==', '=', '===') AND vk[1:n] IS DISTINCT FROM tk THEN RETURN false; END IF;
      IF op = '!=' AND vk[1:n] = tk THEN RETURN false; END IF;
      CONTINUE;
    END IF;

    tk := ansible.ver_key(target);
    IF tk IS NULL THEN
      RETURN NULL;
    END IF;

    CASE op
      WHEN '>='  THEN IF NOT vk >= tk THEN RETURN false; END IF;
      WHEN '<='  THEN IF NOT vk <= tk THEN RETURN false; END IF;
      WHEN '>'   THEN IF NOT vk >  tk THEN RETURN false; END IF;
      WHEN '<'   THEN IF NOT vk <  tk THEN RETURN false; END IF;
      WHEN '!='  THEN IF vk = tk THEN RETURN false; END IF;
      WHEN '~='  THEN
        n := array_length(string_to_array(regexp_replace(target, '[^0-9.].*$', ''), '.'), 1);
        IF vk < tk OR vk[1:n-1] IS DISTINCT FROM tk[1:n-1] THEN RETURN false; END IF;
      ELSE  -- ==, =, ===
        IF vk <> tk THEN RETURN false; END IF;
    END CASE;
  END LOOP;
  RETURN true;
END $$;

------------------------------------------------------------------------------
-- Core data
------------------------------------------------------------------------------

-- Every release of the engine: classic "ansible" (<= 2.9), ansible-base (2.10), ansible-core (2.11+)
CREATE TABLE core_release (
  version         text PRIMARY KEY,
  product         text NOT NULL CHECK (product IN ('ansible', 'ansible-base', 'ansible-core')),
  ver_key         bigint[] NOT NULL,
  series          text NOT NULL,
  is_prerelease   boolean NOT NULL,
  released_at     timestamptz,
  requires_python text,
  yanked          boolean NOT NULL DEFAULT false
);
CREATE INDEX core_release_series_idx ON core_release (series, ver_key);

-- Every release of the community "ansible" package, with the engine it pins.
CREATE TABLE ansible_release (
  version         text PRIMARY KEY,
  line            text NOT NULL,         -- '2.10', '3', ... '12' (release line / major)
  ver_key         bigint[] NOT NULL,
  is_prerelease   boolean NOT NULL,
  released_at     timestamptz,           -- PyPI upload time (NULL = not on PyPI yet)
  core_version    text NOT NULL,
  core_product    text NOT NULL,
  requires_python text
);
CREATE INDEX ansible_release_line_idx ON ansible_release (line, ver_key);

-- Every collection that has ever shipped in the ansible package.
CREATE TABLE collection (
  fqcn               text PRIMARY KEY,
  namespace          text NOT NULL,
  name               text NOT NULL,
  repository         text,
  maintainers        text[] NOT NULL DEFAULT '{}',
  description        text,
  license            text[] NOT NULL DEFAULT '{}',
  tags               text[] NOT NULL DEFAULT '{}',
  dependencies       jsonb NOT NULL DEFAULT '{}',   -- of the highest version on Galaxy
  galaxy_deprecated  boolean,
  download_count     bigint,
  galaxy_found       boolean NOT NULL DEFAULT false,
  removal            jsonb                          -- removal block from collection-meta.yaml
);

-- Every version of those collections published on Galaxy.
CREATE TABLE collection_version (
  fqcn             text NOT NULL REFERENCES collection ON DELETE CASCADE,
  version          text NOT NULL,
  ver_key          bigint[],
  is_prerelease    boolean,
  requires_ansible text,
  released_at      timestamptz,
  marks            text[] NOT NULL DEFAULT '{}',
  PRIMARY KEY (fqcn, version)
);
CREATE INDEX collection_version_key_idx ON collection_version (fqcn, ver_key);

-- Which collection version is bundled in which ansible release.
-- (No FK to collection_version: a few historic versions are gone from Galaxy.)
CREATE TABLE release_content (
  ansible_version    text NOT NULL REFERENCES ansible_release ON DELETE CASCADE,
  fqcn               text NOT NULL REFERENCES collection ON DELETE CASCADE,
  collection_version text NOT NULL,
  PRIMARY KEY (ansible_version, fqcn)
);
CREATE INDEX release_content_fqcn_idx ON release_content (fqcn);

-- Audit trail of loads.
CREATE TABLE load_run (
  id          bigserial PRIMARY KEY,
  loaded_at   timestamptz NOT NULL DEFAULT now(),
  duration    interval,
  source      jsonb,
  stats       jsonb
);

-- User-registered environments ("prod runs ansible 10.4.0") for drift tracking.
-- Survives data refreshes.
CREATE TABLE environment (
  name            text PRIMARY KEY,
  ansible_version text NOT NULL,
  pinned          jsonb NOT NULL DEFAULT '{}',   -- fqcn -> version overrides installed on top
  notes           text,
  registered_at   timestamptz NOT NULL DEFAULT now()
);
