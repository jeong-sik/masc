; get_prompt answers "" for a missing key and the startup check only logs, so a
; broken prompt shipped as a quietly shorter prompt. This makes the prompt
; directory a CI gate (masc #29250).

(test
 (name test_prompt_templates_render)
 (modules test_prompt_templates_render)
 (libraries masc_test_deps))
