# Image tool results on text-only tool-response wires

OpenAI-compatible and Ollama tool responses serialized image blocks as JSON text. Gemini ignored those blocks. These request projections did not give the model visual input.

The shared tool-result projection now retains each exact tool response and projects its original image blocks into a labelled user-media followup after the contiguous tool-result batch. OpenAI uses the existing image_url serializer; Ollama uses its existing images field; Gemini uses existing inlineData user parts. Anthropic and Responses retain their native multimodal tool-result arrays. Canonical history and checkpoints are unchanged by this request-only projection.

This uses Gemini user media parts rather than Gemini-3-specific multimodal functionResponse.parts. See [Gemini content API](https://ai.google.dev/api/generate-content) and [Ollama chat message API](https://docs.ollama.com/api/chat). All capability checks remain in their owning request paths; Ollama validates original content before projection.

The feature scenario uses one complete PNG, two parallel tool calls with results in separate messages, and verifies both tool responses precede the image followup. It checks exact image bytes in OpenAI image_url, Ollama images, and Gemini inlineData, along with capability rejection and unchanged canonical history. Source parse/diff checks only; exact-head CI pending. No live image-recognition or Goal-completion claim.
