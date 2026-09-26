# Incomplete agenda comparison — startup failure

[Run 36256591061](https://github.com/jeong-sik/masc/actions/runs/36256591061)
failed during startup of **baseline repetition 3**. Its failure receipt has
zero samples, no visible-keeper preflight and no retained Channels snapshot.
The expected `Health: ` text did not arrive within the existing 10-second
setup wait. The reconstructed terminal shows no overview data and a clipped
`HTTP [refresh f…` status; the underlying fetch error is not available here.
No network, fixture, or product root cause is inferred from that clipped text.

The first two complete pairs retain 400 acknowledgements and four draft
checks. The third candidate session did not run. These partial samples are
preserved but are not aggregated into a completed performance result.
The workflow failure does not identify a regression in the candidate agenda
change: the failing source is the baseline, before measured input begins.

Artifact metadata/ZIP digest and all 20 members were checked. The only public
normalization is the CI checkout prefix in redaction.json. Raw failure stderr
retains the full terminal output; failed-screen.txt reconstructs it with the
same recorded observer helper. Both source identities and completed-session
binary hashes match their receipts.

A single fresh [retry 36257181447](https://github.com/jeong-sik/masc/actions/runs/36257181447)
uses the same artifacts, observer and three-pair protocol. Its observations
must remain separate; this failed attempt is not replaced by the retry.
No local OCaml build, candidate latency gain, deployment or 0.1ms result is
claimed.
