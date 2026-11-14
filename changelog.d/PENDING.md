### Fixed

- `WebSearch` with `includeContent:true` keeps the text an engine sent from
  the page when the page itself cannot be fetched. Ollama `content` and Exa
  `text` were read like any engine's snippet and cut to 1 KiB, so a failed
  page fetch left only that preview and a failure note. Each engine's parser
  now names its field as the engine's own summary or text from the page;
  a page that can be fetched is still the content, and a failed fetch of a
  page with engine text shows that text, cut to `contentMaxChars`, under a
  `Content source` line naming the engine, counted apart in
  `content_engine_text_count` (#38729, #PENDING).
