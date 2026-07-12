open Alcotest
open Masc
module Opc = Operator_pending_confirm

let na = Opc.normalized_actor

let temp_dir () =
  Filename.temp_dir "test_operator_pending_confirm_" ""

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let test_explicit_raw () =
  check string "explicit raw" "alice" (na ~context_actor:"" (Some "alice"))

let test_raw_trimmed () =
  check string "raw trimmed" "bob" (na ~context_actor:"" (Some "  bob  "))

let test_empty_raw_uses_context () =
  check string "empty raw" "ctx-agent" (na ~context_actor:"ctx-agent" (Some ""))

let test_none_uses_context () =
  check string "none" "ctx-agent" (na ~context_actor:"ctx-agent" None)

let test_blank_context_returns_unknown () =
  check string "blank context" "unknown" (na ~context_actor:"" None)

let test_unknown_context_returns_unknown () =
  check string "unknown context" "unknown" (na ~context_actor:"unknown" None)

let test_whitespace_context_returns_unknown () =
  check string "whitespace context" "unknown" (na ~context_actor:"  " None)

let pending_confirm_fixture token =
  { Opc.token = token
  ; trace_id = "ops_test"
  ; actor = "operator"
  ; action_type = "namespace_pause"
  ; target_type = Operator_action_constants.workspace_target_type
  ; target_id = None
  ; payload = `Assoc []
  ; delegated_tool = "masc_pause"
  ; created_at = Masc_domain.now_iso ()
  ; expires_at = None
  }

let test_upsert_reports_persistence_failure () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      Unix.mkdir (Opc.pending_confirms_path config) 0o755;
      match Opc.upsert_pending_confirm config (pending_confirm_fixture "token-upsert") with
      | Ok () -> fail "upsert should report persistence failure"
      | Error msg ->
          check bool "error mentions local write" true
            (String.contains msg ':'
            && String.contains msg Filename.dir_sep.[0]
            && String.length msg > 0))

let test_remove_reports_persistence_failure () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      Workspace_utils.mkdir_p (Opc.operator_dir config);
      (match
         Opc.write_pending_confirms config
           [ pending_confirm_fixture "token-remove" ]
       with
      | Ok () -> ()
      | Error msg -> fail msg);
      Sys.remove (Opc.pending_confirms_path config);
      Unix.mkdir (Opc.pending_confirms_path config) 0o755;
      match Opc.remove_pending_confirm config "token-remove" with
      | Ok () -> fail "remove should report persistence failure"
      | Error msg ->
          check bool "error mentions local write" true
            (String.contains msg ':'
            && String.contains msg Filename.dir_sep.[0]
            && String.length msg > 0))

let tests =
  [
    test_case "explicit raw" `Quick test_explicit_raw;
    test_case "raw trimmed" `Quick test_raw_trimmed;
    test_case "empty raw uses context" `Quick test_empty_raw_uses_context;
    test_case "none uses context" `Quick test_none_uses_context;
    test_case "blank context returns unknown" `Quick test_blank_context_returns_unknown;
    test_case "unknown context returns unknown" `Quick test_unknown_context_returns_unknown;
    test_case "whitespace context returns unknown" `Quick test_whitespace_context_returns_unknown;
    test_case "upsert reports persistence failure" `Quick test_upsert_reports_persistence_failure;
    test_case "remove reports persistence failure" `Quick test_remove_reports_persistence_failure;
  ]

let () = run "normalized_actor" [ ("normalized_actor", tests) ]
