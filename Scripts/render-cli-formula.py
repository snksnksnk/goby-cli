#!/usr/bin/env python3
import re, sys
from pathlib import Path
source, destination, version, checksum = sys.argv[1:]
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.-]+)?', version), 'Invalid release version'
assert re.fullmatch(r'[0-9a-f]{64}', checksum), 'A verified archive digest is required'
text = Path(source).read_text().replace('@VERSION@', version).replace('@SHA256@', checksum)
assert '@VERSION@' not in text and '@SHA256@' not in text
Path(destination).write_text(text)
