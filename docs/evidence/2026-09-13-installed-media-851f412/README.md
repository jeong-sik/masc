# Installed media inspection: 851f412

The installed `masc inspect-file` CLI inspected the three actual task-004 adaptation originals. All three native commands exited 0 and returned completed typed results. This closes the previously missing installed original-file parsing/rendering/decode evidence for these files. It does not replace the earlier task approval or claim an LLM verdict.

## Installed identity and CI

- Source: `851f412a88f4d5bf290dfa67ac60c4b78bb3ebb1`.
- Binary SHA-256: `41a75acff6d190e767cebee3b53c371ed643293a41e1f1b5d93a6c5ab88c180d` (75,875,888 bytes).
- Installed release manifest SHA-256: `9cf2e6e2497f396c5a23dfd2f2c36b7a2dbe99ca7fa8fbd43e2c11cf95916c1d`; 5,431 companion, Dashboard and runtime files were checked against their paired manifest. The binary's `build-commit` output matches the exact source.
- [Test run 34710740227](https://github.com/jeong-sik/masc/actions/runs/34710740227): completed successfully at that source. Its 15 requested suites ran 228 cases. `native-test-target-summary.txt` preserves selected start/result lines; `prior-ci-review.json` includes original full-log hashes and the independent CI review. The latter predates this installed acceptance, so its not-proven list describes that earlier review boundary.
- [macOS ARM Release job 103598999598](https://github.com/jeong-sik/masc/actions/runs/34710741534/job/103598999598): completed successfully at the same source. This evidence does not claim completion of all Release platforms.

## Actual originals and results

| Original | SHA-256 | Bytes | Native result |
| --- | --- | ---: | --- |
| experience.pptx | c6ae385c2925b8946a5e56873977ac26c8a33dd0ee20c44d760144ece9bb4c9d | 25594 | 8 source slides parsed; 8 slide images rendered |
| experience.mp4 | e9f26dde92b0b4120546d617c5cb89e420a3bc43943e5587b04c746bcd7f1283 | 345612 | Entire sole video stream (index 0) decoded; no audio stream |
| experience.pdf | 83c3ba38ff2b0646ce3db1f16adf28324913d58972cc4a109feb06dcaa538897 | 56688 | All 8 pages parsed and rendered |

PPTX parsing uses the managed python-pptx environment and portable LibreOffice; PDF parsing/rendering uses Poppler. The MP4 is H.264, 1920 × 1080, 115 seconds. FFprobe and FFmpeg 8.0.1 returned exit 0; the complete decode uses the same single captured input, explicitly maps stream 0, and has no seek, duration, or frame limit. Raw native output and exact argv are retained.

The independent reviewer rehashed the installed release and current original bytes, reran receipt validation, decoded all 16 returned PNGs, and compared their bytes with the saved images. Both 6th-page PNGs were directly viewed: Korean body text and all three choices are readable. Their fonts/layout differ, so visual equivalence is not claimed. The remaining PNGs are saved and decoded, not individually visually assessed.

Saved before/after state captures contain paths, hashes and sizes only: all 352 selected files were unchanged during this CLI observation, including 191 protected Task/Goal/config paths. This is the probe's observation interval, not the separate later server-restart comparison. It does not establish semantic memory continuity.

## Evidence scope and files

`receipt.json`, three raw `stdout.json`/`stderr.txt` pairs, build-commit output, native FFmpeg logs, all rendered PNGs, and state captures are byte-for-byte copies from `/tmp/masc-installed-media-851f412-20260913`. `sha256.json` is the original probe manifest for 37 files. `SHA256SUMS` covers this archive, including its added README and review metadata, except itself.

Every CLI output says `llm_verdict: not_run`. No LLM visual or semantic assessment, Task/Goal approval, automatic verifier-lane invocation, video-frame visual inspection, or audio decode for this audio-free file is inferred. PPTX animations, embedded audio/video playback, chart data and accessibility remain explicitly uninspected. The reviewer did not rebuild, reinstall, restart or modify runtime state.
