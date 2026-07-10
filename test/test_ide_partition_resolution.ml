(** Backend tests for IDE partition resolution — covers the public Ide_paths
    partition contract.

    NOTE: resolve_partition_for_query and resolve_partition_for_read require
    ~state (Mcp_server workspace config) which is complex to mock. These are
    tested at integration level. This file covers exported pure functions.

    Types verified against:
    - lib/agent_observation/agent_observation.ml (codebase_partition) *)

(* --- partition metadata tests --- *)

let test_partition_kind_labels () =
  let cases =
    [ Ide_paths.By_url "github.com_org_repo", "by_url"
    ; Ide_paths.No_canonical_url, "no_canonical_url"
    ; Ide_paths.Unmatched, "unmatched"
    ; Ide_paths.Base_unresolved, "base_unresolved"
    ; Ide_paths.Legacy_default, "legacy_default"
    ]
  in
  List.iter
    (fun (partition, expected) ->
      Alcotest.(check string) expected expected (Ide_paths.partition_kind partition))
    cases
;;

let test_partition_orphan_flags () =
  Alcotest.(check bool) "By_url is not orphan" false
    (Ide_paths.partition_is_orphan (Ide_paths.By_url "github.com_org_repo"));
  List.iter
    (fun partition ->
      Alcotest.(check bool) "orphan reason" true
        (Ide_paths.partition_is_orphan partition))
    [ Ide_paths.No_canonical_url
    ; Ide_paths.Unmatched
    ; Ide_paths.Base_unresolved
    ; Ide_paths.Legacy_default
    ]
;;

(* --- Ide_paths public contract tests --- *)

(* canonical_url_of_remote : string -> string option
   Normalizes a remote URL to a slug. Returns None for malformed URLs. *)

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

let test_partition_store_dir_by_url () =
  let result =
    Ide_paths.partition_store_dir
      ~base_dir:"/tmp/masc"
      (Ide_paths.By_url "github.com_org_repo")
  in
  Alcotest.(check string) "by-url partition path"
    "/tmp/masc/.masc-ide/by-url/github.com_org_repo"
    result
;;

let test_partition_store_dir_orphan_reasons () =
  let expected = "/tmp/masc/.masc-ide/_orphan" in
  let check_partition partition =
    Alcotest.(check string) "orphan partition path" expected
      (Ide_paths.partition_store_dir ~base_dir:"/tmp/masc" partition)
  in
  List.iter check_partition
    [ Ide_paths.No_canonical_url
    ; Ide_paths.Unmatched
    ; Ide_paths.Base_unresolved
    ; Ide_paths.Legacy_default
    ]
;;

(* --- test suite --- *)

let () =
  Alcotest.run "IDE partition resolution"
    [ ( "partition metadata"
      , [ Alcotest.test_case "kind labels" `Quick test_partition_kind_labels
        ; Alcotest.test_case "orphan flags" `Quick test_partition_orphan_flags
        ] )
    ; ( "canonical_url_of_remote"
      , [ Alcotest.test_case "github HTTPS" `Quick test_canonical_url_of_remote_github_https
        ; Alcotest.test_case "scp matches HTTPS" `Quick
            test_canonical_url_of_remote_scp_matches_https
        ; Alcotest.test_case "empty URL" `Quick test_canonical_url_of_remote_empty
        ] )
    ; ( "partition_store_dir"
      , [ Alcotest.test_case "By_url" `Quick test_partition_store_dir_by_url
        ; Alcotest.test_case "orphan reasons" `Quick
            test_partition_store_dir_orphan_reasons
        ] )
    ]
;;
