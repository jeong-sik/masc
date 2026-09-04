; build_prompt hands one variable list to three review templates, and a
; variable the template does not use is dropped silently. Both Goal templates
; dropped lookup_section, so the Goal verifier held read tools it was never
; told about (masc #29250).

; The prompts are read from config/prompts at runtime, not crunched into the
; library, so without this dep an edit under that directory returns a cached
; pass. Two of these cases exist to fail when the completion prompt is
; reworded — the mechanism they rely on does not run without it.
(test
 (name test_review_prompt_sections_reach_the_model)
 (modules test_review_prompt_sections_reach_the_model)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps))
