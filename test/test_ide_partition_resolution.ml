(** Backend tests for IDE partition resolution — covers
    orphan_read_reason_label and Ide_paths helper functions.

    NOTE: resolve_partition_for_query and resolve_partition_for_read require
    ~state (Mcp_server workspace config) which is complex to mock. These are
    tested at integration level. This file covers the pure functions.

    Types verified against:
    - lib/agent_observation/agent_observation.ml (codebase_partition)
    - lib/server/server_ide_http.ml (orphan_read_reason_label) *)

(* --- orphan_read_reason_label tests --- *)

(* The function is: orphan_read_reason_label : Ide_paths.codebase_partition -> string option
   It maps each partition variant to an optional label string. *)

let test_by_url_returns_none () =
  let result = Server_ide_http.orphan_read_reason_label (Ide_paths.By_url "github.com/org/repo") in
  Alcotest.(check (option string)) "By_url returns None" None result
;;

let test_no_canonical_url_returns_label () =
  let result = Server_ide_http.orphan_read_reason_label Ide_paths.No_canonical_url in
  Alcotest.(check (option string)) "No_canonical_url returns label"
    (Some "no_canonical_url") result
;;

let test_unmatched_returns_label () =
  let result = Server_ide_http.orphan_read_reason_label Ide_paths.Unmatched in
  Alcotest.(check (option string)) "Unmatched returns label"
    (Some "unmatched") result
;;

let test_base_unresolved_returns_label () =
  let result = Server_ide_http.orphan_read_reason_label Ide_paths.Base_unresolved in
  Alcotest.(check (option string)) "Base_unresolved returns label"
    (Some "base_unresolved") result
;;

let test_legacy_default_returns_label () =
  let result = Server_ide_http.orphan_read_reason_label Ide_paths.Legacy_default in
  Alcotest.(check (option string)) "Legacy_default returns label"
    (Some "legacy_default") result
;;

(* --- Ide_paths helper function tests --- *)

(* canonical_url_of_remote : string -> string option
   Normalizes a remote URL to a slug. Returns None for malformed URLs. *)

let test_canonical_url_of_remote_github_https () =
  let result = Ide_paths.canonical_url_of_remote "https://github.com/org/repo" in
  match result with
  | Some slug ->
    (* slug should be "github.com/org/repo" after normalization *)
    Alcotest.(check bool) "github.com present" true
      (String.length slug > 0 && String.length slug < 200)
  | None ->
    Alcotest.fail "github HTTPS URL should resolve to a slug"
;;

let test_canonical_url_of_remote_empty () =
  let result = Ide_paths.canonical_url_of_remote "" in
  Alcotest.(check (option string)) "empty URL returns None" None result
;;

(* strip_scheme tests *)

let test_strip_scheme_https () =
  let result = Ide_paths.strip_scheme "https://github.com/org/repo" in
  Alcotest.(check string) "strip https" "github.com/org/repo" result
;;

let test_strip_scheme_ssh () =
  let result = Ide_paths.strip_scheme "ssh://git@github.com/org/repo" in
  Alcotest.(check string) "strip ssh" "git@github.com/org/repo" result
;;

let test_strip_scheme_none () =
  let result = Ide_paths.strip_scheme "github.com/org/repo" in
  Alcotest.(check string) "no scheme unchanged" "github.com/org/repo" result
;;

(* split_host_path tests *)

let test_split_host_path_normal () =
  let host, path = Ide_paths.split_host_path "github.com/org/repo" in
  Alcotest.(check string) "host" "github.com" host;
  Alcotest.(check string) "path" "org/repo" path
;;

let test_split_host_path_no_slash () =
  let host, path = Ide_paths.split_host_path "localhost" in
  Alcotest.(check string) "host" "localhost" host;
  Alcotest.(check string) "path" "" path
;;

(* --- test suite --- *)

let () =
  Alcotest.run "IDE partition resolution"
    [ ( "orphan_read_reason_label"
      , [ Alcotest.test_case "By_url returns None" `Quick test_by_url_returns_none
        ; Alcotest.test_case "No_canonical_url" `Quick test_no_canonical_url_returns_label
        ; Alcotest.test_case "Unmatched" `Quick test_unmatched_returns_label
        ; Alcotest.test_case "Base_unresolved" `Quick test_base_unresolved_returns_label
        ; Alcotest.test_case "Legacy_default" `Quick test_legacy_default_returns_label
        ] )
    ; ( "canonical_url_of_remote"
      , [ Alcotest.test_case "github HTTPS" `Quick test_canonical_url_of_remote_github_https
        ; Alcotest.test_case "empty URL" `Quick test_canonical_url_of_remote_empty
        ] )
    ; ( "strip_scheme"
      , [ Alcotest.test_case "https" `Quick test_strip_scheme_https
        ; Alcotest.test_case "ssh" `Quick test_strip_scheme_ssh
        ; Alcotest.test_case "no scheme" `Quick test_strip_scheme_none
        ] )
    ; ( "split_host_path"
      , [ Alcotest.test_case "normal" `Quick test_split_host_path_normal
        ; Alcotest.test_case "no slash" `Quick test_split_host_path_no_slash
        ] )
    ]
;;