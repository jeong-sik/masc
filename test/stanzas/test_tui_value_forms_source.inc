; The paths of the sources the check reads. The rule depends on them, so
; building the test copies the current sources next to it: a run by hand
; does not read copies left from the last TUI build.
(rule
 (target tui_screen_sources.ml)
 (deps
  (glob_files %{project_root}/bin/masc_tui*.ml))
 (action
  (with-stdout-to
   %{target}
   (echo "let paths = {|%{deps}|}\n"))))

(test
 (name test_tui_value_forms_source)
 (modules test_tui_value_forms_source tui_screen_sources)
 (deps
  (glob_files %{project_root}/bin/masc_tui*.ml))
 (libraries alcotest))
