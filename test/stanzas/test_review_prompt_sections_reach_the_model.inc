; build_prompt hands one variable list to three review templates, and a
; variable the template does not use is dropped silently. Both Goal templates
; dropped lookup_section, so the Goal verifier held read tools it was never
; told about (masc #29250).

(test
 (name test_review_prompt_sections_reach_the_model)
 (modules test_review_prompt_sections_reach_the_model)
 (libraries masc_test_deps))
