(** Backend tests for the current-only IDE codebase storage contract. *)

let test_canonical_url_of_remote_github_https () =
  let result = Ide_paths.canonical_url_of_remote "https://github.com/org/repo" in
  Alcotest.(check (option string)) "github HTTPS URL resolves to slug"
    (Some "github.com_org_repo") result
;;

let test_canonical_url_of_remote_scp_matches_https () =
  let https = Ide_paths.canonical_url_of_remote "https://github.com/org/repo.git" in
  let scp = Ide_paths.canonical_url_of_remote "git@github.com:org/repo.git" in
  Alcotest.(check (option string)) "scp and https resolve to same slug" https scp
;;

let test_canonical_url_of_remote_empty () =
  let result = Ide_paths.canonical_url_of_remote "" in
  Alcotest.(check (option string)) "empty URL returns None" None result
;;

let test_code_store_dir () =
  let result =
    Ide_paths.code_store_dir ~base_dir:"/tmp/masc" ~codebase:"github.com_org_repo"
  in
  Alcotest.(check string) "codebase store path"
    "/tmp/masc/.masc-ide/by-url/github.com_org_repo"
    result
;;

let () =
  Alcotest.run "IDE codebase resolution"
    [ ( "canonical_url_of_remote"
      , [ Alcotest.test_case "github HTTPS" `Quick test_canonical_url_of_remote_github_https
        ; Alcotest.test_case "scp matches HTTPS" `Quick
            test_canonical_url_of_remote_scp_matches_https
        ; Alcotest.test_case "empty URL" `Quick test_canonical_url_of_remote_empty
        ] )
    ; "code store", [ Alcotest.test_case "code_store_dir" `Quick test_code_store_dir ]
    ]
;;
