(** What [Exec_policy_log_sanitize.sanitize_parts] hides in a logged command.

    The IR path splits a command into words before this runs, so the match
    cannot lean on the whole-command marker check: every [key=value] word
    and every word after a sensitive flag is judged on its own. Each case
    below is a shape that used to reach the log in clear. *)

let check_hidden name parts secret =
  let logged = Exec_policy_log_sanitize.sanitize_parts parts in
  Alcotest.(check bool)
    (Printf.sprintf "%s hides %s" name secret)
    false
    (String_util.contains_substring logged secret)
;;

let uppercase_assignment_redacts () =
  check_hidden "uppercase TOKEN=" [ "deploy"; "TOKEN=opaque-hunter2" ] "opaque-hunter2";
  check_hidden "mixed-case Password=" [ "run"; "Password=s3cr3t" ] "s3cr3t"
;;

let lowercase_assignment_still_redacts () =
  let logged = Exec_policy_log_sanitize.sanitize_parts [ "run"; "token=abc123" ] in
  Alcotest.(check string) "prefix kept, value masked" "run token=[REDACTED]" logged
;;

let secret_flags_mask_the_next_word () =
  check_hidden "--secret" [ "deploy"; "--secret"; "abc123" ] "abc123";
  check_hidden "--apikey" [ "deploy"; "--apikey"; "abc123" ] "abc123";
  check_hidden "--client-secret" [ "deploy"; "--client-secret"; "abc123" ] "abc123"
;;

let innocent_words_pass_through () =
  let logged =
    Exec_policy_log_sanitize.sanitize_parts [ "ls"; "-la"; "/tmp/scratch" ]
  in
  Alcotest.(check string) "unchanged" "ls -la /tmp/scratch" logged
;;

let () =
  Alcotest.run
    "exec_policy_log_sanitize"
    [ ( "sanitize_parts"
      , [ Alcotest.test_case "uppercase assignment redacts" `Quick
            uppercase_assignment_redacts
        ; Alcotest.test_case "lowercase assignment still redacts" `Quick
            lowercase_assignment_still_redacts
        ; Alcotest.test_case "secret flags mask the next word" `Quick
            secret_flags_mask_the_next_word
        ; Alcotest.test_case "innocent words pass through" `Quick
            innocent_words_pass_through
        ] )
    ]
;;
