(** Regression tests for Keeper_tag_dispatch — Mod_control routing.

    Verifies that control tools route through the same typed dispatcher in
    Keeper context. *)

open Alcotest
open Masc

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
    ~config ~keeper_name:"test-keeper" ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_control
    ~name ~args:(`Assoc [])

let dispatch_inline config name =
  Keeper_tag_dispatch.dispatch
    ~config ~keeper_name:"test-keeper" ~agent_name:"test-keeper"
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
    match dispatch_inline config "masc_get_metrics" with
    | Some tr when not (Tool_result.is_success tr) ->
        check bool "error mentions MCP context" true
          (String_util.contains_substring (Tool_result.message tr) "requires MCP session context")
    | Some _tr ->
        fail "masc_get_metrics should remain blocked in keeper context"
    | None ->
        fail "masc_get_metrics returned None")

let test_task_author_uses_keeper_name () =
  with_workspace (fun config ->
    let result =
      Keeper_tag_dispatch.dispatch
        ~config
        ~keeper_name:"keeper-handle"
        ~agent_name:"keeper-actor"
        ~tag:Tool_dispatch.Mod_task
        ~name:"masc_add_task"
        ~args:(`Assoc [ "title", `String "Keeper-authored fallback task" ])
    in
    (match result with
     | Some tr when Tool_result.is_success tr -> ()
     | Some tr ->
       failf "masc_add_task should succeed: %s" (Tool_result.message tr)
     | None -> fail "masc_add_task returned None");
    match (Workspace.read_backlog config).tasks with
    | [ task ] ->
      check
        (option string)
        "fallback task author is the stable keeper handle"
        (Some "keeper-handle")
        task.created_by
    | tasks ->
      failf "expected one fallback-created task, got %d" (List.length tasks))
;;

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun f -> remove_tree (Filename.concat path f));
      Unix.rmdir path
    end else Sys.remove path

(* The library follows the keeper's workspace config, not MASC_BASE_PATH.
   [Workspace.default_config] points the variable at [config.base_path] in a
   test executable, so the decoy is set after [with_workspace] built the
   config: from here on the two disagree, as they do in a process whose
   environment names a different workspace than the request. *)
let test_library_follows_config_not_env () =
  with_workspace (fun config ->
    let decoy =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "test_keeper_tag_dispatch_decoy_%d" (Random.int 1_000_000))
    in
    Unix.mkdir decoy 0o755;
    let original = Sys.getenv_opt "MASC_BASE_PATH" in
    Unix.putenv "MASC_BASE_PATH" decoy;
    Fun.protect
      ~finally:(fun () ->
        Unix.putenv "MASC_BASE_PATH" (Option.value original ~default:"");
        remove_tree decoy)
      (fun () ->
        let dispatch_library name args =
          Keeper_tag_dispatch.dispatch
            ~config ~keeper_name:"test-keeper" ~agent_name:"test-keeper"
            ~tag:Tool_dispatch.Mod_library ~name ~args
        in
        (match
           dispatch_library "masc_library_add"
             (`Assoc
               [ "title", `String "Keeper Workspace Doc"
               ; "content", `String "written through the keeper path"
               ; "source", `String "observation"
               ])
         with
         | Some tr when Tool_result.is_success tr -> ()
         | Some tr -> failf "masc_library_add should succeed: %s" (Tool_result.message tr)
         | None -> fail "masc_library_add returned None");
        let config_library = Tool_library.library_root ~base_path:config.base_path in
        check bool "document written under the config workspace" true
          (Sys.file_exists config_library
           && Array.exists
                (fun f -> Filename.check_suffix f ".md")
                (Sys.readdir config_library));
        check bool "nothing written under MASC_BASE_PATH" false
          (Sys.file_exists (Tool_library.library_root ~base_path:decoy));
        match
          dispatch_library "masc_library_read"
            (`Assoc [ "topic", `String "Keeper Workspace Doc" ])
        with
        | Some tr when Tool_result.is_success tr ->
          check bool "read finds it in the config workspace" true
            (String_util.contains_substring (Tool_result.message tr)
               "written through the keeper path")
        | Some tr -> failf "masc_library_read should succeed: %s" (Tool_result.message tr)
        | None -> fail "masc_library_read returned None"))
;;

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
    "Mod_task identity", [
      test_case
        "fallback task author uses keeper handle"
        `Quick
        test_task_author_uses_keeper_name;
    ];
    "Mod_library workspace", [
      test_case
        "library follows the config, not MASC_BASE_PATH"
        `Quick
        test_library_follows_config_not_env;
    ];
  ]
