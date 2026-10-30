# Metadata initial-screen scan

Followup to #41195 comment4178494830. Consume the initialized terminal snapshot before scrolling instead of decoding the same bytes twice. Each later snapshot is decoded after the page key and drain. Token-set, viewport, applied Gate and bounded scan assertions are unchanged; no empty placeholder is introduced.

Actual full metadata PTY passes (handle31570 exit0) on retained product source6fc062feee7e33a271e09dc155d9feffee923704 and binary196d9fce8ecced88ab44ac424d300d9744299ee1f707d323eac9c0803d7bae0e. Ruff and Pyright pass with zero diagnostics. This fixture-only change does not rebuild product code or qualify current main/fullCI. Raw logs are unchanged.
