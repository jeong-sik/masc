(** Regression tests for Keeper_tag_dispatch — Mod_control gate.

    Verifies that masc_pause_status (read-only) is allowed while
    lifecycle-mutating tools (masc_pause, masc_resume) are blocked. *)

open Alcotest
open Masc_mcp

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
      let config = Coord.default_config dir in
      let _msg = Coord.init config ~agent_name:(Some "test-keeper") in
      f config)

let dispatch config name =
  Keeper_tag_dispatch.dispatch
    ~config ~agent_name:"test-keeper"
    ~tag:Tool_dispatch.Mod_control
    ~name ~args:(`Assoc [])

(* masc_pause_status is read-only — should be allowed. *)
let test_pause_status_allowed () =
  with_room (fun config ->
    match dispatch config "masc_pause_status" with
    | Some (true, _msg) -> ()
    | Some (false, msg) ->
        fail (Printf.sprintf "masc_pause_status should succeed, got error: %s" msg)
    | None ->
        fail "masc_pause_status returned None (tool not recognized)")

(* masc_pause mutates lifecycle — should be blocked. *)
let test_pause_blocked () =
  with_room (fun config ->
    match dispatch config "masc_pause" with
    | Some (false, msg) ->
        check bool "error mentions blocked" true
          (contains_substring msg "blocked")
    | Some (true, _) ->
        fail "masc_pause should be blocked in keeper context"
    | None ->
        fail "masc_pause returned None")

(* masc_resume mutates lifecycle — should be blocked. *)
let test_resume_blocked () =
  with_room (fun config ->
    match dispatch config "masc_resume" with
    | Some (false, msg) ->
        check bool "error mentions blocked" true
          (contains_substring msg "blocked")
    | Some (true, _) ->
        fail "masc_resume should be blocked in keeper context"
    | None ->
        fail "masc_resume returned None")

let () =
  Alcotest.run "Keeper_tag_dispatch" [
    "Mod_control gate", [
      test_case "masc_pause_status allowed" `Quick test_pause_status_allowed;
      test_case "masc_pause blocked" `Quick test_pause_blocked;
      test_case "masc_resume blocked" `Quick test_resume_blocked;
    ];
  ]
