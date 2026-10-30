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

let equals_form_secret_flags_redact () =
  (* The IR path hands [--secret=abc] over as one literal word, so the
     whole-word flag check never sees it: the assignment markers must. *)
  check_hidden "--secret=" [ "deploy"; "--secret=abc123" ] "abc123";
  check_hidden "--apikey=" [ "deploy"; "--apikey=abc123" ] "abc123";
  check_hidden "--client-secret=" [ "deploy"; "--client-secret=abc123" ] "abc123";
  check_hidden "--SECRET=" [ "deploy"; "--SECRET=abc123" ] "abc123";
  let logged =
    Exec_policy_log_sanitize.sanitize_parts [ "deploy"; "--secret=abc123" ]
  in
  Alcotest.(check string)
    "flag prefix kept, value masked"
    "deploy --secret=[REDACTED]"
    logged
;;

let innocent_words_pass_through () =
  let logged =
    Exec_policy_log_sanitize.sanitize_parts [ "ls"; "-la"; "/tmp/scratch" ]
  in
  Alcotest.(check string) "unchanged" "ls -la /tmp/scratch" logged
;;

let aws_assignments_redact_through_typed_commands () =
  let bin =
    match Masc_exec.Exec_program.of_string "env" with
    | Ok bin -> bin
    | Error _ -> Alcotest.fail "env is a nonempty executable"
  in
  List.iter
    (fun (key, value) ->
      let args = [ key ^ "=" ^ value; "AWS_REGION=us-east-1"; "deploy" ] in
      let command = String.concat " " ("env" :: args) in
      let ir = Masc_exec.Shell_ir.Simple
        { bin
        ; args = List.map
            (fun value -> Masc_exec.Shell_ir.Lit (value, Masc_exec.Shell_ir.default_meta))
            args
        ; env = []
        ; cwd = None
        ; redirects = []
        ; sandbox = Masc_exec.Sandbox_target.host ()
        }
      in
      let logged =
        Exec_policy_log_sanitize.sanitize_command_for_log_of_ir
          ~fallback_cmd:command ir
      in
      Alcotest.(check string) (key ^ " retains its name and the remaining command")
        ("env " ^ key ^ "=[REDACTED] AWS_REGION=us-east-1 deploy") logged)
    [ "AWS_SECRET_ACCESS_KEY", "opaque-access-secret"
    ; "AWS_ACCESS_KEY_ID", "opaque-access-id"
    ; "AWS_ACCESS_KEY", "opaque-access-key"
    ; "aws_SeCrEt_AcCeSs_KeY", "opaque-mixed-case"
    ; "OPENAI_API_KEY", "opaque-openai-value"
    ; "ANTHROPIC_API_KEY", "opaque-anthropic-value"
    ; "openai_ApI_kEy", "opaque-mixed-api-value"
    ; "AWS_BEARER_TOKEN_BEDROCK", "opaque-bedrock-value"
    ; "aws_BeArEr_ToKeN_bEdRoCk", "opaque-mixed-bedrock-value"
    ];
  Alcotest.(check string) "ordinary AWS configuration is not a credential"
    "env AWS_PROFILE=production AWS_REGION=us-east-1 deploy"
    (Exec_policy_log_sanitize.sanitize_parts
       [ "env"; "AWS_PROFILE=production"; "AWS_REGION=us-east-1"; "deploy" ])
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
        ; Alcotest.test_case "equals-form secret flags redact" `Quick
            equals_form_secret_flags_redact
        ; Alcotest.test_case "AWS assignments redact through typed commands" `Quick
            aws_assignments_redact_through_typed_commands
        ; Alcotest.test_case "innocent words pass through" `Quick
            innocent_words_pass_through
        ] )
    ]
;;
