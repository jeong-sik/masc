(** Regression tests for Keeper_tag_dispatch — Mod_control routing.

    Verifies that control tools route through the same typed dispatcher in
    Keeper context. *)

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

let dispatch_inline config name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_inline
    ~name ~args:(`Assoc [])

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

let test_pause_allowed () =
  with_workspace (fun config ->
    match dispatch config "masc_pause" with
    | Some tr when Tool_result.is_success tr -> ()
    | Some tr ->
        failf "masc_pause should succeed: %s" (Tool_result.message tr)
    | None ->
        fail "masc_pause returned None")

let test_resume_allowed () =
  with_workspace (fun config ->
    match dispatch config "masc_resume" with
    | Some tr when Tool_result.is_success tr -> ()
    | Some tr ->
        failf "masc_resume should succeed: %s" (Tool_result.message tr)
    | None ->
        fail "masc_resume returned None")

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
    "Mod_control routing", [
      test_case "masc_pause_status allowed" `Quick test_pause_status_allowed;
      test_case "masc_pause allowed" `Quick test_pause_allowed;
      test_case "masc_resume allowed" `Quick test_resume_allowed;
    ];
    "Mod_inline gate", [
      test_case "inline tools blocked" `Quick test_other_inline_blocked;
    ];
  ]
