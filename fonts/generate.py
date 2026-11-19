"""Build the Godot scene icon font from the verified Godot 4.7.2 source release."""

import argparse
from ctypes import c_float
import hashlib
import io
import math
from pathlib import Path, PurePosixPath
import tarfile
from urllib.request import urlopen
from xml.etree import ElementTree

import pathops
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.fontBuilder import FontBuilder
from fontTools.misc.transform import Identity, Transform
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from lxml import etree
from picosvg.svg import SVG
from picosvg.svg_transform import Affine2D
from picosvg.svg_types import SVGPath


HERE = Path(__file__).resolve().parent
URL = "https://github.com/godotengine/godot/releases/download/4.7.2-stable/godot-4.7.2-stable.tar.xz"
SHA256 = "a18ce0ccec3ecc40b0dd6c4f5132ca934e9fb7c2979717940ff32aee1eb35481"
NS = "{http://www.w3.org/2000/svg}"
EM, ASCENT = 1024, 832
FIRST_CODEPOINT = 0xF4000


def source_data(data):
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Source archive does not match the official Godot 4.7.2 release")
    icons, parents = {}, {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r|xz") as archive:
        for entry in archive:
            if not entry.isfile():
                continue
            path = PurePosixPath(entry.name).relative_to("godot-4.7.2-stable")
            if path == PurePosixPath("LICENSE.txt"):
                license_text = archive.extractfile(entry).read()
            elif path.suffix == ".xml" and (
                path.parent == PurePosixPath("doc/classes") or "doc_classes" in path.parts
            ):
                root = ElementTree.fromstring(archive.extractfile(entry).read())
                parents[root.get("name")] = root.get("inherits")
            elif path.suffix == ".svg" and path.parent.name == "icons":
                if path.parts[0] in ("editor", "modules"):
                    icons[path.stem] = archive.extractfile(entry).read()
    mapping = {}
    for name in sorted(parents):
        ancestry = []
        current = name
        while current:
            ancestry.append(current)
            current = parents.get(current)
        if name == "PackedScene" or "Node" in ancestry:
            mapping[name] = next(base for base in ancestry if base in icons)
    return icons, mapping, license_text


def svg_path(d):
    path = pathops.Path()
    parse_path(d, path.getPen())
    return path


def rgba(fill, opacity, saturation):
    # editor/themes/editor_icons.cpp substitutes the Modern dark status colors.
    # None of the bundled scene icons occurs in its saturation exception list.
    fill = {"gray": "#808080", "#ff5f5f": "#ff786b", "#5fff97": "#73f280"}.get(fill, fill)
    digits = fill.removeprefix("#")
    if len(digits) == 3:
        digits = "".join(c * 2 for c in digits)
    channels = bytes.fromhex(digits)
    if saturation != 1:
        # Match Image::adjust_bcs and its RGBA8 writeback, including the
        # float32 intermediate rounding and the final truncation to a byte.
        def f32(value):
            return c_float(value).value
        rgb = [f32(0.5 + f32(f32(v / 255) - 0.5)) for v in channels]
        center = f32(f32(f32(rgb[0] + rgb[1]) + rgb[2]) / 3)
        saturated = (f32(center + f32(saturation * f32(v - center))) for v in rgb)
        channels = bytes(int(max(0, min(255, 255 * v))) for v in saturated)
    return (*channels, round(255 * opacity))


def gradient_layers(path, gradient):
    # WorldEnvironment has a hard two-color transition at x=8. Its final
    # stop has no offset, which SVG clamps to the preceding offset (0.5).
    stops = gradient.findall(NS + "stop")
    if gradient.tag == NS + "linearGradient":
        half = float(gradient.get("x2")) / 2
        boxes = (f"M0 0h{half}v{2*half}H0z", f"M{half} 0h{half}v{2*half}H{half}z")
        for d, stop in zip(boxes, (stops[0], stops[-1])):
            yield pathops.op(path, svg_path(d), pathops.PathOp.INTERSECTION), stop.get("stop-color"), 1
        return

    # COLR v0 has solid paints. For RootMotionView, build nested clipped
    # circles with increasing opacity, retaining the grid's vector outline.
    cx, cy, radius = (float(gradient.get(k)) for k in ("cx", "cy", "r"))
    mid = float(stops[1].get("offset"))
    mid_alpha = float(stops[1].get("stop-opacity"))
    previous_alpha = 0
    for step in range(48, 0, -1):
        r = radius * step / 48
        t = (step - 0.5) / 48
        target = 1 - (1 - mid_alpha) * t / mid if t < mid else mid_alpha * (1 - t) / (1 - mid)
        opacity = (target - previous_alpha) / (1 - previous_alpha)
        disc = svg_path(f"M{cx-r} {cy}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0z")
        clipped = pathops.op(path, disc, pathops.PathOp.INTERSECTION)
        if len(clipped):
            yield clipped, stops[0].get("stop-color"), opacity
        previous_alpha = target


def expand_coordinates(svg):
    # Skia's stroke conversion works in path units. Enlarge the 16-pixel
    # coordinates first so small circles and round joins retain their shape.
    root = svg.svg_root
    view = svg.view_box()
    k = EM / view.w
    root.set("viewBox", " ".join(str(v * k) for v in view))
    root.set("stroke-width", root.get("stroke-width", "1"))
    for el in root.iter():
        if el.tag == NS + "path":
            path = SVGPath(d=el.get("d"))
            commands = []
            for cmd, values in path:
                # Arc rotation, large-arc flag and sweep flag are unitless.
                coords = tuple(v if cmd.upper() == "A" and i in (2, 3, 4) else v * k
                               for i, v in enumerate(values))
                commands.append((cmd, coords))
            el.set("d", path.update_path(commands).d)
        if "transform" in el.attrib:
            a, b, c, d, e, f = Affine2D.fromstring(el.get("transform"))
            el.set("transform", f"matrix({a} {b} {c} {d} {e*k} {f*k})")
        lengths = ("stroke-width", "cx", "cy", "r", "rx", "ry", "x", "y", "x1", "y1", "x2", "y2")
        if el is not root:
            lengths += ("width", "height")
        for attr in lengths:
            if attr in el.attrib:
                el.set(attr, str(float(el.get(attr)) * k))
    # Reparse after mutating the XML to refresh picoSVG's shape cache.
    return SVG.fromstring(etree.tostring(root))


def icon_layers(data, saturation):
    root = etree.fromstring(data)
    # The five CSG masks contain one uniform #fefefe shape. Convert their
    # geometry to clips and retain the 254/255 luminance on the painted paths.
    for mask in root.iter(NS + "mask"):
        assert len(mask) == 1 and mask[0].get("fill") == "#fefefe"
        mask.tag = NS + "clipPath"
        for el in root.iter():
            if el.get("mask") == f"url(#{mask.get('id')})":
                el.set("clip-path", el.attrib.pop("mask"))
                for leaf in el.iter(NS + "path"):
                    leaf.set("opacity", str(254 / 255))

    svg = expand_coordinates(SVG.fromstring(etree.tostring(root))).topicosvg(ndigits=5)
    view = svg.view_box()
    assert view.w == view.h
    scale = EM / view.w
    transform = Transform(scale, 0, 0, -scale, -view.x * scale, ASCENT + view.y * scale)
    for el in svg.svg_root:
        if el.tag == NS + "defs":
            continue
        assert el.tag == NS + "path", el.tag
        path = svg_path(el.get("d"))
        fill = el.get("fill")
        if fill.startswith("url("):
            gradient = svg.svg_root.find(f".//*[@id='{fill[5:-1]}']")
            paints = gradient_layers(path, gradient)
        else:
            path.simplify()
            paints = [(path, fill, float(el.get("opacity", 1)))]
        for outline, color, alpha in paints:
            if len(outline):
                yield outline, transform, rgba(color.lower(), alpha, saturation)


def outline_glyph(path, transform):
    pen = TTGlyphPen(None)
    # Convert cubic segments after scaling so the tolerance is in font units.
    path.draw(TransformPen(Cu2QuPen(pen, max_err=0.5), transform))
    return pen.glyph()


def build(icons, mapping, saturation):
    glyphs = {".notdef": TTGlyphPen(None).glyph()}
    cmap, layers, palette, shape_cache = {}, {}, {}, {}
    codepoints = {}
    for index, name in enumerate(sorted(set(mapping.values()))):
        codepoint = FIRST_CODEPOINT + index
        codepoints[name] = codepoint
        cmap[codepoint] = name
        colored = []
        layer_names = []
        for outline, transform, color in icon_layers(icons[name], saturation):
            glyph = outline_glyph(outline, transform)
            key = glyph.compile(None)
            if key not in shape_cache:
                layer = f"layer{len(shape_cache)}"
                shape_cache[key] = layer
                glyphs[layer] = glyph
            layer = shape_cache[key]
            color_index = palette.setdefault(color, len(palette))
            colored.append((layer, color_index))
            if layer not in layer_names:
                layer_names.append(layer)
        if not colored:
            raise ValueError(f"Empty icon for {name}")
        layers[name] = colored
        # A standard glyf outline also makes the silhouette available to
        # renderers that only implement monochrome TrueType.
        base = TTGlyphPen(glyphs)
        for layer in layer_names:
            base.addComponent(layer, Identity)
        glyphs[name] = base.glyph()

    font = FontBuilder(EM, isTTF=True)
    font.setupGlyphOrder(list(glyphs))
    font.setupCharacterMap(cmap)
    font.setupGlyf(glyphs)
    font.setupHorizontalMetrics({name: (EM, getattr(g, "xMin", 0)) for name, g in glyphs.items()})
    font.setupHorizontalHeader(ascent=ASCENT, descent=ASCENT - EM)
    font.setupOS2(sTypoAscender=ASCENT, sTypoDescender=ASCENT - EM, sTypoLineGap=0,
                  usWinAscent=ASCENT, usWinDescent=EM - ASCENT, xAvgCharWidth=EM)
    font.setupNameTable({
        "familyName": "Godot Scene Icons", "styleName": "Regular",
        "uniqueFontIdentifier": f"godot.nvim:GodotSceneIcons:4.7.2:{saturation:g}",
        "fullName": "Godot Scene Icons", "psName": "GodotSceneIcons-Regular",
        "version": "Version 1.000",
        "copyright": "Copyright (c) 2014-present Godot Engine contributors; "
                     "2007-2014 Juan Linietsky, Ariel Manzur.",
        "licenseDescription": "MIT License. See accompanying GODOT-LICENSE.txt.",
        "licenseInfoURL": "https://github.com/godotengine/godot/blob/4.7.2-stable/LICENSE.txt",
    })
    font.setupPost(isFixedPitch=1)
    font.font["COLR"] = buildCOLR(layers, version=0, glyphMap=font.font.getReverseGlyphMap())
    font.font["CPAL"] = buildCPAL([[tuple(v / 255 for v in color) for color in palette]])
    font.font["head"].created = font.font["head"].modified = 3869769600  # 2026-08-17 UTC
    font.font.recalcTimestamp = False
    font.save(HERE / "GodotSceneIcons.ttf")
    lines = ["-- Generated by fonts/generate.py from Godot 4.7.2-stable.", "return {"]
    lines.extend(f"  {name} = 0x{codepoints[icon]:X}," for name, icon in mapping.items())
    lines.append("}")
    (HERE.parent / "lua/godot/official_icon_map.lua").write_bytes(("\n".join(lines) + "\n").encode())
    print(f"{len(codepoints)} official icons, {len(mapping)} classes, {len(palette)} palette entries")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Local copy of the official source .tar.xz")
    parser.add_argument("--saturation", type=float, default=2.0, help="Editor icon saturation (default 2.0)")
    args = parser.parse_args()
    if not math.isfinite(args.saturation) or not 0 <= args.saturation <= 2:
        parser.error("--saturation must be between 0 and 2")
    data = args.archive.read_bytes() if args.archive else urlopen(URL, timeout=120).read()
    icons, mapping, license_text = source_data(data)
    build(icons, mapping, args.saturation)
    (HERE / "GODOT-LICENSE.txt").write_bytes(license_text)
