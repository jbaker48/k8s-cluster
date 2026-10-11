#!/usr/bin/env python3
"""Read-only, bounded desired-input attestation for the Health Gate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

VERSIONS = {"flux": "2.8.5", "kustomize": "v5.8.1", "yq": "v4.52.5"}
VERSION_COMMANDS = {
    "flux": ["flux", "--version"],
    "kustomize": ["kustomize", "version"],
    "yq": ["yq", "--version"],
}
COLLECTIONS = {
    "kustomizations": "Kustomization",
    "helmreleases": "HelmRelease",
    "gitrepositories": "GitRepository",
    "ocirepositories": "OCIRepository",
    "helmrepositories": "HelmRepository",
    "helmcharts": "HelmChart",
}
SHA = re.compile(r"^[0-9a-f]{40}$")
OCI_REVISION = re.compile(r"^([^@]+)@sha256:([0-9a-f]{64})$")
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
REMOTE = re.compile(
    r"^(?:[a-z][a-z0-9+.-]*://|git::|git@|(?:github|gitlab|bitbucket)\.com[:/])",
    re.IGNORECASE,
)
UNRESOLVED_SUBSTITUTION = re.compile(r"\$\{([^}]+)\}")
SUBSTITUTION_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
HR_SPEC_FIELDS = {
    "chartRef", "chart", "interval", "releaseName", "targetNamespace", "storageNamespace",
    "dependsOn", "serviceAccountName", "persistentClient", "suspend", "timeout",
    "maxHistory", "install", "upgrade", "uninstall", "test", "rollback", "remediation",
    "driftDetection", "values", "valuesFrom", "postRenderers", "kubeConfig", "force",
    "commonMetadata", "healthChecks", "reconcileStrategy",
}
OCI_SPEC_FIELDS = {
    "url", "ref", "interval", "timeout", "suspend", "ignore", "provider", "secretRef",
    "certSecretRef", "serviceAccountName", "verify", "proxySecretRef", "insecure",
}


class Invalid(Exception):
    def __init__(self, code: str, documents: list[dict[str, Any]] | None = None):
        self.code = code
        self.documents = documents or []


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def fingerprint(value: Any) -> str:
    return "sha256:" + hashlib.sha256(canonical(value)).hexdigest()


def command(argv: list[str], cwd: Path | None = None, input_text: str | None = None) -> str:
    try:
        result = subprocess.run(argv, cwd=cwd, input=input_text, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=180, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Invalid("render-tool-unavailable") from exc
    if result.returncode:
        raise Invalid("render-unsupported")
    return result.stdout


def json_values(text: str) -> list[dict[str, Any]]:
    decoder = json.JSONDecoder()
    documents = []
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        value, offset = decoder.raw_decode(text, offset)
        if isinstance(value, dict):
            documents.append(value)
    return documents


def json_documents(text: str) -> list[dict[str, Any]]:
    return [document for document in json_values(text) if document.get("kind")]


def yaml_documents(text: str) -> list[dict[str, Any]]:
    return json_documents(command(["yq", "-o=json", "-I=0", "."], input_text=text))


def file_documents(path: Path) -> list[dict[str, Any]]:
    return json_values(command(["yq", "-o=json", "-I=0", ".", str(path)]))


def tool_versions() -> dict[str, str]:
    versions = {}
    for name in VERSIONS:
        raw = command(VERSION_COMMANDS[name])
        lines = raw.splitlines()
        version = lines[0].split()[-1] if lines and lines[0].split() else ""
        versions[name] = version
    return versions


def object_key(value: dict[str, Any]) -> tuple[str, str]:
    meta = value.get("metadata") or {}
    return str(meta.get("namespace", "default")), str(meta.get("name", ""))


def index(docs: list[dict[str, Any]], kind: str) -> dict[tuple[str, str], dict[str, Any]]:
    result = {}
    for value in docs:
        if value.get("kind") != kind:
            continue
        ident = object_key(value)
        if not ident[1] or ident in result:
            raise Invalid("render-duplicate-object")
        result[ident] = value
    return result


def items(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        if any(not isinstance(entry, dict) for entry in value):
            raise Invalid("malformed-snapshot")
        return value
    if not isinstance(value, dict) or not isinstance(value.get("items"), list):
        raise Invalid("malformed-snapshot")
    if any(not isinstance(entry, dict) for entry in value["items"]):
        raise Invalid("malformed-snapshot")
    return value["items"]


def safe_observation(collection: str, value: dict[str, Any]) -> dict[str, Any]:
    """Keep decision fields and omit values, messages, and arbitrary payloads."""
    meta = value.get("metadata") or {}
    kind = COLLECTIONS[collection]
    allowed_labels = {
        key: val
        for key, val in (meta.get("labels") or {}).items()
        if key in {
            "kustomize.toolkit.fluxcd.io/name",
            "kustomize.toolkit.fluxcd.io/namespace",
        }
    }
    identity = {
        key: meta.get(key)
        for key in ("namespace", "name", "uid", "resourceVersion", "generation", "deletionTimestamp")
        if key in meta
    }
    identity["labels"] = allowed_labels
    spec = value.get("spec") or {}
    entry: dict[str, Any] = {
        "kind": kind,
        "metadata": identity,
        "metadata_hash": fingerprint({
            "labels": meta.get("labels") or {},
            "annotations": meta.get("annotations") or {},
        }),
        "spec_hash": fingerprint(spec),
        "suspended": spec.get("suspend") is True,
    }
    if kind == "Kustomization":
        source_ref = spec.get("sourceRef") or {}
        entry["spec"] = {
            "sourceRef": {
                key: source_ref[key]
                for key in ("kind", "name", "namespace")
                if key in source_ref
            },
            "suspend": spec.get("suspend") is True,
        }
    status = value.get("status") or {}
    safe_status: dict[str, Any] = {}
    for field in (
        "observedGeneration",
        "lastAppliedRevision",
        "lastAttemptedRevision",
        "lastAttemptedGeneration",
        "lastAttemptedRevisionDigest",
        "lastAttemptedConfigDigest",
        "lastAttemptedReleaseAction",
    ):
        if isinstance(status.get(field), (str, int, float, bool)):
            safe_status[field] = status[field]
    artifact = (status.get("artifact") or {}).get("revision")
    if isinstance(artifact, str):
        safe_status["artifact_revision"] = artifact
    if isinstance(status.get("inventory"), dict):
        safe_status["inventory_ids"] = sorted(
            item.get("id", "")
            for item in (status["inventory"].get("entries") or [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        )
    conditions = []
    for condition in status.get("conditions") or []:
        if isinstance(condition, dict):
            conditions.append(
                {
                    field: condition[field]
                    for field in ("type", "status", "reason", "observedGeneration")
                    if isinstance(condition.get(field), (str, int, float, bool))
                }
            )
    safe_status["conditions"] = conditions
    history = []
    for release in status.get("history") or []:
        if isinstance(release, dict):
            history.append(
                {
                    field: release[field]
                    for field in (
                        "version", "status", "configDigest", "chartVersion",
                        "ociDigest", "lastDeployed",
                    )
                    if isinstance(release.get(field), (str, int, float, bool))
                }
            )
    if history:
        safe_status["history"] = history
    entry["status"] = safe_status
    return entry


def metadata_fingerprint(value: dict[str, Any]) -> str:
    meta = value.get("metadata") or {}
    return fingerprint({
        "labels": meta.get("labels") or {},
        "annotations": meta.get("annotations") or {},
    })


def current_conditions(resource: dict[str, Any]) -> list[dict[str, Any]] | None:
    status = resource.get("status", {})
    if not isinstance(status, dict):
        return None
    conditions = status.get("conditions") or []
    if not isinstance(conditions, list):
        return None
    seen: set[str] = set()
    for condition in conditions:
        if not isinstance(condition, dict):
            return None
        condition_type = condition.get("type")
        if not isinstance(condition_type, str) or not condition_type or condition_type in seen:
            return None
        condition_status = condition.get("status")
        if not isinstance(condition_status, str) or condition_status not in {"True", "False", "Unknown"}:
            return None
        observed_generation = condition.get("observedGeneration")
        if observed_generation is not None and not isinstance(observed_generation, int):
            return None
        seen.add(condition_type)
    return conditions


def legacy_chart_diagnostics(target: list[dict[str, Any]], live: dict[str, list[dict[str, Any]]]
                              ) -> list[dict[str, Any]]:
    rendered_repositories = index(target, "HelmRepository")
    live_repositories = index(live["helmrepositories"], "HelmRepository")
    live_charts = live["helmcharts"]
    result = []
    for release in target:
        if release.get("kind") != "HelmRelease":
            continue
        metadata = release.get("metadata") or {}
        namespace = str(metadata.get("namespace", "default"))
        name = str(metadata.get("name", ""))
        chart_spec = ((release.get("spec") or {}).get("chart") or {}).get("spec") or {}
        source_ref = chart_spec.get("sourceRef") or {}
        if source_ref.get("kind") != "HelmRepository":
            continue
        source_namespace = str(source_ref.get("namespace", namespace))
        source_name = str(source_ref.get("name", ""))
        source_ident = (source_namespace, source_name)
        desired_repository = rendered_repositories.get(source_ident)
        live_repository = live_repositories.get(source_ident)
        reason_codes = []
        if desired_repository is None:
            reason_codes.append("helmrepository-missing-from-render")
        elif live_repository is None:
            reason_codes.append("helmrepository-not-live")
        elif canonical(live_repository.get("spec") or {}) != canonical(desired_repository.get("spec") or {}) or (
            metadata_fingerprint(live_repository) != metadata_fingerprint(desired_repository)
        ):
            reason_codes.append("helmrepository-spec-mismatch")

        charts = []
        for helm_chart in live_charts:
            labels = (helm_chart.get("metadata") or {}).get("labels") or {}
            if (labels.get("helm.toolkit.fluxcd.io/name") == name
                    and labels.get("helm.toolkit.fluxcd.io/namespace") == namespace):
                charts.append(helm_chart)
        chart_reference_match = False
        status_reference_match = False
        chart_identity: tuple[str, str] | None = None
        chart_revision = ""
        chart_uid = ""
        chart_generation: int | None = None
        if len(charts) != 1:
            reason_codes.append("helmchart-missing" if not charts else "helmchart-owner-ambiguous")
        else:
            helm_chart = charts[0]
            chart_metadata = helm_chart.get("metadata") or {}
            chart_identity = object_key(helm_chart)
            chart_uid = str(chart_metadata.get("uid", ""))
            chart_generation = chart_metadata.get("generation")
            actual_spec = helm_chart.get("spec") or {}
            actual_source_ref = actual_spec.get("sourceRef") or {}
            actual_source_namespace = str(actual_source_ref.get("namespace", chart_identity[0]))
            expected_source_namespace = str(source_ref.get("namespace", namespace))
            chart_reference_match = (
                actual_spec.get("chart") == chart_spec.get("chart")
                and actual_spec.get("version") == chart_spec.get("version")
                and actual_source_ref.get("kind") == source_ref.get("kind")
                and actual_source_ref.get("name") == source_name
                and actual_source_namespace == expected_source_namespace
            )
            if not chart_reference_match:
                reason_codes.append("helmchart-reference-mismatch")
            status_reference = ((release.get("status") or {}).get("helmChart"))
            status_ident = tuple(str(part) for part in status_reference.split("/", 1)) if (
                isinstance(status_reference, str) and status_reference.count("/") == 1
            ) else None
            status_reference_match = status_ident == chart_identity
            if not status_reference_match:
                reason_codes.append("helmchart-status-reference-mismatch")
            chart_revision = str((((helm_chart.get("status") or {}).get("artifact") or {}).get("revision")) or "")
        # A matching repository chart version/artifact is diagnostic only: the HR attempt does not
        # carry the generated HelmChart artifact digest needed to bind those bytes to that attempt.
        reason_codes.append("helmchart-artifact-unbound")
        source_metadata = (live_repository or {}).get("metadata") or {}
        result.append({
            "namespace": namespace,
            "name": name,
            "source": {
                "kind": "HelmRepository", "namespace": source_namespace, "name": source_name,
                "uid": str(source_metadata.get("uid", "")),
                "generation": source_metadata.get("generation"),
                "spec_hash": fingerprint((live_repository or {}).get("spec") or {}),
                "artifact_revision": str((((live_repository or {}).get("status") or {}).get("artifact") or {}).get("revision") or ""),
            },
            "helm_chart": {
                "namespace": chart_identity[0] if chart_identity else "",
                "name": chart_identity[1] if chart_identity else "",
                "uid": chart_uid,
                "generation": chart_generation,
                "reference_match": chart_reference_match,
                "status_reference_match": status_reference_match,
                "artifact_revision": chart_revision,
            },
            "artifact_binding": "unavailable",
            "reason_codes": reason_codes,
        })
    return result


def sanitized_observations(live: dict[str, list[dict[str, Any]]]) -> dict[str, list[dict[str, Any]]]:
    return {
        collection: [safe_observation(collection, value) for value in live[collection]]
        for collection in COLLECTIONS
    }


def _reference_list(spec: dict[str, Any], field: str) -> list[str]:
    value = spec.get(field, [])
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise Invalid("render-unsupported")
    return value


def _generator_references(spec: dict[str, Any], field: str) -> list[str]:
    generators = spec.get(field, [])
    if generators is None:
        return []
    if not isinstance(generators, list):
        raise Invalid("render-unsupported")
    refs = []
    for generator in generators:
        if not isinstance(generator, dict):
            raise Invalid("render-unsupported")
        for key in ("files", "envs"):
            values = generator.get(key, [])
            if values is None:
                continue
            if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
                raise Invalid("render-unsupported")
            refs.extend(value.split("=", 1)[-1] for value in values)
    return refs


def _kustomization_references(spec: dict[str, Any]) -> list[str]:
    if any(spec.get(field) for field in ("helmCharts", "generators", "transformers")):
        raise Invalid("remote-build-dependency")
    refs = []
    for field in (
        "resources", "components", "bases", "patchesStrategicMerge",
        "crds", "configurations",
    ):
        refs.extend(_reference_list(spec, field))
    json_patches = spec.get("patchesJson6902", [])
    if json_patches is None:
        json_patches = []
    if not isinstance(json_patches, list):
        raise Invalid("render-unsupported")
    for patch in json_patches:
        if not isinstance(patch, dict) or not isinstance(patch.get("path"), str):
            raise Invalid("render-unsupported")
        refs.append(patch["path"])
    patches = spec.get("patches", [])
    if patches is None:
        patches = []
    if not isinstance(patches, list):
        raise Invalid("render-unsupported")
    for patch in patches:
        if isinstance(patch, str):
            refs.append(patch)
        elif isinstance(patch, dict):
            path = patch.get("path")
            if path is not None:
                if not isinstance(path, str):
                    raise Invalid("render-unsupported")
                refs.append(path)
        else:
            raise Invalid("render-unsupported")
    replacements = spec.get("replacements", [])
    if replacements is None:
        replacements = []
    if not isinstance(replacements, list):
        raise Invalid("render-unsupported")
    for replacement in replacements:
        if not isinstance(replacement, dict):
            raise Invalid("render-unsupported")
        path = replacement.get("path")
        if path is not None:
            if not isinstance(path, str):
                raise Invalid("render-unsupported")
            refs.append(path)
    openapi = spec.get("openapi") or {}
    if not isinstance(openapi, dict):
        raise Invalid("render-unsupported")
    if openapi.get("path") is not None:
        if not isinstance(openapi["path"], str):
            raise Invalid("render-unsupported")
        refs.append(openapi["path"])
    refs.extend(_generator_references(spec, "configMapGenerator"))
    refs.extend(_generator_references(spec, "secretGenerator"))
    return refs


def _remote_reference(reference: str) -> bool:
    value = reference.strip()
    return bool(
        REMOTE.match(value)
        or re.search(r"(?:^|/)github\.com/|(?:^|/)gitlab\.com/|(?:^|/)bitbucket\.org/", value)
        or "?ref=" in value
    )


def local_graph_error(directory: Path, repository_root: Path | None = None) -> str | None:
    root = (repository_root or directory).resolve()
    start = directory.resolve()
    if not start.is_relative_to(root):
        return "render-unsupported"
    queue = [start]
    visited: set[Path] = set()
    while queue:
        current = queue.pop()
        try:
            current = current.resolve(strict=True)
        except OSError:
            return "render-unsupported"
        if current in visited:
            continue
        visited.add(current)
        if not current.is_relative_to(root) or not current.is_dir():
            return "render-unsupported"
        candidates = [current / name for name in (
            "kustomization.yaml", "kustomization.yml", "kustomization.json", "Kustomization",
        )
                      if (current / name).is_file()]
        if not candidates:
            continue
        if len(candidates) != 1:
            return "render-unsupported"
        docs = file_documents(candidates[0])
        if len(docs) != 1:
            return "render-unsupported"
        spec = docs[0]
        try:
            refs = _kustomization_references(spec)
        except Invalid as exc:
            return exc.code
        for ref in refs:
            if _remote_reference(ref):
                return "remote-build-dependency"
            try:
                candidate = (current / ref).resolve(strict=True)
            except OSError:
                return "render-unsupported"
            if not candidate.is_relative_to(root):
                return "render-unsupported"
            if candidate.is_dir():
                queue.append(candidate)
            elif not candidate.is_file():
                return "render-unsupported"
    return None


def contains_flux_kustomization(directory: Path) -> bool:
    for path in directory.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".yaml", ".yml"}:
            continue
        try:
            for doc in file_documents(path):
                if (
                    doc.get("kind") == "Kustomization"
                    and str(doc.get("apiVersion", "")).startswith("kustomize.toolkit.fluxcd.io/")
                ):
                    return True
        except Invalid:
            continue
    return False


def input_fingerprint(hr_spec: dict[str, Any], source_spec: dict[str, Any] | None) -> str:
    source = source_spec or {}
    return fingerprint({
        "chartRef": hr_spec.get("chartRef"),
        "values": hr_spec.get("values", {}),
        "source": {"url": source.get("url"), "ref": source.get("ref")},
    })


def normalized_ks_spec(spec: Any) -> Any:
    if not isinstance(spec, dict):
        return spec
    normalized = dict(spec)
    normalized["suspend"] = normalized.get("suspend") is True
    return normalized


def has_unresolved_substitution(value: Any) -> bool:
    if isinstance(value, str):
        return UNRESOLVED_SUBSTITUTION.search(value) is not None
    if isinstance(value, list):
        return any(has_unresolved_substitution(item) for item in value)
    if isinstance(value, dict):
        return any(has_unresolved_substitution(item) for item in value.values())
    return False


def substitution_error(rendered: list[dict[str, Any]], definition: dict[str, Any]) -> str | None:
    spec = definition.get("spec") or {}
    post_build = spec.get("postBuild") or {}
    if not isinstance(post_build, dict):
        return "unsupported-substitution"
    literal = post_build.get("substitute") or {}
    if not isinstance(literal, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in literal.items()
    ):
        return "unsupported-substitution"
    external = post_build.get("substituteFrom") or []
    if not isinstance(external, list) or any(not isinstance(item, dict) for item in external):
        return "unsupported-substitution"

    def check(value: Any) -> bool:
        if isinstance(value, str):
            for match in UNRESOLVED_SUBSTITUTION.finditer(value):
                name = match.group(1)
                if not SUBSTITUTION_NAME.fullmatch(name) or name not in literal:
                    return False
            return True
        if isinstance(value, list):
            return all(check(item) for item in value)
        if isinstance(value, dict):
            return all(check(item) for item in value.values())
        return True

    if any(not check(document) for document in rendered):
        return "unsupported-substitution"
    if any(has_unresolved_substitution(value) for value in literal.values()):
        return "unsupported-substitution"
    return None


def kustomize_build(repo: Path, path: str) -> list[dict[str, Any]]:
    directory = (repo / path.lstrip("./")).resolve()
    if not directory.is_relative_to(repo.resolve()):
        raise Invalid("render-unsupported")
    graph_error = local_graph_error(directory, repo)
    if graph_error:
        raise Invalid(graph_error)
    rendered = command(["kustomize", "build", str(directory)], cwd=repo)
    return yaml_documents(rendered)


def flux_build(repo: Path, name: str, path: str, definition: Path, namespace: str = "flux-system") -> list[dict[str, Any]]:
    directory = (repo / path.lstrip("./")).resolve()
    graph_error = local_graph_error(directory, repo)
    if graph_error:
        raise Invalid(graph_error)
    kustomization_docs = [
        document for document in file_documents(definition)
        if document.get("kind") == "Kustomization"
    ]
    if len(kustomization_docs) != 1:
        raise Invalid("render-unsupported")
    arguments = [
        "flux", "build", "kustomization", name,
        "--path", str(repo / path.lstrip("./")),
        "--kustomization-file", str(definition),
        "--namespace", namespace,
        "--dry-run",
        "--local-sources", f"GitRepository/flux-system/home-kubernetes={repo}",
    ]
    unexpanded_definition = json.loads(json.dumps(kustomization_docs[0]))
    unexpanded_spec = unexpanded_definition.get("spec") or {}
    if not isinstance(unexpanded_spec, dict):
        raise Invalid("render-unsupported")
    unexpanded_spec.pop("postBuild", None)
    with tempfile.TemporaryDirectory(prefix="health-gate-unexpanded-") as directory:
        raw_definition = Path(directory) / "kustomization.json"
        raw_definition.write_text(json.dumps(unexpanded_definition, separators=(",", ":")))
        raw_arguments = list(arguments)
        raw_arguments[raw_arguments.index("--kustomization-file") + 1] = str(raw_definition)
        unexpanded = yaml_documents(command(raw_arguments, cwd=repo))
    substitute_error = substitution_error(unexpanded, kustomization_docs[0])
    if substitute_error:
        raise Invalid(substitute_error, documents=unexpanded)
    rendered = yaml_documents(command(arguments, cwd=repo))
    substitute_error = substitution_error(rendered, kustomization_docs[0])
    if substitute_error:
        raise Invalid(substitute_error)
    return yaml_documents(command([*arguments, "--strict-substitute"], cwd=repo))


def render(repo: Path) -> tuple[list[dict[str, Any]], dict[str, str]]:
    if tool_versions() != VERSIONS:
        raise Invalid("render-tool-version-mismatch")
    for root in (repo / "kubernetes/flux", repo / "kubernetes/apps"):
        if local_graph_error(root, repo):
            raise Invalid("root-render-unsupported")
    try:
        cluster = flux_build(repo, "cluster", "./kubernetes/flux", repo / "kubernetes/flux/config/cluster.yaml")
        apps = flux_build(repo, "cluster-apps", "./kubernetes/apps", repo / "kubernetes/flux/apps.yaml")
    except Invalid as exc:
        raise Invalid("root-render-unsupported") from exc
    docs = cluster + apps
    errors: dict[str, str] = {}
    queue = [doc for doc in docs if doc.get("kind") == "Kustomization"]
    visited: set[tuple[str, str]] = {("flux-system", "cluster"), ("flux-system", "cluster-apps")}
    with tempfile.TemporaryDirectory(prefix="health-gate-render-") as directory:
        temp = Path(directory)
        while queue:
            ks = queue.pop(0)
            ns, name = object_key(ks)
            ident = (ns, name)
            if not name or ident in visited:
                continue
            visited.add(ident)
            spec = ks.get("spec") or {}
            owner = f"{ns}/{name}"
            source_ref = spec.get("sourceRef") or {}
            path = str(spec.get("path", ""))
            leaf = (repo / path.lstrip("./")).resolve()
            intermediate = leaf.is_relative_to(repo.resolve()) and contains_flux_kustomization(leaf)
            if source_ref.get("kind") != "GitRepository" or source_ref.get("name") != "home-kubernetes":
                if intermediate:
                    raise Invalid("root-render-unsupported")
                errors[owner] = "unsupported-source-ref"
                continue
            if not leaf.is_relative_to(repo.resolve()):
                if intermediate:
                    raise Invalid("root-render-unsupported")
                errors[owner] = "remote-build-dependency"
                continue
            unsupported = local_graph_error(leaf, repo)
            if unsupported:
                if intermediate:
                    raise Invalid("root-render-unsupported")
                errors[owner] = "remote-build-dependency"
                continue
            definition = temp / f"{ns}-{name}.yaml"
            definition.write_text(json.dumps(ks, separators=(",", ":")) + "\n")
            try:
                child_docs = flux_build(repo, name, path, definition, ns)
            except Invalid as exc:
                if intermediate:
                    raise Invalid("root-render-unsupported")
                errors[owner] = (
                    "unsupported-substitution"
                    if exc.code == "unsupported-substitution"
                    else "remote-build-dependency"
                )
                if exc.code == "unsupported-substitution":
                    docs.extend(exc.documents)
                    queue.extend(doc for doc in exc.documents if doc.get("kind") == "Kustomization")
                continue
            docs.extend(child_docs)
            queue.extend(doc for doc in child_docs if doc.get("kind") == "Kustomization")
    return docs, errors


def normalized_parent_spec(parent: list[dict[str, Any]], source_ident: tuple[str, str] | None) -> Any:
    if source_ident is None:
        return None
    namespace, name = source_ident
    for obj in parent:
        if obj.get("kind") == "OCIRepository" and object_key(obj) == (namespace, name):
            return obj.get("spec") or {}
    return None


def attest(target: list[dict[str, Any]], parent: list[dict[str, Any]], snapshot: dict[str, Any],
           target_sha: str, parent_sha: str, owner_errors: dict[str, str],
           parent_errors: dict[str, str]) -> dict[str, Any]:
    if not SHA.fullmatch(target_sha) or not SHA.fullmatch(parent_sha):
        raise Invalid("invalid-target-sha")
    before = snapshot.get("before", {})
    after = snapshot.get("after", {})
    superseded = (
        snapshot.get("superseded") is True
        or snapshot.get("main_before") != target_sha
        or snapshot.get("main_after") != target_sha
    )
    live = {name: items(after.get(name)) for name in COLLECTIONS}
    prior = {name: items(before.get(name)) for name in COLLECTIONS}
    target_hr = index(target, "HelmRelease")
    parent_hr = index(parent, "HelmRelease")
    target_oci = index(target, "OCIRepository")
    live_oci = index(live["ocirepositories"], "OCIRepository")
    live_hr = index(live["helmreleases"], "HelmRelease")
    live_ks = index(live["kustomizations"], "Kustomization")
    live_git = index(live["gitrepositories"], "GitRepository")
    expected_ks = index(target, "Kustomization")
    ks_attestations = []
    diagnostics: list[dict[str, str]] = []
    legacy_charts = legacy_chart_diagnostics(target, live)
    for record in legacy_charts:
        for code in record["reason_codes"]:
            kind = "HelmRepository" if code.startswith("helmrepository-") else "HelmChart"
            diagnostics.append({"kind": kind, "namespace": record["namespace"],
                                "name": record["name"], "code": code, "reason": code})
    for ident, desired in sorted(expected_ks.items()):
        ns, name = ident
        current = live_ks.get(ident)
        reason = None
        if owner_errors.get(f"{ns}/{name}"):
            reason = owner_errors[f"{ns}/{name}"]
        elif current is None:
            reason = "kustomization-not-live"
        elif (current.get("metadata") or {}).get("deletionTimestamp"):
            reason = "kustomization-deleting"
        elif canonical(normalized_ks_spec(current.get("spec") or {})) != canonical(
            normalized_ks_spec(desired.get("spec") or {})
        ):
            reason = "kustomization-spec-mismatch"
        elif ((desired.get("spec") or {}).get("sourceRef") or {}).get("kind") != "GitRepository" or (
            ((desired.get("spec") or {}).get("sourceRef") or {}).get("name") != "home-kubernetes"
            or ((desired.get("spec") or {}).get("sourceRef") or {}).get("namespace", ns) != "flux-system"
        ):
            reason = "unsupported-source-ref"
        ks_attestations.append({"namespace": ns, "name": name, "supported": reason is None,
                                "desired_spec_hash": fingerprint(desired.get("spec") or {}),
                                "reason_code": reason or "supported"})
        if reason:
            diagnostics.append({"kind": "Kustomization", "namespace": ns, "name": name, "code": reason, "reason": reason})

    hr_attestations = []
    for ident, desired in sorted(target_hr.items()):
        ns, name = ident
        meta = desired.get("metadata") or {}
        labels = meta.get("labels") or {}
        owner_ns = str(labels.get("kustomize.toolkit.fluxcd.io/namespace", "flux-system"))
        owner_name = str(labels.get("kustomize.toolkit.fluxcd.io/name", ""))
        owner_key = f"{owner_ns}/{owner_name}"
        spec = desired.get("spec") or {}
        reason = None
        if spec.get("valuesFrom"):
            reason = "unsupported-values"
        elif set(spec) - HR_SPEC_FIELDS:
            reason = "unsupported-hr-fields"
        elif has_unresolved_substitution(spec):
            reason = "unsupported-substitution"
        elif spec.get("postRenderers"):
            reason = "unsupported-post-renderer"
        elif spec.get("kubeConfig"):
            reason = "unsupported-kubeconfig"
        elif (spec.get("upgrade") or {}).get("preserveValues") is True:
            reason = "unsupported-preserve-values"
        elif not isinstance(spec.get("values", {}), dict):
            reason = "unsupported-values"
        elif "chartRef" not in spec:
            reason = "unsupported-chart-source"
        previous = parent_hr.get(ident)
        if previous is None:
            reason = reason or "parent-hr-missing"
        if owner_errors.get(owner_key):
            reason = owner_errors[owner_key]
        if parent_errors.get(owner_key):
            reason = reason or "parent-render-unsupported"
        chart = spec.get("chartRef") or {}
        source_ns = str(chart.get("namespace", ns))
        source_ident = (source_ns, str(chart.get("name", ""))) if chart.get("kind") == "OCIRepository" else None
        source_desired = target_oci.get(source_ident) if source_ident else None
        source_live = live_oci.get(source_ident) if source_ident else None
        tag = ""
        full_digest = ""
        if source_ident is None:
            reason = reason or "unsupported-chart-source"
        elif source_desired is None:
            reason = reason or "source-missing-from-render"
        else:
            desired_source_spec = source_desired.get("spec") or {}
            tag = str(((desired_source_spec.get("ref") or {}).get("tag")) or "")
            if not SEMVER.fullmatch(tag):
                reason = reason or "unsupported-source-tag"
            if set(desired_source_spec) - OCI_SPEC_FIELDS:
                reason = reason or "unsupported-source-fields"
            if source_live is None:
                reason = reason or "source-unavailable"
            else:
                source_revision = (((source_live.get("status") or {}).get("artifact") or {}).get("revision")) or ""
                match = OCI_REVISION.fullmatch(str(source_revision))
                if not match or match.group(1) != tag:
                    reason = reason or "source-artifact-mismatch"
                else:
                    full_digest = "sha256:" + match.group(2)
                if canonical(source_live.get("spec") or {}) != canonical(desired_source_spec):
                    reason = reason or "source-spec-mismatch"
                if metadata_fingerprint(source_live) != metadata_fingerprint(source_desired):
                    reason = reason or "source-metadata-mismatch"
        current_hr = live_hr.get(ident)
        if current_hr is None:
            reason = reason or "hr-not-live"
        else:
            current_meta = current_hr.get("metadata") or {}
            if current_meta.get("deletionTimestamp"):
                reason = reason or "hr-deleting"
            elif canonical(current_hr.get("spec") or {}) != canonical(spec):
                reason = reason or "live-spec-mismatch"
            elif metadata_fingerprint(current_hr) != metadata_fingerprint(desired):
                reason = reason or "live-metadata-mismatch"
        parent_source_spec = normalized_parent_spec(parent, source_ident)
        if previous is not None and parent_source_spec is None:
            reason = reason or "parent-source-missing"
        changed = previous is not None and parent_source_spec is not None and input_fingerprint(
            spec, (source_desired or {}).get("spec")) != input_fingerprint(
                previous.get("spec") or {}, parent_source_spec)
        entry = {
            "namespace": ns, "name": name,
            "owner": {"namespace": owner_ns, "name": owner_name},
            "supported": reason is None, "reason_code": reason or "supported",
            "changed_inputs": changed, "desired_spec_hash": fingerprint(spec),
            "source_kind": "OCIRepository" if source_ident else "",
            "source_name": source_ident[1] if source_ident else "",
            "source_namespace": source_ident[0] if source_ident else "",
            "source_tag": tag, "source_digest": full_digest,
        }
        hr_attestations.append(entry)
        if reason:
            diagnostics.append({"kind": "HelmRelease", "namespace": ns, "name": name, "code": reason, "reason": reason})

    target_ids = set(target_hr)
    for ident, live_release in sorted(live_hr.items()):
        if ident in target_ids:
            continue
        ns, name = ident
        labels = (live_release.get("metadata") or {}).get("labels") or {}
        owner_ns = str(labels.get("kustomize.toolkit.fluxcd.io/namespace", "flux-system"))
        owner_name = str(labels.get("kustomize.toolkit.fluxcd.io/name", ""))
        reason = owner_errors.get(f"{owner_ns}/{owner_name}", "not-in-target-render")
        hr_attestations.append({
            "namespace": ns, "name": name,
            "owner": {"namespace": owner_ns, "name": owner_name},
            "supported": False, "reason_code": reason, "changed_inputs": False,
            "desired_spec_hash": "", "source_kind": "", "source_name": "",
            "source_namespace": "", "source_tag": "", "source_digest": "",
        })
        diagnostics.append({"kind": "HelmRelease", "namespace": ns, "name": name,
                            "code": reason, "reason": reason})

    for owner, code in sorted(owner_errors.items()):
        owner_ns, _, owner_name = owner.partition("/")
        diagnostics.append({"kind": "Kustomization", "namespace": owner_ns,
                            "name": owner_name, "code": code, "reason": code})

    stable = True
    for collection in COLLECTIONS:
        old = {object_key(value): value for value in prior[collection]}
        new = {object_key(value): value for value in live[collection]}
        if old.keys() != new.keys():
            stable = False
            break
        for ident, current in new.items():
            old_metadata = old[ident].get("metadata") or {}
            current_metadata = current.get("metadata") or {}
            if any(
                old_metadata.get(field) != current_metadata.get(field)
                for field in ("uid", "resourceVersion")
            ):
                stable = False
                break
        if not stable:
            break
        for ident, value in old.items():
            before_meta = value.get("metadata") or {}
            after_meta = (new[ident].get("metadata") or {})
            if before_meta.get("uid") != after_meta.get("uid") or before_meta.get("resourceVersion") != after_meta.get("resourceVersion"):
                stable = False
                break
        if not stable:
            break
    if not stable:
        diagnostics.append({"kind": "Sample", "namespace": "", "name": "", "code": "resource-changed-during-sample", "reason": "resource-changed-during-sample"})
    if not target_hr:
        diagnostics.append({"kind": "Sample", "namespace": "", "name": "", "code": "empty-desired-set", "reason": "empty-desired-set"})
    if superseded:
        diagnostics.append({"kind": "Main", "namespace": "", "name": "main", "code": "superseded", "reason": "main-advanced-during-sample"})

    def current_failure(resource: dict[str, Any]) -> bool:
        if (resource.get("spec") or {}).get("suspend") is True:
            return False
        metadata = resource.get("metadata") or {}
        status = resource.get("status") or {}
        generation = metadata.get("generation")
        conditions = current_conditions(resource)
        if (
            not isinstance(generation, int)
            or metadata.get("deletionTimestamp")
            or not isinstance(status, dict)
            or status.get("observedGeneration") != generation
            or not conditions
            or any(condition.get("observedGeneration") != generation for condition in conditions)
        ):
            return True
        ready = [condition for condition in conditions if condition.get("type") == "Ready"]
        return (
            len(ready) != 1
            or ready[0].get("status") != "True"
            or any(
                condition.get("type") in {"Reconciling", "Stalled"}
                and condition.get("status") != "False"
                for condition in conditions
            )
            or any(condition.get("status") == "Unknown" for condition in conditions)
        )

    target_revision = f"main@sha1:{target_sha}"
    parent_revision = f"main@sha1:{parent_sha}"
    home_source = live_git.get(("flux-system", "home-kubernetes")) or {}

    def source_is_current(source: dict[str, Any], revision: str) -> bool:
        metadata = source.get("metadata") or {}
        status = source.get("status") or {}
        generation = metadata.get("generation")
        conditions = current_conditions(source)
        if not conditions:
            return False
        ready = [condition for condition in conditions
                 if condition.get("type") == "Ready"]
        return (
            isinstance(generation, int)
            and not metadata.get("deletionTimestamp")
            and (source.get("spec") or {}).get("suspend") is not True
            and status.get("observedGeneration") == generation
            and all(condition.get("observedGeneration") == generation for condition in conditions)
            and len(ready) == 1
            and ready[0].get("status") == "True"
            and ready[0].get("observedGeneration") == generation
            and (((status.get("artifact") or {}).get("revision")) == revision)
        )

    def complete_stable_sample(owner_key: str) -> bool:
        if not stable or not source_is_current(home_source, target_revision):
            return False
        active = [resource for resource in live["kustomizations"]
                  if (resource.get("spec") or {}).get("suspend") is not True]
        active_ids = {object_key(resource) for resource in active}
        if not active or not {("flux-system", "cluster"), ("flux-system", "cluster-apps")} <= active_ids:
            return False
        for resource in active:
            status = resource.get("status") or {}
            metadata = resource.get("metadata") or {}
            generation = metadata.get("generation")
            conditions = current_conditions(resource)
            ready = [condition for condition in conditions or []
                     if condition.get("type") == "Ready"]
            ident = object_key(resource)
            if (
                not isinstance(generation, int)
                or status.get("observedGeneration") != generation
                or status.get("lastAttemptedRevision") != target_revision
                or not conditions
                or any(condition.get("observedGeneration") != generation for condition in conditions)
                or len(ready) != 1
                or ready[0].get("status") not in {"True", "False"}
                or any(condition.get("type") == "Stalled"
                       and condition.get("status") != "False" for condition in conditions)
                or any(condition.get("type") == "Reconciling"
                       and condition.get("status") != "False" for condition in conditions)
                or any(condition.get("status") == "Unknown" for condition in conditions)
            ):
                return False
            applied = status.get("lastAppliedRevision")
            expected_child_failure = (
                "/".join(ident) == owner_key
                and ready[0].get("status") == "False"
                and ready[0].get("reason") == "HealthCheckFailed"
                and not any(condition.get("type") == "Stalled"
                            and condition.get("status") == "True" for condition in conditions)
            )
            if ready[0].get("status") != "True" and not expected_child_failure:
                return False
            if applied != target_revision and not (expected_child_failure and applied == parent_revision):
                return False
        return True

    candidates = []
    for entry in hr_attestations:
        if not entry["supported"] or not entry["changed_inputs"]:
            continue
        ident = (entry["namespace"], entry["name"])
        current = live_hr.get(ident) or {}
        metadata = current.get("metadata") or {}
        status = current.get("status") or {}
        conditions = current_conditions(current)
        if conditions is None:
            continue
        generation = metadata.get("generation")
        ready = [cond for cond in conditions if cond.get("type") == "Ready"]
        stalled = [cond for cond in conditions if cond.get("type") == "Stalled"]
        source = live_oci.get((entry["source_namespace"], entry["source_name"])) or {}
        attempted_chart_revision = entry["source_tag"] + "+" + entry["source_digest"].removeprefix("sha256:")[:12]
        attempt_current = (
            isinstance(generation, int)
            and all(cond.get("observedGeneration") == generation for cond in conditions)
            and status.get("lastAttemptedGeneration") == generation
            and status.get("observedGeneration") == generation
            and status.get("lastAttemptedRevision") == attempted_chart_revision
            and status.get("lastAttemptedRevisionDigest") == entry["source_digest"]
            and source_is_current(source, entry["source_tag"] + "@" + entry["source_digest"])
        )
        terminal = (
            len(ready) == 1 and len(stalled) == 1
            and ready[0].get("status") == "False"
            and ready[0].get("reason") == "RetriesExceeded"
            and ready[0].get("observedGeneration") == generation
            and stalled[0].get("status") == "True"
            and stalled[0].get("observedGeneration") == generation
        )
        owner_key = f"{entry['owner']['namespace']}/{entry['owner']['name']}"
        owner_ident = (entry["owner"]["namespace"], entry["owner"]["name"])
        owner = live_ks.get(owner_ident)
        desired_owner = next(
            (ks for ks in target if ks.get("kind") == "Kustomization" and object_key(ks) == owner_ident),
            None,
        )
        owner_attested = any(
            proof.get("namespace") == owner_ident[0]
            and proof.get("name") == owner_ident[1]
            and proof.get("supported") is True
            for proof in ks_attestations
        )
        inventory_id = f"{ident[0]}_{ident[1]}_helm.toolkit.fluxcd.io_HelmRelease"
        inventory_owners = sum(
            1 for candidate_owner in live["kustomizations"]
            if inventory_id in [
                item.get("id", "")
                for item in (((candidate_owner.get("status") or {}).get("inventory") or {}).get("entries") or [])
                if isinstance(item, dict)
            ]
        )
        ownership_current = (
            owner is not None
            and desired_owner is not None
            and owner_attested
            and (owner.get("spec") or {}).get("suspend") is not True
            and inventory_owners == 1
            and canonical(normalized_ks_spec(owner.get("spec") or {}))
            == canonical(normalized_ks_spec(desired_owner.get("spec") or {}))
        )

        owner_conditions = current_conditions(owner) if owner else None
        owner_conditions = owner_conditions or []
        owner_ready = [condition for condition in owner_conditions
                       if condition.get("type") == "Ready"]
        owner_generation = (owner.get("metadata") or {}).get("generation") if owner else None
        expected_child_health_failure = (
            owner is not None
            and current_conditions(owner) is not None
            and all(condition.get("observedGeneration") == owner_generation for condition in owner_conditions)
            and (owner.get("status") or {}).get("observedGeneration") == owner_generation
            and len(owner_ready) == 1
            and owner_ready[0].get("status") == "False"
            and owner_ready[0].get("reason") == "HealthCheckFailed"
            and owner_ready[0].get("observedGeneration") == owner_generation
            and (owner.get("status") or {}).get("lastAttemptedRevision") == target_revision
            and not any(
                condition.get("type") == "Stalled" and condition.get("status") == "True"
                and condition.get("observedGeneration") == owner_generation
                for condition in owner_conditions if isinstance(condition, dict)
            )
        )
        competing = any(
            current_failure(other)
            for collection in ("kustomizations", "helmreleases", "gitrepositories",
                               "ocirepositories", "helmrepositories", "helmcharts")
            for other in live[collection]
            if not (
                (collection == "helmreleases" and object_key(other) == ident)
                or (collection == "kustomizations" and object_key(other) == owner_ident
                    and expected_child_health_failure)
            )
        )
        checks = {
            "complete_stable_sample": complete_stable_sample(owner_key),
            "not_superseded": not superseded,
            "target_changed_effective_inputs": entry["changed_inputs"],
            "healthy_premerge_baseline_same_hr_uid": False,
            "live_desired_spec_and_source_match": entry["supported"],
            "unique_current_owner_inventory": ownership_current,
            "attempted_generation_and_chart_identity_match": attempt_current,
            "current_terminal_retry_exhaustion": terminal,
            "no_competing_failure": not competing,
            "server_enforced_base_sha_merge_cas": False,
        }
        evidence_established = all(
            value for key, value in checks.items()
            if key not in {"healthy_premerge_baseline_same_hr_uid", "server_enforced_base_sha_merge_cas"}
        )
        if evidence_established:
            # The baseline and merge-CAS prerequisites are fixed failures.
            # No runtime input can make either check true.
            candidates.append({"namespace": entry["namespace"], "name": entry["name"],
                               "owner": entry["owner"], "checks": checks, "authorized": False})
            diagnostics.append({"kind": "HelmRelease", "namespace": entry["namespace"], "name": entry["name"],
                                "code": "baseline-missing", "reason": "rollback-prerequisite-unavailable"})
            diagnostics.append({"kind": "HelmRelease", "namespace": entry["namespace"], "name": entry["name"],
                                "code": "merge-cas-unavailable", "reason": "rollback-prerequisite-unavailable"})

    counts = {"helmreleases_total": len(hr_attestations),
              "helmreleases_supported": sum(1 for entry in hr_attestations if entry["supported"]),
              "helmreleases_unsupported": sum(1 for entry in hr_attestations if not entry["supported"]),
              "reason_codes": {}}
    for entry in hr_attestations:
        code = entry["reason_code"]
        counts["reason_codes"][code] = counts["reason_codes"].get(code, 0) + 1
    source = live_git.get(("flux-system", "home-kubernetes")) or {}
    return {
        "schema_version": 1, "target_sha": target_sha, "parent_sha": parent_sha,
        "sample_valid": stable, "superseded": superseded,
        "root_source": {"present": bool(source), "revision": (((source.get("status") or {}).get("artifact") or {}).get("revision")) or ""},
        "kustomizations": ks_attestations, "helm_releases": hr_attestations,
        "legacy_chart_diagnostics": legacy_charts,
        "candidate_failures": candidates, "diagnostics": diagnostics,
        "counts": counts, "observed": sanitized_observations(live),
    }


def root_failure(snapshot: dict[str, Any], target_sha: str, parent_sha: str) -> dict[str, Any]:
    try:
        after = snapshot.get("after") or {}
        observations = {name: items(after.get(name)) for name in COLLECTIONS}
        hr_list = observations["helmreleases"]
    except Invalid:
        hr_list = []
        observations = {name: [] for name in COLLECTIONS}
    total = len(hr_list)
    return {
        "schema_version": 1, "target_sha": target_sha, "parent_sha": parent_sha,
        "sample_valid": False, "superseded": False,
        "root_source": {"present": False, "revision": ""},
        "kustomizations": [],
        "legacy_chart_diagnostics": [],
        "helm_releases": [
            {"namespace": (hr.get("metadata") or {}).get("namespace", ""),
             "name": (hr.get("metadata") or {}).get("name", ""),
             "owner": {}, "supported": False, "reason_code": "root-render-unsupported",
             "changed_inputs": False, "desired_spec_hash": "", "source_kind": "",
             "source_name": "", "source_namespace": "", "source_tag": "", "source_digest": ""}
            for hr in hr_list
        ],
        "candidate_failures": [],
        "diagnostics": [{"kind": "Root", "namespace": "", "name": "cluster",
                         "code": "root-render-unsupported", "reason": "root-render-unsupported"}],
        "counts": {"helmreleases_total": total, "helmreleases_supported": 0,
                   "helmreleases_unsupported": total, "reason_codes": {"root-render-unsupported": total}},
        "observed": sanitized_observations(observations),
    }


def run_preflight_fixture(path: Path) -> dict[str, Any]:
    fixture = json.loads(path.read_text())
    results = []
    for case in fixture.get("preflight_cases", []):
        with tempfile.TemporaryDirectory(prefix="health-gate-preflight-") as directory:
            root = Path(directory)
            (root / "kustomization.yaml").write_text("resources:\n  - resource.json\n")
            (root / "resource.json").write_text(json.dumps(case["resource"], separators=(",", ":")))
            graph_error = local_graph_error(root, root)
            if graph_error:
                reason = graph_error
            else:
                rendered = kustomize_build(root, ".")
                reason = substitution_error(rendered, case["definition"])
            results.append({"name": case["name"], "reason_code": reason or "supported"})
    for case in fixture.get("graph_cases", []):
        with tempfile.TemporaryDirectory(prefix="health-gate-graph-") as directory:
            root = Path(directory)
            (root / "kustomization.yaml").write_text(
                json.dumps(case["kustomization"], separators=(",", ":"))
            )
            reason = local_graph_error(root, root)
            results.append({"name": case["name"], "reason_code": reason or "supported"})
    production_build_results = []
    for case in fixture.get("production_build_cases", []):
        with tempfile.TemporaryDirectory(prefix="health-gate-build-preflight-") as directory:
            root = Path(directory)
            (root / "kustomization.yaml").write_text(
                json.dumps(case["kustomization"], separators=(",", ":"))
            )
            for filename, resource in case.get("resources", {}).items():
                (root / filename).write_text(json.dumps(resource, separators=(",", ":")))
            definition = root / "flux-kustomization.json"
            definition.write_text(json.dumps(case["definition"], separators=(",", ":")))
            original_command = command
            flux_invocations = []
            flux_substitution_invocations = []
            retained_documents = 0

            def recording_command(argv: list[str], cwd: Path | None = None,
                                  input_text: str | None = None) -> str:
                if argv and argv[0] == "flux":
                    flux_invocations.append(argv)
                    definition_index = argv.index("--kustomization-file") + 1
                    flux_definition = json.loads(Path(argv[definition_index]).read_text())
                    if ((flux_definition.get("spec") or {}).get("postBuild")):
                        flux_substitution_invocations.append(argv)
                    return "\n".join(
                        json.dumps(resource, separators=(",", ":"))
                        for resource in case.get("resources", {}).values()
                    )
                return original_command(argv, cwd=cwd, input_text=input_text)

            globals()["command"] = recording_command
            reason = None
            try:
                flux_build(root, case["name"], ".", definition)
            except Invalid as exc:
                reason = exc.code
                retained_documents = len(exc.documents)
            finally:
                globals()["command"] = original_command
            production_build_results.append({
                "name": case["name"],
                "reason_code": reason or "supported",
                "flux_invoked": bool(flux_invocations),
                "flux_substitution_invoked": bool(flux_substitution_invocations),
                "documents_retained": retained_documents,
            })
    return {"cases": results, "production_build_cases": production_build_results}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-sha", required=True)
    parser.add_argument("--parent-sha", required=True)
    parser.add_argument("--snapshots", type=Path)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--parent-root", type=Path)
    parser.add_argument("--fixture-input", type=Path)
    parser.add_argument("--preflight-fixture", type=Path)
    args = parser.parse_args()
    try:
        if args.preflight_fixture:
            result = run_preflight_fixture(args.preflight_fixture)
        elif args.fixture_input:
            fixture = json.loads(args.fixture_input.read_text())
            result = attest(
                fixture["target_render"],
                fixture["parent_render"],
                fixture["snapshot"],
                args.target_sha,
                args.parent_sha,
                fixture.get("owner_errors", {}),
                fixture.get("parent_owner_errors", {}),
            )
        else:
            if not args.snapshots or not args.repo_root or not args.parent_root:
                raise Invalid("missing-input")
            snapshot = json.loads(args.snapshots.read_text())
            target, target_errors = render(args.repo_root.resolve())
            parent, parent_errors = render(args.parent_root.resolve())
            result = attest(target, parent, snapshot, args.target_sha, args.parent_sha, target_errors, parent_errors)
    except Invalid as exc:
        if exc.code in {"root-render-unsupported", "render-tool-version-mismatch", "render-tool-unavailable", "render-unsupported"}:
            result = root_failure(snapshot if isinstance(locals().get("snapshot"), dict) else {}, args.target_sha, args.parent_sha)
        else:
            print(json.dumps({"schema_version": 1, "sample_valid": False, "superseded": False,
                              "diagnostics": [{"kind": "Sample", "namespace": "", "name": "",
                                               "code": exc.code, "reason": exc.code}],
                              "counts": {"helmreleases_total": 0, "helmreleases_supported": 0,
                                         "helmreleases_unsupported": 0, "reason_codes": {}}},
                             sort_keys=True, separators=(",", ":")))
            return 2
    except Exception:  # sanitized unexpected exception
        print(json.dumps({"schema_version": 1, "sample_valid": False, "superseded": False,
                          "diagnostics": [{"kind": "Sample", "namespace": "", "name": "",
                                           "code": "producer-error", "reason": "producer-error"}],
                          "counts": {"helmreleases_total": 0, "helmreleases_supported": 0,
                                     "helmreleases_unsupported": 0, "reason_codes": {}}},
                         sort_keys=True, separators=(",", ":")))
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
