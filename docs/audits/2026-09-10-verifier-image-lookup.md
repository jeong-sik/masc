# Shared visual evidence lookup for completion reviewers

The live Goal reviewer rejected a publication because text-only Read could establish file existence and byte counts but could not inspect Korean text, clipping, title consistency, or the fictional-event label. This feature supplies image bytes to that same judge; it does not lower those criteria or treat a linked Task verdict as proof.

The existing Read lookup now recognizes image bytes through the shared image-format sniffer. It reads through the existing producer sandbox runner or the existing owned regular-file reader, with the same cwd/path resolver and containment. Goal reads remain rooted at the shared playground; Task reads remain producer-scoped. The byte bound is the configured KeeperVision image bound, with one lookahead byte to detect oversize, independent of text Read defaults. Images are read whole; line-window arguments receive a stated rejection.

The typed Tool_result payload carries canonical model blocks through Tool_bridge. Its observation contains path, MIME type, full size and SHA-256, never base64 image bodies. Nonimage binary output retains PR35153's UTF-8 rejection boundary. No vision-summary submodel or operator copy into a store is used. PDF rendering/native PDF inspection remains outside this feature.

A deterministic valid 300×300 PNG fixture is 270448 bytes, exceeding the text Read default. The feature test reads it through both Goal and Task surfaces, checks exact byte/hash receipts and image blocks in the next Anthropic request, rejects an outside path and escaping symlink, and exercises the existing configured image bound. Earlier dependent transport tests cover checkpoint/journal replay and OpenAI/Ollama/Gemini image projection.

Validation at authoring: source parse and whitespace checks passed; the fixture was independently decoded as PNG. No local build, deployed runtime update, model semantic judgment, or Goal completion is claimed. Exact-head CI and the original live Goal acceptance remain required.
