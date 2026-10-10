#!/usr/bin/env python3
"""Render, resolve exact API egress, then apply to an explicitly selected cluster."""
import importlib.util
from pathlib import Path
import subprocess
import sys

import yaml

spec = importlib.util.spec_from_file_location('api_egress', Path(__file__).with_name('configure-api-egress.py'))
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)
cidrs = api.api_cidrs()
docs = list(yaml.safe_load_all(subprocess.check_output(
    api.kubectl_command() + ['kustomize', sys.argv[1]], text=True)))
api.configure(docs, cidrs)
# Keep rendered Secrets in memory. Only resource names are printed by kubectl.
subprocess.run(api.kubectl_command() + ['apply', '-f', '-'],
               input=yaml.safe_dump_all(docs, sort_keys=False), text=True, check=True)
