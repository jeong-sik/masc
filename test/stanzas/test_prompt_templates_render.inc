; get_prompt answers "" for a missing key and the startup check only logs, so a
; broken prompt shipped as a quietly shorter prompt. This makes the prompt
; directory a CI gate (masc #29250).

; The gate reads that directory through DUNE_SOURCEROOT at run time, so until
; the dep below it was not one: a commit touching only config/prompts left this
; action up to date and dune ran nothing. A new {{variable}} added to a body
; without its vars line would have shipped, and reached production as an
; Unresolved variables error out of build_prompt, leaving the Task nonterminal.
(test
 (name test_prompt_templates_render)
 (modules test_prompt_templates_render)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps))
