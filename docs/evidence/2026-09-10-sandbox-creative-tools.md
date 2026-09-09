# General sandbox creative tools

The isolated memory-guide Keeper found Python but no ReportLab, CairoSVG or
WeasyPrint in `masc-sandbox:general`. Its root filesystem is read-only, so it
started writing a PDF implementation instead of using a document library.
The default image recipe is `Keeper_sandbox_image.dockerfile`, embedded in the
installed binary; the separate development Dockerfile is not this runtime.

The recipe now includes ReportLab and Poppler for PDF creation/inspection,
CairoSVG and Pillow for SVG/raster images, Nanum Korean fonts, Pandoc and
LibreOffice Impress for slides, and FFmpeg for audio/video. These are Debian
packages installed when building the image, not at Keeper execution time.
Package sources: [ReportLab](https://packages.debian.org/bookworm/python3-reportlab),
[CairoSVG](https://packages.debian.org/bookworm/python/python3-cairosvg),
[Nanum fonts](https://packages.debian.org/bookworm/fonts-nanum).

The Test workflow exercises its freshly built embedded recipe under a
non-root UID, read-only rootfs, dropped capabilities and no network. It creates
and reopens PDF, PNG, JPEG, animated GIF, SVG, PPTX, WAV, MP3 and MP4. PDF text
extraction checks Korean text; rendered pages and hash receipts are uploaded
for visual review. This is a synthetic environment capability scenario, not
a claim that a Keeper chose formats autonomously or that production uses the
new image. CI result and downloaded visual inspection are pending.
