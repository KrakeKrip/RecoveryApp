#!/usr/bin/env python3
"""Explicit maintenance command after a reviewed build, not a verification step."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--unsigned-untrunc', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
manifest = root / 'ThirdParty/BUILD-PROVENANCE.json'
data = json.loads(manifest.read_text())
evidence = sorted(str(p.relative_to(root)) for p in (root / 'docs/build-evidence/TASK-016').iterdir() if p.is_file())
data['evidence_files'] = evidence
for rel in evidence:
    path = root / rel
    normalized = '\n'.join(line.rstrip(' \t') for line in path.read_text().splitlines()).rstrip('\n') + '\n'
    path.write_text(normalized)
recipes = {tool['build_script'] for tool in data['tools'].values()}
recipes.update(('Scripts/verify-ffmpeg-config.py', 'Scripts/test-toolchain-provenance.sh',
                'Scripts/finalize-toolchain-provenance.py'))
for rel in sorted(set(data['files']) | set(evidence) | recipes):
    data['files'][rel] = hashlib.sha256((root / rel).read_bytes()).hexdigest()
data['tools']['untrunc']['sha256_unsigned_build'] = args.unsigned_untrunc
data['tools']['untrunc']['build_command'] = 'make untrunc-81 IS_RELEASE=1 FF_CONFIG_FLAGS=<explicit flags in Scripts/build-untrunc.sh; includes --disable-autodetect --disable-sdl2>'
data['evidence_normalization'] = 'Trailing spaces and final empty lines removed; values and commands unchanged. Make log retains configure summary and actual link command.'
data['verification_helpers'] = sorted(recipes)
manifest.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
