# Original media and collaboration verification integration

This candidate combines the installed collaboration behavior and historical Chat
output work from `4324764e959a5ff8b265b292e5bab9f68e550313` with three explicit
source heads. Their identities remain ancestors, including the previously
installed `aad94bbf3fb90a4600496bf56d7590f02ff385ad`.

| Component | Source | Local merge |
| --- | --- | --- |
| PPTX parsing/rendering and workspace prerequisites | `a008692a6a11d17f2f5a6adb90225a222e66fac6` | `e9726e5b71` |
| MP4 metadata and complete audio/video decode | `60f948bd809d2f4d8716d1242e11f6eec620dfcd` | `cc6e23a1f5` |
| Workspace-bound Board/Fusion verifier lookup | `25847ebcbccbfcc5a36c009fb98e04ccd6af2f8b` | `43b4c81a67` |

The shared verifier Read now retains PDF, PPTX, MP4 and image handling. Each
document/video format reads complete captured source bytes, rejects line-window
arguments, and keeps its existing typed failures. Board/Fusion reads retain their
producer/workspace authority and full original records. The combined description
states that presentation animations and embedded playback are uninspected, and
MP4 decoding does not prove visual frame inspection or accessibility.

Merge resolutions preserve the base's Whisper installation actions, optional
model directory, official-client content projection, runtime error dispatch
callback, and CLI workspace argument. Both CI lanes retain Poppler, LibreOffice,
Python venv and FFmpeg dependencies plus the managed presentation fixture step.
Presentation and collaboration test registrations are both retained.

Source checks verified 21 component files byte-for-byte against their explicit
source heads. Dashboard, server, Keeper, agent_core and runtime files are unchanged
from the integration base. Thirty changed OCaml files passed parse-only checks;
Python syntax and diff checks passed. The existing setup suite passed 56 cases
with 12 native-only cases skipped. The changed-line DET gate passed. Logs and
machine-readable scope are adjacent.

These checks do not prove native compilation, installation, actual verifier
acceptance or browser behavior for this candidate. No local native build or
runtime mutation was performed. Prior component failures remain in their original
evidence directories. Board writer paths remain environment-derived; this
candidate does not prove isolation during live workspace reconfiguration.
