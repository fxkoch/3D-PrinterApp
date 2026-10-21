#!/usr/bin/env python3
"""Builds Packages/MakerSliceCore/Sources/SliceKit/Settings/SlicerOptions.generated.swift:
every process setting of Anycubic Slicer Next (Kobra S1) and Snapmaker Orca (U1) with German texts and the
vendor profile value as recommendation.

  build_catalog.py <sources-dir>
where <sources-dir> holds PrintConfig.cpp/Tab.cpp (Orca 2.3.0, base of Slicer Next) and
snap_PrintConfig_v2.4.0.cpp/snap_Tab_v2.4.0.cpp (Snapmaker Orca). The installed apps provide translations and profiles."""
import sys, os, json, re
sys.path.insert(0, os.path.dirname(__file__))
from orca_options import *

SRC = sys.argv[1]
NEXT = '/Applications/AnycubicSlicerNext.app/Contents/Resources'
ORCA = '/Applications/OrcaSlicer.app/Contents/Resources'
OUT = os.path.join(os.path.dirname(__file__), '../../Packages/MakerSliceCore/Sources/SliceKit/Settings/SlicerOptions.generated.swift')

mo_next = read_mo(NEXT + '/i18n/de/' + os.listdir(NEXT + '/i18n/de')[0])
mo_orca = read_mo(ORCA + '/i18n/de/OrcaSlicer.mo')
de = {**mo_orca, **mo_next}


def tr(s):
    return de.get(norm(s)) if s else None


def resolve(dirs, name):
    """Merged settings of a vendor process preset including everything it inherits."""
    def find(n):
        for d in dirs:
            p = os.path.join(d, n + '.json')
            if os.path.exists(p):
                return json.load(open(p))
        return None
    j = find(name)
    if j is None:
        raise SystemExit('profile not found: ' + name)
    base = resolve(dirs, j['inherits']) if j.get('inherits') else {}
    base.update({k: v for k, v in j.items() if k not in ('inherits', 'name', 'from', 'instantiation', 'setting_id')})
    return base


kobra_rec = resolve([NEXT + '/profiles/Anycubic/process'], '0.20mm Standard @Anycubic Kobra S1 0.4 nozzle')
u1_rec = resolve([ORCA + '/profiles/Snapmaker/process'], '0.20 Standard @Snapmaker U1 (0.4 nozzle)')

o_defs = parse_defs(open(SRC + '/PrintConfig.cpp').read())
o_lay = parse_layout(open(SRC + '/Tab.cpp').read())
s_defs = parse_defs(open(SRC + '/snap_PrintConfig_v2.4.0.cpp').read())
s_lay = parse_layout(open(SRC + '/snap_Tab_v2.4.0.cpp').read())

# Slicer Next: Orca layout, but only what Anycubic's build knows (label in its translation or used by its Kobra S1 profile)
next_keys = [(p, g, k) for p, g, k in o_lay
             if k in kobra_rec or (o_defs.get(k, {}).get('label') and norm(o_defs[k]['label']) in mo_next)]
snap_keys = s_lay

OVERRIDES = json.load(open(os.path.join(os.path.dirname(__file__), 'german_overrides.json')))
GROUPS = {'Color Mixing (Experimental)': 'Farbmischung (experimentell)'}
PAGES = {'Quality': 'Qualität', 'Strength': 'Festigkeit', 'Speed': 'Geschwindigkeit', 'Support': 'Stützen',
         'Multimaterial': 'Mehrfarben', 'Others': 'Sonstiges'}

entries = {}


def add(model, lay, defs, rec):
    for page, group, key in lay:
        d = defs.get(key)
        if not d or d['type'] in ('?',) or not d['label']:
            continue
        e = entries.setdefault(key, dict(key=key, page=page, group=group, d=d, models={}))
        v = rec.get(key)
        if isinstance(v, list) and len(v) == 1:
            v = v[0]
        if v is not None and not isinstance(v, list):
            e['models'][model] = str(v)
        else:
            e['models'].setdefault(model, None)


add('kobraS1', next_keys, o_defs, kobra_rec)
add('snapmakerU1', snap_keys, s_defs, u1_rec)
for e in entries.values():
    if 'snapmakerU1' in e['models']:   # prefer Snapmaker's definition where both exist (newer)
        e['d'] = s_defs[e['key']]


def unit_of(key, kind, side):
    side = (side or '').replace(' or %', ' oder %').replace('mm/s o. %', 'mm/s oder %')
    if side:
        return side
    if kind not in ('float', 'floatOrPercent', 'int'):
        return ''
    if 'acceleration' in key:
        return 'mm/s²'
    if key.endswith('speed') or key.endswith('_jerk') or '_speed' in key or 'jerk' in key:
        return 'mm/s'
    if kind != 'int' and re.search(r'distance|height|gap|radius|compensation|length|width|diameter|spacing|thickness|offset|inset', key) and 'ratio' not in key:
        return 'mm'
    return ''


def sw(s):
    s = (s or '').replace('%%', '%').replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
    return '"' + s + '"'


KIND = {'coBools': 'bool', 'coInts': 'int', 'coFloats': 'float', 'coPercents': 'percent', 'coFloatsOrPercents': 'floatOrPercent',
        'coBool': 'bool', 'coInt': 'int', 'coFloat': 'float', 'coPercent': 'percent', 'coFloatOrPercent': 'floatOrPercent',
        'coEnum': 'choice', 'coString': 'text'}
lines = []
missing_de = []
for e in entries.values():
    d = e['d']
    kind = KIND.get(d['type'])
    if not kind:
        continue
    ov = OVERRIDES.get(e['key'], {})
    title = ov.get('title') or tr(d['label']) or d['label']
    summary = ov.get('summary') or (tr(d['tooltip']) if d['tooltip'] else None)
    if d['tooltip'] and not summary:
        missing_de.append(e['key'])
    summary = summary or d['tooltip'] or ''
    ch = ''
    if kind == 'choice':
        labels = d['enum_labels'] if len(d['enum_labels']) == len(d['enum']) else d['enum']
        ch = ', '.join('(%s, %s)' % (sw(v), sw(tr(l) or l)) for v, l in zip(d['enum'], labels))
    mdl = ', '.join('.%s: %s' % (m, sw(v) if v is not None else '""') for m, v in e['models'].items() if v is not None)
    avail = ', '.join('.' + m for m in e['models'])
    lines.append('        SlicerOption(key: %s, page: %s, group: %s, kind: .%s, title: %s, summary: %s, unit: %s, min: %s, max: %s, choices: [%s], availableFor: [%s], vendor: [%s]),' % (
        sw(e['key']), sw(PAGES.get(e['page'], e['page'])), sw(GROUPS.get(e['group']) or tr(e['group']) or e['group']), kind, sw(title), sw(summary),
        sw(unit_of(e['key'], kind, tr(d['side']) or d['side'])), 'nil' if d['min'] is None else repr(d['min']), 'nil' if d['max'] is None else repr(d['max']),
        ch, avail, mdl or ':'))
hdr = '''// Generated by tools/settings/build_catalog.py – do not edit.
// Source: Anycubic Slicer Next (Kobra S1) and Snapmaker Orca (U1) process settings, vendor profile values as `vendor`.

extension SlicerOptionCatalog {
    static let generated: [SlicerOption] = [
'''
open(OUT, 'w').write(hdr + '\n'.join(lines) + '\n    ]\n}\n')
print(len(lines), 'options;', len(missing_de), 'without German tooltip:', missing_de)
