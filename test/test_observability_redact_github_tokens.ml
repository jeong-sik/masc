(* Verifies the GitHub token prefix patterns in Observability_redact. The
   installation token (ghs_) is the new case added by RFC-0236 §10; the others
   (ghp_/gho_/ghu_) are covered alongside it so a future regression in any
   prefix family is caught here rather than at a leak. The token value is not
   in any provisioned secret file — the prefix structure alone must mask it. *)

let redact s = Masc.Observability_redact.redact_text s

let test_github_token_prefixes () =
  List.iter
    (fun (label, token) ->
      let masked = redact token in
      Alcotest.(check bool)
        (label ^ " masked")
        true
        (not (String.equal masked token)))
    [ "ghp (classic PAT)", "ghp_0123456789abcdefghijklmnopqrstuvwx"
    ; "ghs (installation)", "ghs_0123456789abcdefghijklmnopqrstuvwx"
    ; "gho (oauth)", "gho_0123456789abcdefghijklmnopqrstuvwx"
    ; "ghu (user)", "ghu_0123456789abcdefghijklmnopqrstuvwx"
    ]
;;

let () =
  Alcotest.run
    "observability_redact_github_tokens"
    [ ( "prefixes"
      , [ Alcotest.test_case "github_token_prefixes" `Quick test_github_token_prefixes ] )
    ]
;;
