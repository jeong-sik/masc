# Approval authority interface module path

Base: f85bed9f977cb1780f687494372e7b57da612cb3.

Independent source review found the predecessor's retirement signature referred to Tui_decode without qualification. The implementation opens Masc_tui_types and receives its module alias; that open does not apply to the .mli. The authority Dune library has no -open Masc, so the interface name was unbound. The original finding and the earlier bounded PASS remain separate historical verdicts.

Both interface row types now reference Masc_tui_types.Tui_decode, a dependency already declared by this library. Product behavior is unchanged. Full changed interface and existing alias/Dune source inspected; git diff --check passed. No local Dune build/test was executed under execution_protocol. Corrected cumulative source review requested; no runtime, screenshot, CI or formal approval claim.
