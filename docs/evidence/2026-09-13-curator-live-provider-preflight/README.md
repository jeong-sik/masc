# Live local curator provider preflight

Read-only Ollama `/api/show` and `/api/ps` observations confirm the prepared model
name resolves to the same loaded digest as the ongoing standalone run. The
provider advertises tools, thinking, completion and vision; the loaded context
length is 262,144. These are provider metadata, not tests of each capability.
The tag contains UD-Q4_K_XL while the provider detail reports Q4_K_M; both original
values are retained rather than inferring quantization from the model name.

No generation was requested, no model was restarted, and no MASC configuration
was changed. Native MASC exact-lane admission and successful curator execution
remain required after installing the tested candidate. The existing standalone
synthesis process is independent from that acceptance.
