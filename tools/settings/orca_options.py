"""Reads OrcaSlicer-style option definitions (PrintConfig.cpp), the process tab layout (Tab.cpp)
and German translations (.mo) – shared by build_catalog.py."""
import re, struct, json


def read_mo(path):
    d = open(path, 'rb').read()
    e = '<' if struct.unpack('<I', d[:4])[0] == 0x950412de else '>'
    n, o, t = struct.unpack(e + 'III', d[8:20])
    res = {}
    for i in range(n):
        l, off = struct.unpack(e + 'II', d[o + 8 * i:o + 8 * i + 8])
        l2, off2 = struct.unpack(e + 'II', d[t + 8 * i:t + 8 * i + 8])
        k = d[off:off + l].decode('utf8', 'replace').split('\x04')[-1]
        res[norm(k)] = d[off2:off2 + l2].decode('utf8', 'replace')
    return res


def norm(s):
    return re.sub(r'\s+', ' ', s).strip()


def cstr(expr):
    return ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', expr)).replace('\\n', '\n').replace('\\"', '"')


def parse_defs(src):
    parts = re.split(r'\n\s*(?:auto\s+\w+\s*=\s*)?def\s*=\s*this->add(?:_nullable)?\("', src)
    defs = {}
    for p in parts[1:]:
        key = p.split('"')[0]
        m = re.match(r'[a-z_0-9]+",\s*(co\w+)\)', p)
        typ = m.group(1) if m else '?'
        end = p.find('def = this->add')
        body = p if end < 0 else p[:end]
        def s(field):
            mm = re.search(r'def->' + field + r'\s*=\s*((?:u8L|_L|L)\((?:\s*"(?:[^"\\]|\\.)*"\s*)+\))', body)
            return cstr(mm.group(1)) if mm else None
        mn = re.search(r'def->min\s*=\s*(-?[\d.]+)', body)
        mx = re.search(r'def->max\s*=\s*(-?[\d.]+)', body)
        dflt = re.search(r'def->set_default_value\((.*)\);', body)
        defs[key] = dict(
            type=typ, label=s('label'), tooltip=s('tooltip'), side=s('sidetext'),
            min=float(mn.group(1)) if mn else None, max=float(mx.group(1)) if mx else None,
            enum=re.findall(r'def->enum_values\.push_back\("([^"]*)"\)', body),
            enum_labels=[cstr(x) for x in re.findall(r'def->enum_labels\.push_back\((?:u8L|_L|L)\(("[^"]*")\)\)', body)],
            default=dflt.group(1) if dflt else None)
    return defs


def parse_layout(tab):
    i = tab.index('void TabPrint::build()')
    j = tab.find('void TabPrintModel::build()')
    b = tab[i:j if j > i else i + 70000]
    page = group = None
    out = []
    for line in b.split('\n'):
        m = re.search(r'add_options_page\(L\("([^"]+)"\)', line)
        if m:
            page = m.group(1); continue
        m = re.search(r'new_optgroup\(L\("([^"]+)"\)', line)
        if m:
            group = m.group(1); continue
        for k in re.findall(r'append_single_option_line\(\s*"([a-z_0-9]+)"', line):
            if (page, group, k) not in out:
                out.append((page, group, k))
    return out
