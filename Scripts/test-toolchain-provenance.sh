#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
python3 - "$project_dir" "${1:-}" <<'PY'
import hashlib, json, re, shutil, sys, tempfile
from pathlib import Path, PurePosixPath
root = Path(sys.argv[1])
manifest_rel = 'ThirdParty/BUILD-PROVENANCE.json'
def verify(base):
    m = json.loads((base / manifest_rel).read_text())
    files, evidence, tools = m.get('files'), m.get('evidence_files'), m.get('tools')
    if not isinstance(files, dict) or not files or not isinstance(evidence, list) or not evidence:
        raise ValueError('empty files/evidence')
    if not isinstance(tools, dict) or set(tools) != {'sleuthkit-fls', 'sleuthkit-icat', 'sleuthkit-mmls', 'photorec', 'untrunc'}:
        raise ValueError('missing required tools')
    for rel, expected in files.items():
        path = PurePosixPath(rel)
        if path.is_absolute() or '..' in path.parts or not re.fullmatch('[0-9a-f]{64}', expected):
            raise ValueError('invalid file pin: ' + rel)
        if hashlib.sha256((base / rel).read_bytes()).hexdigest() != expected:
            raise ValueError('SHA mismatch: ' + rel)
    def pinned(rel):
        if not isinstance(rel, str) or rel not in files:
            raise ValueError('unhashed or missing reference: ' + str(rel))
    for rel in evidence:
        pinned(rel)
    for name, tool in tools.items():
        pinned(tool.get('binary'))
        pinned(tool.get('build_script'))
        for key in ('sources', 'patches', 'evidence'):
            refs = tool.get(key)
            if not isinstance(refs, list) or not refs:
                raise ValueError(name + ': empty ' + key)
            for ref in refs:
                pinned(ref)
                if key == 'evidence' and ref not in evidence:
                    raise ValueError('undeclared evidence: ' + ref)
    return m
try:
    original = verify(root)
    print('PASS: provenance pins, evidence and recipe references')
    if sys.argv[2] == '--selftest':
        with tempfile.TemporaryDirectory(prefix='recoveryapp-provenance-selftest-') as work:
            copy = Path(work)
            for rel in list(original['files']) + [manifest_rel]:
                target = copy / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / rel, target)
            verify(copy)
            cases = [original['tools']['sleuthkit-fls']['binary'], original['tools']['sleuthkit-fls']['sources'][0], original['evidence_files'][0], original['tools']['untrunc']['build_script']]
            for rel in cases:
                target = copy / rel
                data = target.read_bytes()
                target.write_bytes(data + b'changed')
                try:
                    verify(copy)
                except (ValueError, OSError):
                    print('PASS: rejected tampering ' + rel)
                else:
                    raise ValueError('tampering accepted: ' + rel)
                target.write_bytes(data)
            target = copy / original['evidence_files'][0]
            data = target.read_bytes()
            target.unlink()
            try:
                verify(copy)
            except OSError:
                print('PASS: rejected missing evidence')
            else:
                raise ValueError('missing evidence accepted')
            target.write_bytes(data)
            for mode in ('empty-evidence', 'empty-sources', 'missing-recipe'):
                m = json.loads(json.dumps(original))
                if mode == 'empty-evidence':
                    m['evidence_files'] = []
                elif mode == 'empty-sources':
                    m['tools']['untrunc']['sources'] = []
                else:
                    del m['tools']['untrunc']['build_script']
                (copy / manifest_rel).write_text(json.dumps(m))
                try:
                    verify(copy)
                except ValueError:
                    print('PASS: rejected ' + mode)
                else:
                    raise ValueError('invalid manifest accepted: ' + mode)
    elif sys.argv[2]:
        raise ValueError('unknown argument')
except (ValueError, OSError, KeyError, TypeError) as error:
    sys.exit('FAIL(provenance): ' + str(error))
PY
