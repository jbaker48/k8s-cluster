#!/usr/bin/env python3
"""
Migrate bjw-s app-template HelmReleases to use OCIRepository pattern
Aligns with onedr0p/cluster-template standards
"""

import os
import sys
from pathlib import Path
import re

# Configuration
APPS_DIR = Path("/Users/jbaker/git/k8s-cluster/kubernetes/apps")
APP_TEMPLATE_VERSION = "4.4.0"
OCI_URL = "oci://ghcr.io/bjw-s-labs/helm/app-template"

# Apps to migrate (excluding emhass which is already done)
APPS_TO_MIGRATE = [
    "ai/litellm/app",
    "ai/ollama/app",
    "ai/openwebui/app",
    "database/dragonfly/app",
    "home/evcc/app",
    "home/frigate/app",
    "home/home-assistant/app",
    "home/mosquitto/app",
    "home/tesla-proxy/app",
    "home/teslamate/app",
    "media/bazarr/app",
    "media/lidarr/app",
    "media/overseerr/app",
    "media/photoprism/app",
    "media/plex/app",
    "media/prowlarr/app",
    "media/radarr/app",
    "media/recyclarr/app",
    "media/sabnzbd/app",
    "media/sonarr/app",
    "network/cloudflared/app",
    "network/unifi/app",
    "observability/speedtest-exporter/app",
    "observability/unpoller/app",
    "selfhosted/actual/app",
    "tools/generic-device-plugin/app",
]

def get_app_info(app_path):
    """Extract app name and namespace from path"""
    parts = app_path.split("/")
    namespace = parts[0]
    app_name = parts[1]
    return namespace, app_name

def create_ocirepository(app_dir, namespace, app_name):
    """Create OCIRepository resource"""
    oci_content = f"""---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: {app_name}
  namespace: {namespace}
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: {APP_TEMPLATE_VERSION}
  url: {OCI_URL}
"""

    oci_file = app_dir / "ocirepository.yaml"
    oci_file.write_text(oci_content)
    print(f"  ✅ Created {oci_file}")

def update_helmrelease(app_dir, app_name):
    """Update HelmRelease to use chartRef"""
    hr_file = app_dir / "helmrelease.yaml"

    if not hr_file.exists():
        print(f"  ⚠️  HelmRelease not found at {hr_file}")
        return False

    content = hr_file.read_text()

    # Pattern to match the old chart spec
    old_pattern = re.compile(
        r'spec:\n'
        r'  interval: \d+m\n'
        r'  chart:\n'
        r'    spec:\n'
        r'      chart: app-template\n'
        r'      version: [\d.]+\n'
        r'      sourceRef:\n'
        r'        kind: HelmRepository\n'
        r'        name: bjw-s\n'
        r'        namespace: flux-system\n',
        re.MULTILINE
    )

    # New chartRef pattern
    new_spec = f"""spec:
  chartRef:
    kind: OCIRepository
    name: {app_name}
  interval: 1h
"""

    if old_pattern.search(content):
        updated_content = old_pattern.sub(new_spec, content)
        hr_file.write_text(updated_content)
        print(f"  ✅ Updated {hr_file}")
        return True
    else:
        print(f"  ⚠️  Pattern not found in {hr_file}, may already be migrated")
        return False

def update_kustomization(app_dir):
    """Add ocirepository.yaml to kustomization resources"""
    kust_file = app_dir / "kustomization.yaml"

    if not kust_file.exists():
        print(f"  ⚠️  Kustomization not found at {kust_file}")
        return False

    content = kust_file.read_text()

    # Check if ocirepository.yaml is already in resources
    if "./ocirepository.yaml" in content:
        print(f"  ℹ️  ocirepository.yaml already in {kust_file}")
        return True

    # Find the resources section and add ocirepository.yaml
    # Look for helmrelease.yaml and add ocirepository.yaml after it
    pattern = re.compile(r'(  - \./helmrelease\.yaml)\n', re.MULTILINE)

    if pattern.search(content):
        updated_content = pattern.sub(r'\1\n  - ./ocirepository.yaml\n', content)
        kust_file.write_text(updated_content)
        print(f"  ✅ Updated {kust_file}")
        return True
    else:
        print(f"  ⚠️  Could not find helmrelease.yaml in resources of {kust_file}")
        return False

def migrate_app(app_path):
    """Migrate a single app"""
    namespace, app_name = get_app_info(app_path)
    app_dir = APPS_DIR / app_path

    print(f"\n📦 Migrating {namespace}/{app_name}")

    if not app_dir.exists():
        print(f"  ❌ Directory not found: {app_dir}")
        return False

    # Step 1: Create OCIRepository
    create_ocirepository(app_dir, namespace, app_name)

    # Step 2: Update HelmRelease
    update_helmrelease(app_dir, app_name)

    # Step 3: Update Kustomization
    update_kustomization(app_dir)

    return True

def main():
    """Main migration function"""
    print("=" * 70)
    print("🚀 BJW-S App-Template Migration to OCIRepository Pattern")
    print(f"   Target Version: {APP_TEMPLATE_VERSION}")
    print(f"   Total Apps: {len(APPS_TO_MIGRATE)}")
    print("=" * 70)

    success_count = 0
    failed_count = 0

    for app_path in APPS_TO_MIGRATE:
        try:
            if migrate_app(app_path):
                success_count += 1
            else:
                failed_count += 1
        except Exception as e:
            print(f"  ❌ Error migrating {app_path}: {e}")
            failed_count += 1

    print("\n" + "=" * 70)
    print(f"✅ Successfully migrated: {success_count}")
    print(f"❌ Failed: {failed_count}")
    print("=" * 70)

    if failed_count > 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
