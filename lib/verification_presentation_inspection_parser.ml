(* python-pptx is the document parser, not a producer-supplied manifest.
   Public APIs: https://python-pptx.readthedocs.io/en/latest/api/slides.html
   and https://python-pptx.readthedocs.io/en/latest/api/shapes.html
   XML preflight only constrains external input to the renderer:
   https://lxml.de/parsing.html (no_network, resolve_entities, load_dtd). *)
let source = {python|
import hashlib, io, json, pathlib, posixpath, sys, urllib.parse, zipfile

class PolicyError(Exception):
    pass

def inspect(source, environment):
    import pptx
    from pptx import Presentation
    from pptx.enum.shapes import MSO_SHAPE_TYPE
    from lxml import etree
    expected = pathlib.Path(environment).resolve()
    if pathlib.Path(sys.prefix).resolve() != expected or sys.prefix == sys.base_prefix:
        raise ImportError("managed presentation virtual environment required")
    try:
        pathlib.Path(pptx.__file__).resolve().relative_to(expected)
    except ValueError:
        raise ImportError("python-pptx must belong to the managed environment")
    data = pathlib.Path(source).read_bytes()
    relation_ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    office_ns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    strict_ns = "http://purl.oclc.org/ooxml/officeDocument/relationships/"
    hyperlinks = {office_ns + "hyperlink", strict_ns + "hyperlink"}
    active_relations = {prefix + kind for prefix in (office_ns, strict_ns)
                        for kind in ("oleObject", "package", "control", "vbaProject")}
    active_content_types = {
        "application/vnd.ms-office.vbaProject", "application/vnd.ms-office.activeX",
        "application/vnd.ms-office.activeX+xml",
        "application/vnd.openxmlformats-officedocument.oleObject",
        "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
        "image/svg+xml",
    }
    hyperlink_targets = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        # Input safety limits apply before any decompression (including CRC checks).
        if len(entries) > 4096 or sum(entry.file_size for entry in entries) > 128 * 1024 * 1024:
            raise PolicyError("package expansion exceeds inspection limits")
        for entry in entries:
            if entry.file_size > 16 * 1024 * 1024 or entry.file_size > max(1, entry.compress_size) * 1000:
                raise PolicyError("package member expansion exceeds inspection limits")
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise ValueError("duplicate package member names")
        corrupt = archive.testzip()
        if corrupt is not None:
            raise ValueError("invalid package member checksum: " + corrupt)
        for name in names:
            if name.endswith("/"):
                continue
            if name.endswith(".svg"):
                raise PolicyError("SVG resources require separate external-resource inspection")
            if not (name.endswith(".xml") or name.endswith(".rels")):
                continue
            parser = etree.XMLParser(resolve_entities=False, load_dtd=False, no_network=True)
            try:
                document = etree.parse(io.BytesIO(archive.read(name)), parser)
            except etree.XMLSyntaxError as error:
                raise ValueError("invalid package XML: " + name + ": " + str(error)) from error
            if document.docinfo.doctype:
                raise PolicyError("XML document types and entities are not allowed: " + name)
            for node in document.iter():
                if not isinstance(node.tag, str):
                    continue
                if node.get("ContentType") in active_content_types:
                    raise PolicyError("active or externally loading package content is unsupported: " + name)
                # SVG and VML can address resources directly, without an OPC relationship.
                if node.get("{http://www.w3.org/1999/xlink}href") is not None:
                    raise PolicyError("direct XML resource links are unsupported: " + name)
                if node.tag == "{urn:schemas-microsoft-com:vml}imagedata" and node.get("src") is not None:
                    raise PolicyError("direct VML image sources are unsupported: " + name)
            if not name.endswith(".rels"):
                continue
            if document.getroot().tag != "{" + relation_ns + "}Relationships":
                raise ValueError("invalid relationship document: " + name)
            for relationship in document.getroot():
                if not isinstance(relationship.tag, str):
                    continue
                if relationship.tag != "{" + relation_ns + "}Relationship":
                    raise ValueError("invalid package relationship: " + name)
                kind = relationship.get("Type")
                target = relationship.get("Target")
                if kind is None or target is None:
                    raise ValueError("incomplete package relationship: " + name)
                if kind in active_relations:
                    raise PolicyError("embedded active documents are not inspected: " + name)
                mode = relationship.get("TargetMode", "Internal")
                if kind in hyperlinks:
                    source_part = posixpath.join(posixpath.dirname(posixpath.dirname(name)), posixpath.basename(name)[:-5])
                    hyperlink_targets.setdefault(source_part, []).append(target)
                if mode == "External":
                    if kind in hyperlinks:
                        continue
                    raise PolicyError("external loading relationship is unsupported: " + name + " (" + kind + ")")
                if mode != "Internal":
                    raise ValueError("unknown relationship target mode: " + name)
                decoded = urllib.parse.unquote(target)
                uri = urllib.parse.urlsplit(decoded)
                if uri.scheme or uri.netloc or "\\" in decoded:
                    raise PolicyError("internal relationship points outside the package: " + name)
                # OPC relationships resolve relative to their source part, not the .rels file.
                directory = posixpath.dirname(posixpath.dirname(name))
                resolved = posixpath.normpath(posixpath.join(directory, uri.path))
                if resolved == ".." or resolved.startswith("../"):
                    raise PolicyError("relationship escapes the package: " + name)
    presentation = Presentation(io.BytesIO(data))

    def shape_text(shapes):
        fragments = []
        for shape in shapes:
            if shape.shape_type == MSO_SHAPE_TYPE.GROUP:
                fragments.extend(shape_text(shape.shapes))
            elif shape.has_text_frame:
                fragments.append(shape.text_frame.text)
            elif shape.has_table:
                fragments.extend("\t".join(cell.text for cell in row.cells)
                                 for row in shape.table.rows)
        return fragments

    slides = []
    for number, slide in enumerate(presentation.slides, start=1):
        show = slide._element.get("show", "1")
        if show not in ("0", "1", "true", "false"):
            raise ValueError("invalid slide visibility")
        notes = None
        if slide.has_notes_slide:
            frame = slide.notes_slide.notes_text_frame
            if frame is not None:
                notes = frame.text
        slides.append({"number": number, "text": "\n".join(shape_text(slide.shapes)),
                       "speaker_notes": notes,
                       "visible": show in ("1", "true"),
                       "hyperlinks": hyperlink_targets.get(str(slide.part.partname).lstrip("/"), [])})
    if not slides:
        raise ValueError("presentation contains no slides")
    return {"schema": "masc.presentation-inspection.v1", "ok": True,
            "source_bytes": len(data), "source_sha256": hashlib.sha256(data).hexdigest(),
            "slides": slides,
            "diagnostics": ["python-pptx " + pptx.__version__,
                            str(sum(map(len, hyperlink_targets.values()))) + " hyperlinks preserved without following",
                            "Text follows slide order and shape z-order; tables include cell text.",
                            "Static inspection does not inspect animation, media playback, chart data, or accessibility."]}

def main():
    try:
        result = inspect(sys.argv[1], sys.argv[2])
    except ImportError as error:
        result = {"schema": "masc.presentation-inspection.v1", "ok": False,
                  "kind": "dependency", "detail": str(error)}
    except PolicyError as error:
        result = {"schema": "masc.presentation-inspection.v1", "ok": False,
                  "kind": "policy", "detail": str(error)}
    except (ValueError, KeyError, TypeError, AttributeError, OSError, zipfile.BadZipFile) as error:
        result = {"schema": "masc.presentation-inspection.v1", "ok": False,
                  "kind": "invalid_document", "detail": type(error).__name__ + ": " + str(error)}
    with pathlib.Path(sys.argv[3]).open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=True, allow_nan=False)

main()
|python}
