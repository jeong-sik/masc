; Gen4 compaction-layer [STATE] guard: keeper_summarizer scrubs
; [STATE]...[/STATE] from Text blocks before OAS default extractive
; summarization. Registered via Builder.with_summarizer (OAS 0.152.0).

(test
 (name test_keeper_summarizer)
 (modules test_keeper_summarizer)
 (libraries masc_test_deps))
