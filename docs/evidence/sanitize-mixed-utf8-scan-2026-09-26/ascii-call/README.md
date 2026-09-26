# ASCII predicate call in the measured candidate

The paired experiment recorded an ASCII/identity mutation median increase in
two of three sessions. This observation does not identify the cause: the host
was shared, and other timing groups were mixed.

Inspecting the verified macOS ARM64 artifacts identified one concrete added
operation. Baseline `887807`'s `ascii_clean` performs the control comparisons
inside its loop. Measured candidate `8c23cd5`'s `first_repair` instead has
`bl _camlSafe_ops$is_disallowed_control_char_1003` on its ASCII branch, with
register state saved and reloaded around the call. The two exact disassemblies,
commands, source identities and server SHA-256 values are retained here.

The follow-up marks the existing private, pure predicate `[@inline]`; its body,
callers, validation and repair policy are unchanged. This attribute is also
used by the installed OCaml 5.5.1 stdlib, including Uchar's decode predicates.
It requests compiler inlining without duplicating the control-character rule.
Existing multilingual/byte-boundary tests continue to cover behavior.

This is a source correction prompted by emitted code, not proof that the call
caused the measured regression. A new artifact must be disassembled to verify
that the compiler removed the call, and measured separately for performance.
The earlier paired experiment remains evidence for `8c23cd5`, not for this
attribute change. No local OCaml build, speedup or deployment is claimed.
