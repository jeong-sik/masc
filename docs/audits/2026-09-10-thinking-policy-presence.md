# Unspecified thinking policy stays unspecified

The isolated c083 Keeper attempted Kimi, then its Ollama fallback. Both requests
were rejected before provider dispatch because `enable_thinking=false` could not
be encoded by their declared no-toggle dialects. The Kimi model omitted
`thinking-support`, but the runtime parser converted omission into false.
Keeper's fleet fallback independently defaulted its request toggle to false.

The existing model field and fleet request setting now preserve absence as
`None`; explicit true and false remain typed requests. Model declarations still
take precedence over explicit fleet policy. Missing policy leaves the provider
default unchanged. Unsupported explicit disables still fail provider validation.
No thinking controls are removed from providers that implement them, and no new
configuration knob is added.

Runtime readback emits null for an undeclared model policy; tool observations
omit an unrequested toggle. The Keeper workspace rail distinguishes that state
from an explicit disabled policy.

The behavioral scenario loads the repository Kimi runtime and catalog, exercises
fleet unset/false/true through the actual turn policy, and serializes the unset
request without invented toggle or effort fields. It checks that explicit false
still receives the typed unsupported-disable rejection. Existing explicit-model
true/false tests retain their meaning after the model field becomes optional.
CI is pending; no local build or live provider/configuration mutation was done.
