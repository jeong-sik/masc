### Added

- The Overview's Providers section can show usage windows for OpenRouter,
  Z.AI (GLM Coding Plan), Kimi Coding and Ollama Cloud accounts. A provider
  in `runtime.toml` declares `[providers.<id>.usage-read]` with a `shape`
  (`openrouter-key`, `zai-quota-limit`, `kimi-coding-usages` or
  `ollama-usage`) and an absolute `https://` `url`; masc sends one GET with
  the provider's own credentials, without a model call, once per account at
  server start. An unknown shape, a URL that is not `https://`, a missing
  URL, an unknown key or a provider without `credentials` is refused at load.
  A failed read is logged as a warning with its scope and shape; routing and
  admission do not read these windows. The seed `runtime.toml` declares the
  four endpoints; only OpenRouter's is documented.
