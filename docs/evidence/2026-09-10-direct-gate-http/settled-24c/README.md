# Settled direct Gate continuation

CI candidate `24c00e3536d940113a0be47b051673b62e6715fc`, run `34414355454`, artifact `10128768952`, was executed using the real server and a fresh home-directory Docker workspace. The six targeted suites in run `34414352814` passed. No local build was used.

The same admitted operation completed after its real Write, durable Execute approval, rate-limit deferral, approved replay, and alternate-runtime continuation. The actual `keeper_artifact_read` read the replay output identified by SHA-256 `64956a6e4b4c6c404a8c10bd8c213f352887437438f74b85d69621d2ab564462` (655 bytes). Original input digest and checkpoint ownership were preserved. Both effects occurred once; the transcript contains one user and one terminal assistant row.

Unlike the earlier e95 observation, this run recorded continuation settlement and then explicitly acknowledged the spent Gate wake **without a model turn** (`continuation.txt`). Provider requests remained four through server shutdown. The run handle completed with exit code zero; no replacement operation was submitted.

This proves this bounded successful approval path with a synthetic provider and real server, Gate authority, Docker effect, and artifact read. It does not prove semantic LLM quality, attachment/channel input, server restart, denial delivery, or automatic recovery from unavailable Gate authority. Those remain distinct from this runtime observation.
