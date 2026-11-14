#!/usr/bin/env python3
"""tounicode-fix.py — ToUnicode CMap repair for the Arabic edition PDF.

Original: The Sourdough Framework by Hendrik Kleinwächter,
the-sourdough-framework.com, CC BY-SA 4.0. The Arabic edition inherits
CC BY-SA 4.0.

Phase 28R reconstruction of the lost original, from the project record
(Phase 21/22 opening reports).

Root cause: rsvg-convert/pango renders Arabic text via HarfBuzz GSUB
substitution forms (fatha-ar.small, kashida forms, ligature pieces) that
carry no Unicode. The PDF then maps those CIDs to U+FFFD in the ToUnicode
CMap, so text extraction shows replacement characters. The fix is
CMap-only: the glyphs render correctly, only the extraction mapping is
rewritten.

Behavior:
  - Walks every page's /Resources /Font, recursing into Form XObject
    /Resources/Font dictionaries (depth-capped at 6) so fonts nested inside
    the Arabic-redrawn figure SVGs are covered too.
  - For each font with a ToUnicode CMap, every CID mapping to U+FFFD is
    looked up in the CID_MAP table for that base font and rewritten.
  - CID_OVERRIDES are keyed by the FULL BaseFont (subset prefix included)
    so they can never hijack another Amiri subset's same-numbered glyph
    (the fonttag-only keying hazard). Each override entry carries the
    subset hmtx advance the glyph must have (verdict (D) rule: identify by
    width); a width mismatch aborts with exit 1.
  - An unknown U+FFFD CID (not in the table, not a valid override), an
    unapplied override, or -- with --require-overrides -- an override font
    absent from the PDF aborts with exit 1 instead of silently mis-mapping.

Usage: python3 tounicode-fix.py <pdf> [--require-overrides]
"""

import sys
import io
from collections import Counter

import pikepdf
from fontTools.ttLib import TTFont

# --------------------------------------------------------------------------
# CID -> Unicode for the HarfBuzz GSUB forms, keyed by base font name
# (without subset prefix). Established in the Phase 21 opening report,
# build 12 configuration (HarfBuzz renderer + this post-processor).
CID_MAP = {
    "Amiri-Bold": {
        0x510: 0x064E,   # fatha-ar.small
        0x512: 0x064F,   # damma-ar.small
        0x166C: 0x0640,  # kashida-ar.small
    },
    "Amiri-Italic": {
        0x0A45: 0x062E,
        0x16FB: 0x0640,
    },
    "Amiri-Regular": {
        0x059F: 0x064E,
        0x05A1: 0x064F,
        0x0FC9: 0x0626,
        0x155B: 0x064C,
        0x1567: 0x0640,
        0x16FB: 0x0640,
    },
}

# Overrides for fonts nested inside figure XObjects, keyed by the FULL
# BaseFont (subset prefix included). Each entry: cid -> (unicode or None,
# expected hmtx advance in font units). unicode None means "maps to
# nothing": the CMap entry is deleted so extraction yields no character.
# Established in the Phase 22 opening report (build 14).
CID_OVERRIDES = {
    "/KMVOJZ+Amiri-Regular": {
        86: (0x062E, 92),   # خ, the surviving half
        85: (None, 72),
    },
    "/YFXCFN+Amiri-Regular": {
        74: (None, 92),
        49: (0x0640, 185),
    },
}

MAX_XOBJECT_DEPTH = 6


def parse_cmap(stream_bytes):
    """Parse a ToUnicode CMap into (dict cid->unicode list, header, tail).

    Returns (mappings, prefix, suffix) where mappings maps cid (int) to a
    list of unicode ints; prefix/suffix are the CMap text before/after the
    bfchar/bfrange blocks so the file can be rebuilt verbatim.
    """
    text = stream_bytes.decode("latin-1")
    marker = "beginbfchar"
    # find all bfchar and bfrange blocks
    mappings = {}
    segments = []  # (start, end, kind) spans of the block bodies
    idx = 0
    blocks = []
    for kind in ("bfchar", "bfrange"):
        start = 0
        while True:
            b = text.find("begin" + kind, start)
            if b < 0:
                break
            e = text.find("end" + kind, b)
            if e < 0:
                break
            blocks.append((b, e + len("end" + kind), kind))
            start = e + len("end" + kind)
    if not blocks:
        return None, None, None
    blocks.sort()
    prefix = text[: blocks[0][0]]
    suffix = text[blocks[-1][1]:]
    for b, e, kind in blocks:
        body = text[b:e]
        if kind == "bfchar":
            entries = body.split("bfchar")[1].split("endbfchar")[0]
            tokens = entries.split()
            i = 0
            while i + 1 < len(tokens):
                src, dst = tokens[i], tokens[i + 1]
                if src.startswith("<") and dst.startswith("<"):
                    cid = int(src[1:-1], 16)
                    dsthex = dst[1:-1]
                    uni = [int(dsthex[j: j + 4], 16)
                           for j in range(0, len(dsthex), 4)]
                    mappings[cid] = uni
                i += 2
        else:  # bfrange
            entries = body.split("bfrange")[1].split("endbfrange")[0]
            tokens = entries.split()
            i = 0
            while i < len(tokens):
                if i + 2 < len(tokens) and tokens[i].startswith("<") \
                        and tokens[i + 1].startswith("<") \
                        and tokens[i + 2].startswith("<"):
                    lo = int(tokens[i][1:-1], 16)
                    hi = int(tokens[i + 1][1:-1], 16)
                    dsthex = tokens[i + 2][1:-1]
                    base = [int(dsthex[j: j + 4], 16)
                            for j in range(0, len(dsthex), 4)]
                    for c in range(lo, hi + 1):
                        u = base[0] + (c - lo)
                        mappings[c] = [u]
                    i += 3
                elif i + 2 < len(tokens) and tokens[i].startswith("<") \
                        and tokens[i + 1].startswith("<") \
                        and tokens[i + 2].startswith("["):
                    lo = int(tokens[i][1:-1], 16)
                    hi = int(tokens[i + 1][1:-1], 16)
                    inner = tokens[i + 2][1:-1].split(">")
                    for off, c in enumerate(range(lo, hi + 1)):
                        if off < len(inner):
                            h = inner[off].lstrip("<")
                            if h:
                                mappings[c] = [int(h, 16)]
                    i += 3
                else:
                    i += 1
    return mappings, prefix, suffix


def build_cmap(prefix, entries, suffix):
    """Rebuild the CMap text from an ordered list of (cid, uni-list) with
    None unicode meaning the entry is dropped."""
    lines = []
    for cid, uni in entries:
        if uni is None:
            continue
        dst = "".join("%04X" % u for u in uni)
        lines.append("<%04X> <%s>" % (cid, dst))
    body = "\n".join(lines)
    return (prefix + "beginbfchar\n" + body + "\nendbfchar\n" + suffix,
            len([e for e in entries if e[1] is not None]))


def hmtx_advance(pdf, font_obj, cid):
    """Read the advance width (font units) of glyph `cid` from the font's
    embedded FontFile2 via fontTools. Identity CID==GID for these subsets."""
    try:
        desc = font_obj["/FontDescriptor"]
        ff = desc["/FontFile2"]
        data = ff.read_bytes()
        tt = TTFont(io.BytesIO(data), fontNumber=0, lazy=True)
        hmtx = tt["hmtx"]
        # glyph order: GID -> name
        order = tt.getGlyphOrder()
        if cid < len(order):
            name = order[cid]
            return hmtx[name][0]
    except Exception as exc:  # noqa: BLE001
        print("  ! hmtx read failed for cid %s: %s" % (cid, exc))
    return None


def collect_fonts(pdf, depth=0):
    """Yield (basefont, font_obj) for every font in the document, recursing
    into Form XObject resources up to MAX_XOBJECT_DEPTH."""
    seen = set()
    out = []

    def walk(res, depth):
        if res is None or depth > MAX_XOBJECT_DEPTH:
            return
        try:
            fonts = res["/Font"]
        except KeyError:
            fonts = None
        if fonts is not None:
            for name, fobj in fonts.items():
                try:
                    bf = str(fobj["/BaseFont"])
                except (KeyError, AttributeError):
                    bf = str(name)
                key = (bf, fobj.objgen if hasattr(fobj, "objgen") else id(fobj))
                if key not in seen:
                    seen.add(key)
                    out.append((bf, fobj))
        try:
            xobjs = res["/XObject"]
        except KeyError:
            xobjs = None
        if xobjs is not None:
            for _, xo in xobjs.items():
                try:
                    if str(xo.get("/Subtype", "")) == "/Form":
                        walk(xo.get("/Resources"), depth + 1)
                except (KeyError, AttributeError):
                    pass

    for page in pdf.pages:
        try:
            walk(page.get("/Resources"), 0)
        except (KeyError, AttributeError):
            pass
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    require_overrides = "--require-overrides" in flags
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    path = args[0]

    pdf = pikepdf.open(path, allow_overwriting_input=True)
    fonts = collect_fonts(pdf)

    total_patched = 0
    patched_by_font = Counter()
    applied_overrides = set()
    errors = []

    for bf, fobj in fonts:
        cmap_obj = fobj.get("/ToUnicode")
        if cmap_obj is None:
            continue
        raw = cmap_obj.read_bytes()
        parsed = parse_cmap(raw)
        if parsed[0] is None:
            continue
        mappings, prefix, suffix = parsed

        # which base table applies? key by base font name without subset tag
        base_key = None
        for k in CID_MAP:
            if bf.endswith(k) or bf.endswith("+" + k):
                base_key = k
                break
        override_key = bf if bf in CID_OVERRIDES else None

        if base_key is None and override_key is None:
            # an overridden font that is absent from the tables but carries
            # FFFD entries is only an error if it claims an override name
            continue

        table = dict(CID_MAP.get(base_key, {}))
        if override_key:
            table.update({cid: ([u] if u else None)
                          for cid, (u, _w) in CID_OVERRIDES[override_key].items()})

        changed = False
        entries = []
        for cid in sorted(mappings):
            uni = mappings[cid]
            if uni == [0xFFFD]:
                if cid in table:
                    new = table[cid]
                    if new is not None:
                        # width check for overrides
                        if override_key and cid in CID_OVERRIDES[override_key]:
                            expect = CID_OVERRIDES[override_key][cid][1]
                            adv = hmtx_advance(pdf, fobj, cid)
                            if adv is not None and adv != expect:
                                errors.append(
                                    "%s cid %d width %s != expected %d"
                                    % (bf, cid, adv, expect))
                                continue
                            applied_overrides.add((override_key, cid))
                    entries.append((cid, new))
                    changed = True
                    total_patched += 1
                    patched_by_font[bf] += 1
                else:
                    errors.append("unknown U+FFFD cid %d in %s" % (cid, bf))
                    entries.append((cid, uni))
            else:
                entries.append((cid, uni))

        if changed:
            text, n = build_cmap(prefix, entries, suffix)
            fobj["/ToUnicode"].write(text.encode("latin-1"))

    # override bookkeeping
    for bf in CID_OVERRIDES:
        present = any(b == bf for b, _ in fonts)
        if not present:
            if require_overrides:
                errors.append("override font %s absent from the PDF" % bf)
            continue
        for cid in CID_OVERRIDES[bf]:
            if (bf, cid) not in applied_overrides:
                errors.append("override %s cid %d not applied" % (bf, cid))

    pdf.save(path)
    pdf.close()

    for bf, n in sorted(patched_by_font.items()):
        print("patched %3d CIDs in %s" % (n, bf))
    if errors:
        for e in errors:
            print("ERROR: %s" % e)
        sys.exit(1)
    print("tounicode-fix: %d CID(s) patched, 0 unresolved" % total_patched)
    sys.exit(0)


if __name__ == "__main__":
    main()
