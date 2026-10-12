# Unobserved body metadata authority

A `Text` event with `Unobserved_scope (Some scope)` previously called `enter_text_response_scope` even after an explicitly observed response had acquired authority. That replaced response metadata with an unobserved scope, cleared model/usage/stop/activity metadata, and inserted a response boundary. The body itself was retained.

The branch now enters an unobserved scope only while no observed response owner exists. Original unowned body bytes are still retained by the existing Text arm; no provider identity or reasoning is invented.

Measured actual parent/current Unobserved_scope branch expressions and unchanged `enter_text_response_scope` in `/tmp/masc-unobserved-body-metadata-20261012/{parent,current}.ml`. Parent failed: `unobserved body replaced observed response metadata`. Current passed for absent, earlier, same and later unobserved scopes over a known owner, while an initially unowned scope still entered. Minimal record types substitute external state; `begin_response` records a boundary count instead of trail nodes. This does not execute the entire Text arm, decoder, buffer/trail rendering or provider runtime.

Registered a state fixture asserting response_metadata preservation and original text retention for the same four scopes. Fixture remains unexecuted. Both changed OCaml files passed syntax-only parsing and git diff --check passed. No full typecheck/build/CI/installation/UI/screenshot or formal approval evidence.
