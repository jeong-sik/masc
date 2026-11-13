### Fixed

- A `runtime.toml` value its setting cannot use is refused where the file's
  text is validated: a blank or over-long `autonomous.wake_prompt`, a
  `sandbox.microvm_memory` that is not a size, a `sandbox.microvm_dns` a guest
  cannot reach, and a `web_search.searxng_url` that is not an http or https
  URL. The dashboard's save and preview, `masc config set`, the web search
  setup and the deployment check now report it under the `runtime.toml` key;
  before, they accepted it and the next server start refused the file. The
  wake prompt's reader names `autonomous.wake_prompt` instead of an
  environment variable (#PENDING).
