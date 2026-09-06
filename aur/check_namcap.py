"""Retain namcap diagnostics and narrowly review prebuilt Electron placement."""
import json
from pathlib import Path
import sys

evidence = Path(sys.argv[1])
audit = json.loads((evidence / 'DEB-PAYLOAD-AUDIT.json').read_text())
if len(audit['elf']) != 8 or not all(name.startswith('opt/Hidden Tunes Desktop/') for name in audit['elf']):
    raise SystemExit('Unexpected ELF inventory; the placement review does not apply.')
expected = "hiddentunes E: ELF files outside of a valid path ('opt/')."
errors = []
warnings = []
reviewed = []
for filename in ('namcap-PKGBUILD.txt', 'namcap-package.txt'):
    for line in (evidence / filename).read_text().splitlines():
        if ' E:' in line:
            if filename == 'namcap-package.txt' and line == expected and not reviewed:
                reviewed.append(line)
            else:
                errors.append({'file': filename, 'message': line})
        elif ' W:' in line:
            warnings.append({'file': filename, 'message': line})
result = {
    'status': 'FAIL' if errors else 'PASS with documented opt/ placement exception' if reviewed else 'PASS',
    'unresolvedErrors': errors,
    'reviewedDiagnostic': reviewed,
    'reason': 'The original prebuilt Electron distribution remains intact under /opt/Hidden Tunes Desktop, as directed for bundled Electron distributions by the Arch Electron package guidelines. All eight original ELF files are byte-verified; no application file is relocated.',
    'reference': 'https://wiki.archlinux.org/title/Electron_package_guidelines#Directory_structure',
    'warnings': warnings,
    'rawReportsPreserved': True,
}
(evidence / 'namcap-review.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'status': result['status'], 'unresolvedErrors': errors, 'warningCount': len(warnings)}, indent=2))
if errors:
    raise SystemExit('Unreviewed namcap errors remain.')
