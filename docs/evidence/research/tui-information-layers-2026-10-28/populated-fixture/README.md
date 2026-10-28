# Populated, read-only fixture

This is a synthetic loopback server and private workspace for manual comparison,
not a MASC server or a regression test. The [fixture](fixture.py) serves eight
fabricated chat messages, a waiting inventory with one running row, 18 event
rows and one scheduled row, and an empty server-message page. Other reads
return 503; every POST returns 405. It does not accept credentials or start a
Keeper. Its workspace path and health identity are derived from the directory
passed on the command line. Use a fresh private directory, isolated environment
and free port for each observation.

At 18:26:35 KST on 2026-10-28, the same copied baseline executable described
in the [parent record](../README.md) displayed the [synthetic chat](baseline-chat.txt)
at 100×24 in tmux. The two saved HTTP responses are the fixture's
[waiting inventory](waiting-inventory.json) and [queued operations](queued-operations.json).
The baseline predates the Queue panel, so this observation does not establish
that the candidate can decode or display these queue rows. A later
[candidate observation](candidate-2732143/README.md) used the same fixture;
it does not establish real-server behavior or the later follow-up's behavior.

| File | SHA-256 |
| --- | --- |
| `fixture.py` | `374818af7daded45b8bb80a2e8cb16e9caa00c7eb4f8450762f8f48d0b95255d` |
| `baseline-chat.txt` | `0b3e8c856fcdf45f07f2d84f5457bfb06a716e1e74cdb28b4d6ce65602c46ffa` |
| `waiting-inventory.json` | `ea366ab70447e27c7204f773709586cb4bc8ce694fd87848a2349f1cca52ea32` |
| `queued-operations.json` | `9389e6512af6fefa0599e7a946ef8eb432546cec8eb92d674ad516e2b98d7f1e` |
