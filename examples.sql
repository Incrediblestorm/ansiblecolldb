-- ansiblecolldb tour:  docker exec -it ansibledb psql -U ansible -f /opt/ansibledb/examples.sql
\pset pager off
\x auto

\echo '== Last load'
SELECT loaded_at, duration, stats FROM load_run ORDER BY id DESC LIMIT 1;

\echo '== Ansible lines at a glance'
SELECT * FROM v_ansible_line_summary;

\echo '== Engine series and which ansible lines bundle them'
SELECT series, product, latest_version, latest_released, bundled_in_ansible_lines FROM v_core_series ORDER BY latest_ver_key;

\echo '== What ships in the newest ansible 11?'
SELECT fqcn, collection_version, requires_ansible FROM collections_for_ansible('11') LIMIT 10;

\echo '== Which ansible releases ship community.general 9.x?'
SELECT * FROM ansible_for_collection('community.general', '==9.*') LIMIT 5;

\echo '== Best collection versions for an ansible-core 2.16 control node'
SELECT fqcn, best_version, latest_version, is_latest FROM collections_for_core('2.16') WHERE NOT is_latest LIMIT 10;

\echo '== Engine support of amazon.aws, per major'
SELECT * FROM collection_support_matrix('amazon.aws');

\echo '== Find ansible releases with community.general >= 10 AND kubernetes.core >= 5 on core < 2.19'
SELECT * FROM find_ansible('{"community.general": ">=10", "kubernetes.core": ">=5"}', '<2.19') LIMIT 5;

\echo '== Upgrade briefing 9 -> latest'
SELECT jsonb_pretty(upgrade_report('9', 'latest'));

\echo '== Collections on their way out'
SELECT fqcn, status, last_ansible FROM v_collection_lifecycle WHERE status <> 'active' ORDER BY status, fqcn;

\echo '== Bundles whose engine does not meet a collection''s requires_ansible'
SELECT * FROM v_bundle_conflicts LIMIT 10;

\echo '== community.docker across ansible lines'
SELECT * FROM collection_timeline('community.docker');

\echo '== requirements.yml for a subset of ansible 10'
SELECT requirements_yml('10', ARRAY['ansible.posix', 'community.general', 'community.crypto']);

\echo '== Track an environment and see its drift'
CALL register_environment('demo-prod', '9', '{"community.general": "9.0.0"}', 'example environment');
SELECT * FROM v_environment_summary;
SELECT fqcn, installed, latest_in_line, best_for_core, behind_by FROM v_environment_drift
 WHERE environment = 'demo-prod' AND behind_by IN ('major', 'minor') LIMIT 10;
CALL drop_environment('demo-prod');
