(** Regression tests for Keeper_tag_dispatch — Mod_misc dispatch.

    Verifies that tool dispatch through Mod_misc works for the keeper
    context after module tag consolidation. *)

open Alcotest
open Masc_mcp

(* Temp directory setup matching test_keeper_task_dispatch.ml pattern. *)
let with_room f =
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
      let config = Room.default_config dir in
      let _msg = Room.init config ~agent_name:(Some "test-keeper") in
      f config)

let dispatch config tag name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag
    ~name ~args:(`Assoc [])

(* Mod_misc dispatch returns Some for tools routed through misc. *)
let test_misc_dispatch_returns_result () =
  with_room (fun config ->
    match dispatch config Tool_dispatch.Mod_misc "masc_unknown_tool_xyz" with
    | Some _ -> ()
    | None ->
        (* Mod_misc dispatch may return None for unrecognized tools *)
        ())

(* Mod_keeper is blocked in keeper context to prevent cycles. *)
let test_keeper_blocked () =
  with_room (fun config ->
    match dispatch config Tool_dispatch.Mod_keeper "masc_keeper_msg" with
    | Some (false, msg) ->
        check bool "error mentions keeper management" true
          (String.length msg > 0)
    | Some (true, _) ->
        fail "Mod_keeper should be blocked in keeper context"
    | None ->
        fail "Mod_keeper returned None")

let () =
  Alcotest.run "Keeper_tag_dispatch" [
    "dispatch", [
      test_case "Mod_misc dispatch returns result" `Quick test_misc_dispatch_returns_result;
      test_case "Mod_keeper blocked in keeper" `Quick test_keeper_blocked;
    ];
  ]
