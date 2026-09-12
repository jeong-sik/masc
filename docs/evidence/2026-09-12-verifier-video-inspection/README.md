# Original MP4 inspection for standalone verification

Task004's independent verifier rejected PPTX/MP4 reads as non-UTF-8. This change extends its existing contained Read boundary for MP4 files. It captures complete bytes privately, hashes that exact copy, probes format/stream metadata with FFprobe and decodes every audio/video stream with FFmpeg. Decoder status and diagnostics are direct process observations. Subtitle/data/attachment streams are separately marked uninspected. Metadata/decoding is not a visual or accessibility verdict.

The fixed MOV/MP4 demuxer disables external data references and absolute track paths; the input protocol is restricted to file. No producer command, arbitrary shell, network URL or producer path reaches the decoder. The original snapshot is compared again after inspection and temporary files are removed on completion. Missing FFmpeg/FFprobe, malformed output, empty media and decoding errors are failures. This feature requires FFmpeg installed in the verifier service environment; it does not silently install a dependency or infer availability from a producer container.

This branch is stacked on PDF inspection PR35398 because it reuses the complete-byte dispatch and capture boundaries. Its behavior test exercises Task and Goal Read with the real fixture below, exact source identity, both audio/video streams, damaged media, line-window rejection, containment and absent dependencies. CI installs FFmpeg for the real test. Local validation is parse-only OCaml plus actual standalone FFmpeg commands; no local MASC build or deployed-verifier success is claimed.

Fixture: generated one-second 64x48 MPEG-4 video and mono AAC sine tone, using FFmpeg lavfi testsrc2 and sine. It contains no third-party media. Exact command and SHA are in fixture.json.

Primary command references:
- https://ffmpeg.org/ffprobe.html (JSON format/stream metadata)
- https://ffmpeg.org/ffmpeg.html (stream mapping, xerror, abort_on)
- https://ffmpeg.org/ffmpeg-formats.html#mov_002fmp4_002f3gp (external track reference defaults)
