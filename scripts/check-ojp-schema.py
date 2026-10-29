#!/usr/bin/env python3
"""Validate production OJP request templates against an official OJP 2.0 checkout.

Requires lxml. Run: python scripts/check-ojp-schema.py --schema /path/to/OJP/OJP.xsd
No network requests, API token or iPhone are used. Swift interpolations receive
fixed example values; an unexpected/new interpolation fails explicitly.
"""
from pathlib import Path
import argparse
import re

from lxml import etree

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--schema', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / 'WrapPin/Features/Train/Core/OJPClient.swift').read_text(encoding='utf-8')
bodies = re.findall(r'let body = """(.*?)"""', source, re.S)
assert len(bodies) == 3, 'Expected station, trip and journey-info production templates'
envelope = re.search(r'request.httpBody = Data\("""(.*?)"""\.utf8\)', source, re.S).group(1)
schema = etree.XMLSchema(etree.parse(str(args.schema)))
replacements = {
    r'\(OJPXML.timestamp(Date()))': '2026-10-29T12:00:00Z',
    r'\(OJPXML.timestamp(now))': '2026-10-29T12:00:00Z',
    r'\(OJPXML.timestamp(departure))': '2026-10-29T12:00:00Z',
    r'\(OJPXML.escape(name))': 'Bern',
    r'\(OJPXML.escape(origin.id))': 'ch:1:sloid:7000',
    r'\(OJPXML.escape(origin.name))': 'Bern',
    r'\(OJPXML.escape(destination.id))': 'ch:1:sloid:3000',
    r'\(OJPXML.escape(destination.name))': 'Zürich HB',
    r'\(realtime ? "explanatory" : "none")': 'explanatory',
    r'\(OJPXML.escape(reference.journeyRef))': 'ch:1:sjyid:100001:975-001',
    r'\(OJPXML.escape(reference.operatingDay))': '2026-10-29',
}
for number, body in enumerate(bodies, 1):
    for realtime in ['explanatory', 'none'] if number == 2 else ['explanatory']:
        request = envelope.replace(r'\(body)', body)
        for old, new in replacements.items():
            request = request.replace(old, realtime if old.startswith(r'\(realtime ?') else new)
        assert '\\(' not in request, 'Unrecognised Swift interpolation: update schema test'
        # Remove only Swift multiline-string indentation, not XML values.
        request = '\n'.join(line[8:] if line.startswith('        ') else line for line in request.splitlines()).strip()
        document = etree.fromstring(request.encode('utf-8'))
        if not schema.validate(document):
            raise AssertionError(f'Request template {number}: {schema.error_log}')
        print(f'OJP template {number} ({realtime}): schema valid')
