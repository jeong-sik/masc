(* Agent_observation.remote_url_syntax: which tokens are written as a git
   remote. The judge host context relies on this to keep relative paths,
   API endpoint paths, refspecs and gh's [owner/repo] shorthand out of the
   repository references it reports (#34401). *)

let accepts name token () =
  Alcotest.(check bool) name true (Agent_observation.remote_url_syntax token)
;;

let rejects name token () =
  Alcotest.(check bool) name false (Agent_observation.remote_url_syntax token)
;;

let () =
  Alcotest.run
    "remote_url_syntax"
    [ ( "written as a remote"
      , [ Alcotest.test_case "https" `Quick
            (accepts "https" "https://github.com/jeong-sik/masc.git")
        ; Alcotest.test_case "http" `Quick (accepts "http" "http://example.com/a/b")
        ; Alcotest.test_case "ssh://" `Quick
            (accepts "ssh://" "ssh://git@github.com/jeong-sik/masc")
        ; Alcotest.test_case "git://" `Quick (accepts "git://" "git://host/a/b")
        ; Alcotest.test_case "scp form" `Quick
            (accepts "scp form" "git@github.com:jeong-sik/masc.git")
        ; Alcotest.test_case "scheme case is not syntax" `Quick
            (accepts "uppercase scheme" "HTTPS://GitHub.com/a/b")
        ] )
    ; ( "not a remote"
      , [ Alcotest.test_case "owner/repo shorthand" `Quick
            (rejects "owner/repo" "jeong-sik/masc")
        ; Alcotest.test_case "relative path" `Quick (rejects "relative path" "tmp/pr34356")
        ; Alcotest.test_case "api endpoint path" `Quick
            (rejects "api path" "repos/jeong-sik/masc/pulls/34356/update-branch")
        ; Alcotest.test_case "refspec" `Quick
            (rejects "refspec" "work34378:fix/the-compose-footer")
        ; Alcotest.test_case "email-like value" `Quick
            (rejects "email" "someone@example.com")
        ; Alcotest.test_case "config override" `Quick
            (rejects "config override" "credential.helper=!gh auth git-credential")
        ; Alcotest.test_case "empty" `Quick (rejects "empty" "")
        ; Alcotest.test_case "whitespace" `Quick (rejects "whitespace" "   ")
        ] )
    ]
;;
