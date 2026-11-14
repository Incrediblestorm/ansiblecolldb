#!/usr/bin/env python3
"""Fetch ansible package / ansible-core / collection version data and emit one JSON
document for the ansible.ingest() stored procedure.

Sources (nothing is hard-coded, everything is discovered at run time):
  * ansible-community/ansible-build-data  - every ansible package release, the
    collection versions it bundles and the engine version it pins (*.deps),
    plus collection metadata / removal schedules (collection-meta.yaml)
  * PyPI JSON API - release dates of ansible, ansible-core, ansible-base
  * Galaxy v3 API - every published version of every collection, with its
    requires_ansible specifier, plus description/tags/license/download count
"""

import io
import json
import os
import re
import sys
import tarfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import yaml

BUILD_DATA_REF = os.environ.get("BUILD_DATA_REF", "main")
BUILD_DATA_URL = f"https://codeload.github.com/ansible-community/ansible-build-data/tar.gz/{BUILD_DATA_REF}"
GALAXY = os.environ.get("GALAXY_URL", "https://galaxy.ansible.com").rstrip("/")
GALAXY_INDEX = GALAXY + "/api/v3/plugin/ansible/content/published/collections/index"
PYPI = "https://pypi.org/pypi/{}/json"
WORKERS = int(os.environ.get("FETCH_WORKERS", "8"))
UA = "ansiblecolldb/1.0 (+https://github.com/ansible-community/ansible-build-data)"

DEPS_RE = re.compile(r"^ansible-(\d.*)\.deps$")


def log(msg):
    print(f"[fetch] {msg}", file=sys.stderr, flush=True)


def get(url, *, as_json=True, tries=6):
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
            return json.loads(body) if as_json else body
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code not in (429, 500, 502, 503, 504) or attempt == tries - 1:
                raise
            wait = int(e.headers.get("Retry-After") or 0) or 2 ** attempt
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == tries - 1:
                raise
            wait = 2 ** attempt
        log(f"retry {attempt + 1} in {wait}s: {url}")
        time.sleep(wait)


# --------------------------------------------------------------------------- build data

def parse_deps(text):
    meta, cols = {}, {}
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or ":" not in line:
            continue
        key, val = (s.strip() for s in line.split(":", 1))
        (meta if key.startswith("_") else cols)[key] = val
    return meta, cols


def fetch_build_data():
    log(f"downloading ansible-build-data@{BUILD_DATA_REF}")
    blob = get(BUILD_DATA_URL, as_json=False)
    releases, coll_meta = {}, {}
    metas = []
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for member in tar.getmembers():
            parts = member.name.split("/")
            if len(parts) != 3 or not member.isfile():
                continue
            _, line_dir, fname = parts
            if (m := DEPS_RE.match(fname)):
                meta, cols = parse_deps(tar.extractfile(member).read().decode())
                version = meta.get("_ansible_version", m.group(1))
                if "_ansible_core_version" in meta:
                    core, product = meta["_ansible_core_version"], "ansible-core"
                else:
                    core, product = meta.get("_ansible_base_version"), "ansible-base"
                if not core:
                    log(f"skip {fname}: no engine version")
                    continue
                releases[version] = {
                    "version": version,
                    "core_version": core,
                    "core_product": product,
                    "requires_python": meta.get("_python"),
                    "collections": cols,
                }
            elif fname == "collection-meta.yaml":
                metas.append((line_dir, yaml.safe_load(tar.extractfile(member)) or {}))

    # Newer lines win: sort numerically by line directory ('2.10' < '3' < ... < '13')
    def line_key(d):
        return tuple(int(x) for x in d.split(".") if x.isdigit())

    # The newest line that still lists a collection is authoritative (a removal
    # announced in an old line may have been cancelled later).
    for _, doc in sorted(metas, key=lambda m: line_key(m[0])):
        for fqcn, info in (doc.get("collections") or {}).items():
            coll_meta[fqcn] = info or {}
    latest_line = max((m[0] for m in metas), key=line_key, default=None)
    log(f"{len(releases)} ansible releases, metadata for {len(coll_meta)} collections (newest line {latest_line})")
    return releases, coll_meta


# --------------------------------------------------------------------------- PyPI

def pypi_releases(project):
    data = get(PYPI.format(project)) or {"releases": {}}
    out = {}
    for version, files in data["releases"].items():
        if not files:
            continue
        uploaded = min(f["upload_time_iso_8601"] for f in files)
        out[version] = {
            "released_at": uploaded,
            "requires_python": next((f.get("requires_python") for f in files if f.get("requires_python")), None),
            "yanked": all(f.get("yanked") for f in files),
        }
    log(f"PyPI {project}: {len(out)} releases")
    return out


def major_minor(v):
    m = re.match(r"(\d+)\.(\d+)", v)
    return (int(m.group(1)), int(m.group(2))) if m else None


# --------------------------------------------------------------------------- Galaxy

def fetch_collection(fqcn):
    ns, name = fqcn.split(".", 1)
    base = f"{GALAXY_INDEX}/{ns}/{name}/"
    info = get(base)
    result = {"fqcn": fqcn, "galaxy_found": bool(info), "versions": []}
    if not info:
        return result
    result["deprecated"] = info.get("deprecated")
    result["download_count"] = info.get("download_count")

    url = base + "versions/?limit=100"
    while url:
        page = get(url)
        if not page:
            break
        for v in page.get("data", []):
            result["versions"].append({
                "version": v["version"],
                "requires_ansible": v.get("requires_ansible"),
                "released_at": v.get("created_at"),
                "marks": [m.get("value", m) if isinstance(m, dict) else m for m in v.get("marks") or []],
            })
        nxt = (page.get("links") or {}).get("next")
        url = (GALAXY + nxt) if nxt and nxt.startswith("/") else nxt

    highest = (info.get("highest_version") or {}).get("version")
    if highest:
        detail = get(f"{base}versions/{highest}/") or {}
        md = detail.get("metadata") or {}
        result.update({
            "description": md.get("description"),
            "license": md.get("license") or [],
            "tags": md.get("tags") or [],
            "dependencies": md.get("dependencies") or {},
        })
    return result


# --------------------------------------------------------------------------- main

def main():
    t0 = time.time()
    releases, coll_meta = fetch_build_data()

    with ThreadPoolExecutor(3) as pool:
        pypi_ansible, pypi_core, pypi_base = pool.map(pypi_releases, ["ansible", "ansible-core", "ansible-base"])

    core_releases = []
    for v, r in pypi_core.items():
        core_releases.append({"version": v, "product": "ansible-core", **r})
    for v, r in pypi_base.items():
        core_releases.append({"version": v, "product": "ansible-base", **r})
    # Before 2.10 the engine itself was published as "ansible"
    for v, r in pypi_ansible.items():
        if (mm := major_minor(v)) and mm < (2, 10):
            core_releases.append({"version": v, "product": "ansible", **r})

    ansible_releases = []
    for v, r in releases.items():
        pypi = pypi_ansible.get(v, {})
        ansible_releases.append({**r, "released_at": pypi.get("released_at")})

    fqcns = sorted({f for r in releases.values() for f in r["collections"]})
    log(f"querying Galaxy for {len(fqcns)} collections with {WORKERS} workers")
    with ThreadPoolExecutor(WORKERS) as pool:
        galaxy = list(pool.map(fetch_collection, fqcns))

    collections = []
    for g in galaxy:
        meta = coll_meta.get(g["fqcn"], {})
        collections.append({
            **g,
            "repository": meta.get("repository"),
            "maintainers": meta.get("maintainers") or [],
            "removal": meta.get("removal"),
        })
    missing = [c["fqcn"] for c in collections if not c["galaxy_found"]]
    if missing:
        log(f"not on Galaxy: {', '.join(missing)}")

    payload = {
        "source": {
            "fetched_at": datetime.now(timezone.utc).isoformat(),
            "build_data_ref": BUILD_DATA_REF,
            "galaxy": GALAXY,
            "seconds": round(time.time() - t0, 1),
            "missing_on_galaxy": missing,
        },
        "core_releases": core_releases,
        "ansible_releases": ansible_releases,
        "collections": collections,
    }
    json.dump(payload, sys.stdout, separators=(",", ":"), default=str)
    log(f"done in {time.time() - t0:.1f}s: {len(core_releases)} engine releases, "
        f"{len(ansible_releases)} ansible releases, {sum(len(c['versions']) for c in collections)} collection versions")


if __name__ == "__main__":
    main()
