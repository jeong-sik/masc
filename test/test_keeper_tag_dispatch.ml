(** Regression tests for Keeper_tag_dispatch — Mod_control gate.

    Verifies that masc_pause_status (read-only) is allowed while
    lifecycle-mutating tools (masc_pause, masc_resume) are blocked. *)

open Alcotest
open Masc

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

(* Temp directory setup matching test_keeper_task_dispatch.ml pattern. *)
let with_workspace f =
  Eio_main.run @@ fun _env ->
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_tag_dispatch_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      (try
        let rec rm path =
          if Sys.is_directory path then begin
            Sys.readdir path |> Array.iter (fun f ->
              rm (Filename.concat path f));
            Unix.rmdir path
          end else
            Sys.remove path
        in
        rm dir
      with _ -> ()))
    (fun () ->
      let config = Workspace.default_config dir in
      let _msg = Workspace.init config ~agent_name:(Some "test-keeper") in
      f config)

let dispatch config name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_control
    ~name ~args:(`Assoc [])

let dispatch_inline ?(args = `Assoc []) config name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_inline
    ~name ~args

let dispatch_external ?(args = `Assoc []) config name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_external
    ~name ~args

(* masc_pause_status is read-only — should be allowed. *)
let test_pause_status_allowed () =
  with_workspace (fun config ->
    match dispatch config "masc_pause_status" with
    | Some tr when (Tool_result.is_success tr) -> ()
    | Some tr ->
        fail (Printf.sprintf "masc_pause_status should succeed, got error: %s"
          (Tool_result.message tr))
    | None ->
        fail "masc_pause_status returned None (tool not recognized)")

(* masc_pause mutates lifecycle — should be blocked. *)
let test_pause_blocked () =
  with_workspace (fun config ->
    match dispatch config "masc_pause" with
    | Some tr when not (Tool_result.is_success tr) ->
        check bool "error mentions blocked" true
          (contains_substring (Tool_result.message tr) "blocked")
    | Some _tr ->
        fail "masc_pause should be blocked in keeper context"
    | None ->
        fail "masc_pause returned None")

(* masc_resume mutates lifecycle — should be blocked. *)
let test_resume_blocked () =
  with_workspace (fun config ->
    match dispatch config "masc_resume" with
    | Some tr when not (Tool_result.is_success tr) ->
        check bool "error mentions blocked" true
          (contains_substring (Tool_result.message tr) "blocked")
    | Some _tr ->
        fail "masc_resume should be blocked in keeper context"
    | None ->
        fail "masc_resume returned None")

let test_approval_pending_external_allowed () =
  with_workspace (fun config ->
    match dispatch_external config "masc_approval_pending" with
    | Some tr when (Tool_result.is_success tr) ->
        (match Yojson.Safe.from_string (Tool_result.message tr) with
         | `List _ -> ()
         | _ -> fail "masc_approval_pending should return a JSON list")
    | Some tr ->
        fail (Printf.sprintf "masc_approval_pending should succeed: %s"
          (Tool_result.message tr))
    | None ->
        fail "masc_approval_pending returned None")

let test_approval_get_missing_id_rejected () =
  let tr =
    Keeper_tool_in_process_runtime.handle_masc_approval_result
      ~name:"masc_approval_get"
      ~args:(`Assoc [])
  in
  if Tool_result.is_success tr
  then fail "masc_approval_get should reject missing id"
  else check string "message" "id is required" (Tool_result.message tr)

let test_approval_get_not_found_rejected () =
  let args = `Assoc [ "id", `String "appr_missing" ] in
  let tr =
    Keeper_tool_in_process_runtime.handle_masc_approval_result
      ~name:"masc_approval_get"
      ~args
  in
  if Tool_result.is_success tr
  then fail "masc_approval_get should reject unknown id"
  else
    check bool "message mentions not found" true
      (contains_substring (Tool_result.message tr) "no longer pending")

let test_approval_resolve_allowed () =
  with_workspace (fun config ->
    let resolved = ref None in
    let id =
      Keeper_approval_queue.submit_pending
        ~keeper_name:"test-keeper"
        ~tool_name:"tool_edit_file"
        ~input:(`Assoc [ "path", `String "demo.txt" ])
        ~risk_level:Keeper_approval_queue.Critical
        ~base_path:config.base_path
        ~on_resolution:(fun decision -> resolved := Some decision)
        ()
    in
    let args =
      `Assoc [ "id", `String id; "decision", `String "approve" ]
    in
    let tr =
      Keeper_tool_in_process_runtime.handle_masc_approval_result
        ~name:"masc_approval_resolve"
        ~args
    in
    if Tool_result.is_success tr
    then
        (match !resolved with
         | Some Agent_sdk.Hooks.Approve -> ()
         | Some (Agent_sdk.Hooks.Reject reason) ->
             fail (Printf.sprintf "expected approve, got reject: %s" reason)
         | Some (Agent_sdk.Hooks.Edit _) ->
             fail "expected approve, got edit"
         | None -> fail "approval callback was not invoked")
    else
      fail (Printf.sprintf "masc_approval_resolve should succeed: %s"
        (Tool_result.message tr)))

let test_other_inline_blocked () =
  with_workspace (fun config ->
    match dispatch_inline config "masc_agents" with
    | Some tr when not (Tool_result.is_success tr) ->
        check bool "error mentions MCP context" true
          (contains_substring (Tool_result.message tr) "requires MCP session context")
    | Some _tr ->
        fail "masc_agents should remain blocked in keeper context"
    | None ->
        fail "masc_agents returned None")

let () =
  Alcotest.run "Keeper_tag_dispatch" [
    "Mod_control gate", [
      test_case "masc_pause_status allowed" `Quick test_pause_status_allowed;
      test_case "masc_pause blocked" `Quick test_pause_blocked;
      test_case "masc_resume blocked" `Quick test_resume_blocked;
    ];
    "Mod_inline gate", [
      test_case "other inline tools blocked" `Quick test_other_inline_blocked;
    ];
    "Mod_external gate", [
      test_case "masc_approval_pending allowed" `Quick
        test_approval_pending_external_allowed;
    ];
    "Approval handler", [
      test_case "masc_approval_get missing id rejected" `Quick
        test_approval_get_missing_id_rejected;
      test_case "masc_approval_get not found rejected" `Quick
        test_approval_get_not_found_rejected;
      test_case "masc_approval_resolve allowed" `Quick
        test_approval_resolve_allowed;
    ];
  ]
