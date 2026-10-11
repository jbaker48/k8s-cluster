#!/usr/bin/env python3
"""Classify current Flux failure evidence for Health Gate notifications."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import sys
from typing import Any


RESOURCE_LISTS = (
    "kustomizations",
    "helmreleases",
    "gitrepositories",
    "ocirepositories",
    "helmrepositories",
    "helmcharts",
)
TARGET_REVISION_PREFIX = "main@sha1:"
SOURCE_NAME = "home-kubernetes"
SOURCE_NAMESPACE = "flux-system"
SOURCE_KIND = "GitRepository"
HR_INVENTORY_SUFFIX = "helm.toolkit.fluxcd.io_HelmRelease"
KS_INVENTORY_SUFFIX = "kustomize.toolkit.fluxcd.io_Kustomization"
ROOT_KUSTOMIZATIONS = {
    ("flux-system", "cluster"),
    ("flux-system", "cluster-apps"),
}


class EvidenceError(Exception):
    """A snapshot cannot safely establish notification evidence."""


def read_json(path: pathlib.Path | None, default: Any) -> Any:
    if path is None:
        return default
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"invalid-json:{path.name}") from exc


def positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def resource_key(resource: dict[str, Any]) -> tuple[str, str] | None:
    metadata = resource.get("metadata")
    if not isinstance(metadata, dict):
        return None
    namespace = metadata.get("namespace")
    name = metadata.get("name")
    if not isinstance(namespace, str) or not namespace:
        return None
    if not isinstance(name, str) or not name:
        return None
    return namespace, name


def normalized_path(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    path = value.replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    path = path.strip("/")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return None
    return "/".join(parts)


def path_contains(parent: str, child: str) -> bool:
    return child == parent or child.startswith(parent + "/")


def app_bucket(path: str) -> str | None:
    parts = path.split("/")
    if (len(parts) >= 5 and parts[:2] == ["kubernetes", "apps"]
            and all(parts[index] for index in (2, 3))):
        return "/".join(parts[:4])
    return None


def make_scope(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("scope_error") is True:
        return {"mode": "unavailable", "display": "unavailable", "apps": []}
    paths = raw.get("changed_paths")
    if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
        return {"mode": "unavailable", "display": "unavailable", "apps": []}
    apps: set[str] = set()
    infrastructure = False
    for path in paths:
        if not path.startswith("kubernetes/"):
            continue
        bucket = app_bucket(path)
        if bucket is None:
            infrastructure = True
        else:
            apps.add(bucket)
    if infrastructure:
        return {"mode": "infrastructure-wide", "display": "infrastructure-wide", "apps": []}
    if not apps:
        return {"mode": "empty", "display": "empty", "apps": []}
    ordered = sorted(apps)
    display = "apps:" + ",".join(path.removeprefix("kubernetes/apps/") for path in ordered)
    return {"mode": "apps", "display": display, "apps": ordered}


def items(snapshot: Any, name: str) -> list[dict[str, Any]]:
    if not isinstance(snapshot, dict):
        raise EvidenceError("snapshot-not-object")
    collection = snapshot.get(name)
    if not isinstance(collection, dict) or not isinstance(collection.get("items"), list):
        raise EvidenceError(f"snapshot-list-invalid:{name}")
    values = collection["items"]
    if any(not isinstance(value, dict) for value in values):
        raise EvidenceError(f"snapshot-item-invalid:{name}")
    return values


def index_resources(values: list[dict[str, Any]], kind: str) -> tuple[dict[tuple[str, str], dict[str, Any]], set[tuple[str, str]]]:
    indexed: dict[tuple[str, str], dict[str, Any]] = {}
    duplicates: set[tuple[str, str]] = set()
    for value in values:
        key = resource_key(value)
        if key is None:
            continue
        if key in indexed:
            duplicates.add(key)
        else:
            indexed[key] = value
    if duplicates:
        return indexed, duplicates
    return indexed, set()


def metadata_identity(resource: dict[str, Any]) -> tuple[Any, ...] | None:
    metadata = resource.get("metadata")
    if not isinstance(metadata, dict):
        return None
    uid = metadata.get("uid")
    generation = metadata.get("generation")
    if not isinstance(uid, str) or not uid or not positive_int(generation):
        return None
    return uid, generation


def source_identity(resource: dict[str, Any]) -> tuple[str, str, str] | None:
    spec = resource.get("spec")
    if not isinstance(spec, dict):
        return None
    ref = spec.get("sourceRef")
    if not isinstance(ref, dict):
        return None
    kind = ref.get("kind")
    name = ref.get("name")
    namespace = ref.get("namespace")
    if namespace is None:
        key = resource_key(resource)
        namespace = key[0] if key else None
    if not all(isinstance(value, str) and value for value in (kind, name, namespace)):
        return None
    return kind, namespace, name


def active(resource: dict[str, Any]) -> bool:
    metadata = resource.get("metadata")
    spec = resource.get("spec")
    return (
        isinstance(metadata, dict)
        and not metadata.get("deletionTimestamp")
        and isinstance(spec, dict)
        and spec.get("suspend") is not True
    )


def condition_failure(resource: dict[str, Any]) -> tuple[dict[str, Any] | None, str | None]:
    metadata = resource.get("metadata")
    status = resource.get("status")
    if not isinstance(metadata, dict) or not isinstance(status, dict):
        return None, "status-invalid"
    generation = metadata.get("generation")
    if not positive_int(generation):
        return None, "generation-invalid"
    conditions = status.get("conditions")
    if not isinstance(conditions, list):
        return None, "conditions-invalid"
    relevant: dict[str, list[dict[str, Any]]] = {"Ready": [], "Stalled": []}
    for condition in conditions:
        if not isinstance(condition, dict):
            return None, "condition-invalid"
        condition_type = condition.get("type")
        if not isinstance(condition_type, str) or not condition_type:
            return None, "condition-invalid"
        if condition_type in relevant:
            relevant[condition_type].append(condition)
    for condition_type, matching in relevant.items():
        if len(matching) > 1:
            return None, "condition-ambiguous"
        if not matching:
            continue
        condition = matching[0]
        condition_status = condition.get("status")
        observed_generation = condition.get("observedGeneration")
        if condition_status not in ("True", "False", "Unknown"):
            return None, "condition-invalid"
        if not positive_int(observed_generation):
            return None, "condition-generation-invalid"
        if observed_generation != generation:
            continue
        failed = (condition_type == "Ready" and condition_status == "False") or (
            condition_type == "Stalled" and condition_status == "True"
        )
        if failed:
            reason = condition.get("reason")
            if not isinstance(reason, str):
                reason = ""
            return {
                "condition": condition_type,
                "status": condition_status,
                "reason": reason,
            }, None
    return None, None


def is_target_revision(value: Any, target_sha: str) -> bool:
    return value == TARGET_REVISION_PREFIX + target_sha


def inventory_id(namespace: str, name: str) -> str:
    return f"{namespace}_{name}_{HR_INVENTORY_SUFFIX}"


def inventory_owners_for_id(
    kustomizations: list[dict[str, Any]], wanted: str
) -> list[tuple[str, str]]:
    owners: list[tuple[str, str]] = []
    for kustomization in kustomizations:
        key = resource_key(kustomization)
        status = kustomization.get("status")
        inventory = status.get("inventory") if isinstance(status, dict) else None
        entries = inventory.get("entries") if isinstance(inventory, dict) else None
        if not key or not isinstance(entries, list):
            continue
        if any(isinstance(entry, dict) and entry.get("id") == wanted for entry in entries):
            owners.append(key)
    return sorted(set(owners))


def inventory_owners(kustomizations: list[dict[str, Any]], release_key: tuple[str, str]) -> list[tuple[str, str]]:
    return inventory_owners_for_id(kustomizations, inventory_id(*release_key))


def kustomization_inventory_owners(
    kustomizations: list[dict[str, Any]], child_key: tuple[str, str]
) -> list[tuple[str, str]]:
    wanted = f"{child_key[0]}_{child_key[1]}_{KS_INVENTORY_SUFFIX}"
    return inventory_owners_for_id(kustomizations, wanted)


def resolve_kustomization_owner(
    resource: dict[str, Any], kustomizations: list[dict[str, Any]]
) -> tuple[tuple[str, str] | None, str | None]:
    key = resource_key(resource)
    if key is None:
        return None, "kustomization-identity-invalid"
    metadata = resource.get("metadata")
    labels = metadata.get("labels") if isinstance(metadata, dict) else None
    if labels is None:
        labels = {}
    if not isinstance(labels, dict):
        return None, "kustomization-owner-labels-invalid"
    label_name = labels.get("kustomize.toolkit.fluxcd.io/name")
    label_namespace = labels.get("kustomize.toolkit.fluxcd.io/namespace")
    has_name = label_name is not None
    has_namespace = label_namespace is not None
    listed = kustomization_inventory_owners(kustomizations, key)
    if not has_name and not has_namespace and not listed and key in ROOT_KUSTOMIZATIONS:
        return None, None
    label_owner: tuple[str, str] | None = None
    if has_name and has_namespace:
        if not all(isinstance(value, str) and value for value in (label_name, label_namespace)):
            return None, "kustomization-owner-labels-invalid"
        label_owner = (label_namespace, label_name)
    elif has_name or has_namespace:
        if len(listed) != 1:
            return None, "kustomization-owner-ambiguous" if listed else "kustomization-owner-missing"
        candidate = listed[0]
        if ((has_name and candidate[1] != label_name)
                or (has_namespace and candidate[0] != label_namespace)):
            return None, "kustomization-owner-conflict"
        label_owner = candidate
    elif len(listed) == 1:
        label_owner = listed[0]
    elif len(listed) > 1:
        return None, "kustomization-owner-ambiguous"
    else:
        return None, "kustomization-owner-missing"
    if label_owner not in {resource_key(item) for item in kustomizations}:
        return None, "kustomization-owner-missing"
    if listed and (len(listed) != 1 or listed[0] != label_owner):
        return None, "kustomization-owner-conflict"
    return label_owner, None


def resolve_owner(release: dict[str, Any], kustomizations: list[dict[str, Any]]) -> tuple[tuple[str, str] | None, str | None]:
    release_key = resource_key(release)
    if release_key is None:
        return None, "helmrelease-identity-invalid"
    labels = (release.get("metadata") or {}).get("labels") or {}
    if not isinstance(labels, dict):
        return None, "helmrelease-owner-labels-invalid"
    label_name = labels.get("kustomize.toolkit.fluxcd.io/name")
    label_namespace = labels.get("kustomize.toolkit.fluxcd.io/namespace")
    has_name = label_name is not None
    has_namespace = label_namespace is not None
    listed = inventory_owners(kustomizations, release_key)
    label_owner: tuple[str, str] | None = None
    if has_name and has_namespace:
        if not all(isinstance(value, str) and value for value in (label_name, label_namespace)):
            return None, "helmrelease-owner-labels-invalid"
        label_owner = (label_namespace, label_name)
    elif has_name or has_namespace:
        if len(listed) == 1:
            candidate = listed[0]
            if ((has_name and candidate[1] != label_name)
                    or (has_namespace and candidate[0] != label_namespace)):
                return None, "helmrelease-owner-conflict"
            label_owner = candidate
        else:
            return None, "helmrelease-owner-ambiguous" if len(listed) > 1 else "helmrelease-owner-missing"
    elif len(listed) == 1:
        label_owner = listed[0]
    elif len(listed) > 1:
        return None, "helmrelease-owner-ambiguous"
    else:
        return None, "helmrelease-owner-missing"
    if label_owner not in {resource_key(ks) for ks in kustomizations}:
        return None, "helmrelease-owner-missing"
    if listed and (len(listed) != 1 or listed[0] != label_owner):
        return None, "helmrelease-owner-conflict"
    return label_owner, None


def candidate_signature(resource: dict[str, Any], kind: str) -> tuple[Any, ...] | None:
    metadata = resource.get("metadata")
    if not isinstance(metadata, dict):
        return None
    identity = metadata_identity(resource)
    if identity is None:
        return None
    spec = resource.get("spec")
    if not isinstance(spec, dict):
        return None
    signature: list[Any] = [identity, metadata.get("deletionTimestamp"), spec.get("suspend") is True]
    if kind == "Kustomization":
        path = normalized_path((spec.get("path") or ""))
        source = source_identity(resource)
        if path is None or source is None:
            return None
        signature.extend((path, source))
    else:
        labels = metadata.get("labels") or {}
        if not isinstance(labels, dict):
            return None
        signature.append((
            labels.get("kustomize.toolkit.fluxcd.io/name"),
            labels.get("kustomize.toolkit.fluxcd.io/namespace"),
        ))
    return tuple(signature)


def safe_reason(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", value)[:128]


def describe_failure(
    resource: dict[str, Any],
    kind: str,
    condition: dict[str, Any],
    target_sha: str,
    owner: tuple[str, str] | None,
    observation_time: str,
    ks_target_revision: str,
) -> dict[str, Any]:
    namespace, name = resource_key(resource) or ("", "")
    metadata = resource.get("metadata") or {}
    return {
        "kind": kind,
        "namespace": namespace,
        "name": name,
        "uid": metadata.get("uid"),
        "generation": metadata.get("generation"),
        "condition": condition["condition"],
        "status": condition["status"],
        "reason": safe_reason(condition["reason"]),
        "ks_target_revision": ks_target_revision,
        "owner_identity": (
            f"{owner[0]}/{owner[1]}" if owner else f"{SOURCE_KIND} {SOURCE_NAMESPACE}/{SOURCE_NAME}"
        ),
        "observation_time": observation_time,
        "target_sha": target_sha,
    }


def scope_kustomizations(
    all_kustomizations: list[dict[str, Any]], scope: dict[str, Any]
) -> tuple[list[dict[str, Any]], set[tuple[str, str]]]:
    repository: list[dict[str, Any]] = []
    for resource in all_kustomizations:
        if source_identity(resource) == (SOURCE_KIND, SOURCE_NAMESPACE, SOURCE_NAME):
            repository.append(resource)
    if scope["mode"] == "infrastructure-wide":
        return repository, {key for item in repository if (key := resource_key(item))}
    if scope["mode"] != "apps":
        return [], set()
    apps = scope["apps"]
    selected: set[tuple[str, str]] = set()
    for resource in repository:
        path = normalized_path((resource.get("spec") or {}).get("path"))
        if path is None:
            continue
        if any(path_contains(app, path) for app in apps):
            key = resource_key(resource)
            if key:
                selected.add(key)
    return repository, selected


def clear_state(scope: dict[str, Any], evidence: str, diagnostic: str | None = None) -> dict[str, Any]:
    diagnostics = [diagnostic] if diagnostic else []
    return {
        "flux_unhealthy": False,
        "flux_unhealthy_objects": [],
        "flux_notification_evidence": evidence,
        "flux_notification_scope": scope["display"],
        "evidence_time": "",
        "diagnostics": diagnostics,
    }


def evaluate(
    snapshots: Any,
    target_sha: str,
    scope_input: Any,
    previous: Any,
    observation_time: str,
    observation_error: bool = False,
) -> dict[str, Any]:
    scope = make_scope(scope_input)
    if scope["mode"] == "unavailable":
        result = clear_state(scope, "unavailable", "notification-scope-unavailable")
        previous_objects = previous.get("flux_unhealthy_objects", []) if isinstance(previous, dict) else []
        if isinstance(previous_objects, list):
            result["flux_unhealthy_objects"] = previous_objects
            result["flux_unhealthy"] = bool(previous_objects)
            result["flux_notification_evidence"] = "partial" if previous_objects else "unavailable"
            result["evidence_time"] = previous.get("evidence_time", "") if isinstance(previous, dict) else ""
        return result
    prior_objects = previous.get("flux_unhealthy_objects", []) if isinstance(previous, dict) else []
    if not isinstance(prior_objects, list):
        prior_objects = []
    if observation_error:
        result = clear_state(scope, "partial" if prior_objects else "unavailable", "notification-observation-unavailable")
        result["flux_unhealthy_objects"] = prior_objects
        result["flux_unhealthy"] = bool(prior_objects)
        result["evidence_time"] = previous.get("evidence_time", "") if isinstance(previous, dict) else ""
        return result
    if not isinstance(snapshots, dict):
        result = clear_state(scope, "partial" if prior_objects else "unavailable", "notification-snapshots-unavailable")
        result["flux_unhealthy_objects"] = prior_objects
        result["flux_unhealthy"] = bool(prior_objects)
        result["evidence_time"] = previous.get("evidence_time", "") if isinstance(previous, dict) else ""
        return result
    main_before = snapshots.get("main_before")
    main_after = snapshots.get("main_after")
    if snapshots.get("superseded") is True or main_before not in (None, target_sha) or main_after not in (None, target_sha):
        return clear_state(scope, "superseded", "main-revision-superseded")
    if main_before != target_sha or main_after != target_sha:
        result = clear_state(scope, "partial" if prior_objects else "unavailable", "notification-main-evidence-unavailable")
        result["flux_unhealthy_objects"] = prior_objects
        result["flux_unhealthy"] = bool(prior_objects)
        result["evidence_time"] = previous.get("evidence_time", "") if isinstance(previous, dict) else ""
        return result

    try:
        before = snapshots.get("before")
        after = snapshots.get("after")
        before_lists = {name: items(before, name) for name in RESOURCE_LISTS}
        after_lists = {name: items(after, name) for name in RESOURCE_LISTS}
    except EvidenceError as exc:
        result = clear_state(scope, "partial" if prior_objects else "unavailable", str(exc))
        result["flux_unhealthy_objects"] = prior_objects
        result["flux_unhealthy"] = bool(prior_objects)
        result["evidence_time"] = previous.get("evidence_time", "") if isinstance(previous, dict) else ""
        return result

    before_indexes: dict[str, dict[tuple[str, str], dict[str, Any]]] = {}
    after_indexes: dict[str, dict[tuple[str, str], dict[str, Any]]] = {}
    diagnostics: set[str] = set()
    duplicate_keys: set[tuple[str, str, str]] = set()
    for collection, values in before_lists.items():
        indexed, duplicate = index_resources(values, collection)
        before_indexes[collection] = indexed
        duplicate_keys.update((collection, *key) for key in duplicate)
    for collection, values in after_lists.items():
        indexed, duplicate = index_resources(values, collection)
        after_indexes[collection] = indexed
        duplicate_keys.update((collection, *key) for key in duplicate)
    if duplicate_keys:
        diagnostics.add("notification-identity-ambiguous")

    after_ks = after_indexes["kustomizations"]
    before_ks = before_indexes["kustomizations"]
    repository_ks, direct_ks_keys = scope_kustomizations(
        after_lists["kustomizations"], scope
    )
    selected_ks_keys = set(direct_ks_keys)
    if scope["mode"] == "unavailable":
        diagnostics.add("notification-scope-unavailable")

    ks_owner_map: dict[tuple[str, str], tuple[str, str] | None] = {}
    ks_owner_errors: set[tuple[str, str]] = set()
    pending_ks = list(sorted(direct_ks_keys))
    while pending_ks:
        key = pending_ks.pop()
        if key in ks_owner_map or key in ks_owner_errors:
            continue
        after_resource = after_ks.get(key)
        before_resource = before_ks.get(key)
        if after_resource is None or before_resource is None:
            diagnostics.add("notification-owner-chain-unavailable")
            ks_owner_errors.add(key)
            continue
        owner, owner_problem = resolve_kustomization_owner(
            after_resource, after_lists["kustomizations"]
        )
        before_owner, before_owner_problem = resolve_kustomization_owner(
            before_resource, before_lists["kustomizations"]
        )
        if owner_problem or before_owner_problem or owner != before_owner:
            problem = owner_problem or before_owner_problem or "owner-changed-across-pair"
            diagnostics.add("notification-" + problem)
            ks_owner_errors.add(key)
            continue
        ks_owner_map[key] = owner
        if owner is None:
            continue
        parent = after_ks.get(owner)
        if parent is None:
            diagnostics.add("notification-kustomization-owner-missing")
            ks_owner_errors.add(key)
            continue
        if source_identity(parent) != (SOURCE_KIND, SOURCE_NAMESPACE, SOURCE_NAME):
            diagnostics.add("notification-kustomization-owner-source-invalid")
            ks_owner_errors.add(key)
            continue
        selected_ks_keys.add(owner)
        pending_ks.append(owner)

    source_key = (SOURCE_NAMESPACE, SOURCE_NAME)
    source_before = before_indexes["gitrepositories"].get(source_key)
    source_after = after_indexes["gitrepositories"].get(source_key)
    if scope["mode"] != "empty" and selected_ks_keys:
        if (source_before is None or source_after is None
                or metadata_identity(source_before) is None
                or metadata_identity(source_before) != metadata_identity(source_after)):
            diagnostics.add("notification-source-identity-unavailable")
    source_valid = (
        scope["mode"] == "empty"
        or not selected_ks_keys
        or (source_before is not None and source_after is not None
            and metadata_identity(source_before) is not None
            and metadata_identity(source_before) == metadata_identity(source_after)
            and active(source_after))
    )

    # An eligible object must have a stable, active owner chain.
    active_chain_ok: dict[tuple[str, str], bool] = {}
    for key in selected_ks_keys:
        chain_ok = True
        seen: set[tuple[str, str]] = set()
        current = key
        while True:
            if current in seen or current in ks_owner_errors:
                chain_ok = False
                break
            seen.add(current)
            owner = ks_owner_map.get(current)
            if owner is None:
                break
            parent = after_ks.get(owner)
            if owner not in selected_ks_keys or parent is None or not active(parent):
                chain_ok = False
                break
            current = owner
        active_chain_ok[key] = chain_ok

    current_failures: dict[tuple[str, str, str, str, int], dict[str, Any]] = {}
    invalid_candidates: set[tuple[str, str, str]] = set()
    resolved_candidates: set[tuple[str, str, str]] = set()

    def stable_resource(collection: str, kind: str, key: tuple[str, str]) -> dict[str, Any] | None:
        before_resource = before_indexes[collection].get(key)
        after_resource = after_indexes[collection].get(key)
        if before_resource is None or after_resource is None:
            diagnostics.add("notification-candidate-missing-from-pair")
            invalid_candidates.add((kind, *key))
            return None
        if (key in {item[1:] for item in duplicate_keys if item[0] == collection}
                or candidate_signature(before_resource, kind) is None
                or candidate_signature(before_resource, kind) != candidate_signature(after_resource, kind)):
            diagnostics.add("notification-candidate-identity-changed")
            invalid_candidates.add((kind, *key))
            return None
        return after_resource

    scoped_ks: dict[tuple[str, str], dict[str, Any]] = {}
    if scope["mode"] != "empty":
        for key in sorted(selected_ks_keys):
            resource = stable_resource("kustomizations", "Kustomization", key)
            if resource is None:
                continue
            scoped_ks[key] = resource

        for key in sorted(selected_ks_keys):
            resource = scoped_ks.get(key)
            if resource is None:
                continue
            if key in ks_owner_errors:
                invalid_candidates.add(("Kustomization", *key))
                continue
            if not source_valid:
                invalid_candidates.add(("Kustomization", *key))
                continue
            if not active(resource) or not active_chain_ok.get(key, True):
                resolved_candidates.add(("Kustomization", *key))
                continue
            identity = metadata_identity(resource)
            if identity is None:
                diagnostics.add("notification-kustomization-identity-invalid")
                invalid_candidates.add(("Kustomization", *key))
                continue
            status = resource.get("status")
            if not isinstance(status, dict):
                diagnostics.add("notification-kustomization-status-invalid")
                invalid_candidates.add(("Kustomization", *key))
                continue
            if not is_target_revision(status.get("lastAttemptedRevision"), target_sha):
                resolved_candidates.add(("Kustomization", *key))
                continue
            failure, problem = condition_failure(resource)
            if problem:
                diagnostics.add("notification-" + problem)
                invalid_candidates.add(("Kustomization", *key))
                continue
            resolved_candidates.add(("Kustomization", *key))
            if failure:
                nearest_owner = ks_owner_map.get(key)
                obj = describe_failure(
                    resource, "Kustomization", failure, target_sha,
                    nearest_owner, observation_time,
                    str(status.get("lastAttemptedRevision", "")),
                )
                identity_key = ("Kustomization", *key, identity[0], identity[1])
                current_failures[identity_key] = obj

    all_ks = after_lists["kustomizations"]
    before_ks_resources = before_lists["kustomizations"]
    after_hrs = after_indexes["helmreleases"]
    for key in sorted(after_hrs):
        if scope["mode"] == "empty":
            break
        release = after_hrs[key]
        owner, owner_problem = resolve_owner(release, all_ks)
        if owner_problem:
            # An unknown owner is diagnostic; it is never used to infer scope.
            diagnostics.add("notification-" + owner_problem)
            diagnostics.add("notification-evidence-unavailable")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        if owner not in selected_ks_keys:
            continue
        stable = stable_resource("helmreleases", "HelmRelease", key)
        if stable is None:
            continue
        before_release = before_indexes["helmreleases"].get(key)
        if before_release is None:
            diagnostics.add("notification-candidate-missing-from-pair")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        before_owner, before_owner_problem = resolve_owner(before_release, before_ks_resources)
        if before_owner_problem or before_owner != owner:
            diagnostics.add("notification-owner-changed-across-pair")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        scoped_owner = scoped_ks.get(owner)
        if scoped_owner is None:
            diagnostics.add("notification-owner-not-in-pair")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        if not source_valid:
            diagnostics.add("notification-source-identity-unavailable")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        owner_stable = stable_resource("kustomizations", "Kustomization", owner)
        if owner_stable is None:
            invalid_candidates.add(("HelmRelease", *key))
            continue
        if not active(stable) or not active(scoped_owner) or not active_chain_ok.get(owner, True):
            resolved_candidates.add(("HelmRelease", *key))
            continue
        release_identity = metadata_identity(stable)
        if release_identity is None:
            diagnostics.add("notification-helmrelease-identity-invalid")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        owner_status = scoped_owner.get("status")
        release_status = stable.get("status")
        if not isinstance(owner_status, dict) or not isinstance(release_status, dict):
            diagnostics.add("notification-helmrelease-status-invalid")
            invalid_candidates.add(("HelmRelease", *key))
            continue
        if not (is_target_revision(owner_status.get("lastAttemptedRevision"), target_sha)
                and is_target_revision(owner_status.get("lastAppliedRevision"), target_sha)):
            resolved_candidates.add(("HelmRelease", *key))
            continue
        failure, problem = condition_failure(stable)
        attempted_generation = release_status.get("lastAttemptedGeneration")
        observed_generation = release_status.get("observedGeneration")
        if problem:
            diagnostics.add("notification-" + problem)
            invalid_candidates.add(("HelmRelease", *key))
            continue
        resolved_candidates.add(("HelmRelease", *key))
        if failure:
            generation = release_identity[1]
            if attempted_generation != generation and observed_generation != generation:
                continue
            obj = describe_failure(
                stable, "HelmRelease", failure, target_sha, owner,
                observation_time,
                str(owner_status.get("lastAttemptedRevision", "")),
            )
            identity_key = ("HelmRelease", *key, release_identity[0], release_identity[1])
            current_failures[identity_key] = obj

    # A valid non-failing observation clears prior failures. Partial observations
    # retain old evidence only for candidates whose current state was unresolved.
    previous_by_name: dict[tuple[str, str, str], dict[str, Any]] = {}
    for item in prior_objects:
        if not isinstance(item, dict):
            continue
        kind, namespace, name = item.get("kind"), item.get("namespace"), item.get("name")
        if all(isinstance(value, str) and value for value in (kind, namespace, name)):
            previous_by_name[(kind, namespace, name)] = item
    partial = bool(diagnostics)
    retained: dict[tuple[str, str, str, str, int], dict[str, Any]] = dict(current_failures)
    if partial:
        for object_name, item in previous_by_name.items():
            if object_name in invalid_candidates:
                old_identity = (item.get("uid"), item.get("generation"))
                current = after_indexes.get(
                    "kustomizations" if object_name[0] == "Kustomization" else "helmreleases", {}
                ).get((object_name[1], object_name[2]))
                current_identity = metadata_identity(current) if current else None
                if current_identity and current_identity != old_identity:
                    continue
                retained[(object_name[0], object_name[1], object_name[2], str(item.get("uid", "")), int(item.get("generation", 0)))] = item
            elif object_name not in resolved_candidates and object_name not in {
                (key[0], key[1], key[2]) for key in current_failures
            }:
                # A parser/read gap unrelated to this previously failing object
                # does not manufacture recovery evidence.
                current = after_indexes.get(
                    "kustomizations" if object_name[0] == "Kustomization" else "helmreleases", {}
                ).get((object_name[1], object_name[2]))
                current_identity = metadata_identity(current) if current else None
                old_identity = (item.get("uid"), item.get("generation"))
                if current is None or (current_identity and current_identity != old_identity):
                    continue
                retained[(object_name[0], object_name[1], object_name[2], str(item.get("uid", "")), int(item.get("generation", 0)))] = item

    objects = sorted(
        retained.values(),
        key=lambda item: (
            item.get("kind", ""), item.get("namespace", ""),
            item.get("name", ""), item.get("uid", ""), item.get("generation", 0),
        ),
    )
    if invalid_candidates:
        diagnostics.add("notification-evidence-unavailable")
    evidence = "partial" if partial else "valid"
    evidence_time = max(
        (item.get("observation_time", "") for item in objects if isinstance(item.get("observation_time"), str)),
        default="",
    )
    return {
        "flux_unhealthy": bool(objects),
        "flux_unhealthy_objects": objects,
        "flux_notification_evidence": evidence,
        "flux_notification_scope": scope["display"],
        "evidence_time": evidence_time,
        "diagnostics": sorted(diagnostics),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshots", type=pathlib.Path)
    parser.add_argument("--target-sha", required=True)
    parser.add_argument("--scope", type=pathlib.Path, required=True)
    parser.add_argument("--previous", type=pathlib.Path)
    parser.add_argument("--observed-at", default="")
    parser.add_argument("--observation-error", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.target_sha):
        parser.error("--target-sha must be a full lowercase commit SHA")
    observation_time = args.observed_at
    if not observation_time:
        observation_time = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    try:
        scope_input = read_json(args.scope, {})
        previous = read_json(args.previous, {})
        snapshots = read_json(args.snapshots, None) if args.snapshots else None
        result = evaluate(
            snapshots, args.target_sha, scope_input, previous,
            observation_time, args.observation_error,
        )
    except EvidenceError as exc:
        scope_input = {}
        try:
            scope_input = read_json(args.scope, {})
            previous = read_json(args.previous, {})
        except EvidenceError:
            previous = {}
        result = clear_state(make_scope(scope_input), "partial" if previous.get("flux_unhealthy_objects") else "unavailable", str(exc))
        result["flux_unhealthy_objects"] = previous.get("flux_unhealthy_objects", [])
        result["flux_unhealthy"] = bool(result["flux_unhealthy_objects"])
        result["evidence_time"] = previous.get("evidence_time", "")
    json.dump(result, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
