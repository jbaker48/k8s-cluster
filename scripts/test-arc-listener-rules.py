#!/usr/bin/env python3
"""Check and test the deployed ARC PrometheusRule (requires PyYAML and promtool)."""

from pathlib import Path
import subprocess
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]
RULE = ROOT / "kubernetes/apps/arc-systems/actions-runner-controller/app/prometheusrule.yaml"
TEST = ROOT / "scripts/tests/arc-listener-rules.test.yaml"


def main():
    with tempfile.TemporaryDirectory(prefix="arc-listener-rules-") as directory:
        directory = Path(directory)
        rule = directory / "rules.yaml"
        rule.write_text(yaml.safe_dump(yaml.safe_load(RULE.read_text())["spec"]))
        test = directory / "test.yaml"
        test.write_text(TEST.read_text())
        for command in (["check", "rules", str(rule)], ["test", "rules", str(test)]):
            subprocess.run(["promtool", *command], check=True, cwd=directory)


if __name__ == "__main__":
    main()
