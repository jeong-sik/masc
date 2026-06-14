; Pins the filesystem-grounded Cwd_not_directory hint: a stale
; "repos/masc-mcp" path surfaces the real "repos/" entries read via
; Sys.readdir, with no rename table or substring matching.

(test
 (name test_exec_policy_cwd_hint)
 (modules test_exec_policy_cwd_hint)
 (libraries masc_test_deps))
