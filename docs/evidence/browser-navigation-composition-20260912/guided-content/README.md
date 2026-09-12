# Guided visible-content composition

A third isolated run used the same server cd7, TUI c230, Codex subscription model
and page fixture. The site instruction now gives the exact handoff route for a
regions observation (scene read with the selected document/node scope) and says
expectedUrl is supported only for scene/regions. It retains the author/owner
distinction introduced in the preceding experiment.

The typed execution-ID audit finds **6 outer calls, 0 failed calls and 3 successful
content compositions**: load browser-lanes, load the site instruction, read the
observed navigation region, then navigate/read Alpha, Beta and Gamma. Complete
outer result strings total 35,416 UTF-8 bytes, including the newly loaded base
Skill; this is not provider wire input size. Observed completion was 35.537 seconds.
One run is not proof of deterministic skill selection or causal latency improvement.

The answer reports Alpha's owner as unspecified, Joon/Sora as explicitly assigned,
the two Mina requests, superseded Alpha decision, current decisions and message
links. Scene results have truncated=false; claims remain limited to displayed
fixture content. No actual Slack session was used.

This run's TUI captured **all three current URL/heading/message pairs in 43
complete frames**, with no input after Keeper start. That does not invalidate
[the preceding missed-page result](../content-shortcut/README.md): cadence sometimes
observes intermediate visits and sometimes does not. A recorded-observation
reader is still required to make those pages inspectable after a rapid sweep.
The TUI reads the full visible page while the Keeper receives the same content
through the composition; snapshot times are independent, not a single atomic
shared capture.

The complete raw tool results, durable receipt previews and typed outer execution
IDs are retained for joining. Larger previews are truncated in the receipt store;
full results come from exact tool_use_id-matched native trace events. The actual
Firefox screenshot and xterm replays of captured TUI bytes retain their separate
provenance. User binaries and live services were not changed.
