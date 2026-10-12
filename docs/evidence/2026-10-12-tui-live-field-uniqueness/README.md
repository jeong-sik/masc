# Live stream metadata uniqueness

Base: a80a8f6713be219acc1e2352d8892ef4166221ee.

The strict terminal decoder already uses unique_object_fields. Live event
handling selected first fields and could attach a different occurrence/call ID
or accept a conflicting event type. Expose the existing projection validator and
share it with live envelope and CUSTOM metadata-object decoding before dispatch.
Opaque argument strings remain untouched; this is protocol metadata validation,
not content matching or recursive rewriting of supplied arguments.

Artifacts: /tmp/masc-tui-live-field-uniqueness-20261012/.
Actual parent/current live dispatcher, custom metadata guard, tool occurrence and
argument helpers run with actual projection unique_object_fields and actual
Json_util.reject_unknown_fields. Surroundings stub integer decoding (exercised
values are valid integers), approval ID decoding, unrelated text handling and
custom-schema validation. The only custom event arm exercised is copied actual
approval settlement handling; unrelated custom arms are omitted. Actual Yojson
is loaded. Parent exits 1 for duplicate live identity. Current exits 0 for
repeated envelope/occurrence/custom approval fields, canonical tool acceptance
and exact opaque argument string retention. This is not whole live decoder,
SSE framing or full completion-protocol execution evidence.

Three changed OCaml files passed syntax-only parsing; diff whitespace check
passed. Registered live protocol fixture is unexecuted. Full typecheck/build,
provider integration, journal replay, installed runtime, UI/screenshots, CI,
formal approval and merge remain unverified. Nested usage and other typed payload
objects still use their respective codecs; recursive uniqueness is not asserted.
