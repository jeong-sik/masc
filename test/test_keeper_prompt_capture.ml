(* The extra system context a turn assembled, captured as text. Until now the
   turn record kept each block's bytes and digest — how much, never what.

   The properties under test: the text survives the round trip unchanged, the
   store stays one turn (a capture overwrites, it does not accumulate), an
   unknown block id is rejected rather than dropped, and "never captured" is a
   different answer from "captured and malformed". *)

module Capture = Masc.Keeper_prompt_capture
module Block_id = Prompt_block_id

let keeper = "test-keeper"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-capture-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  f config
;;

(* A recall block with the shape a live keeper writes, including the newlines
   and the leading rule that a naive JSON round trip would be tempted to trim. *)
let recall_text =
  "--- Memory OS Recall ---\n\
   LLM-selected current memory, revision 223, updated 2026-08-06T00:00:00Z.\n\
   [blocker] task-195 is blocked by the openssl link drift.\n"
;;

let test_text_survives_the_round_trip () =
  with_workspace (fun config ->
    Capture.write
      ~config
      ~keeper
      ~trace_id:"trace-a"
      ~absolute_turn:17534
      ~blocks:
        [ Block_id.Dynamic_context, "board: 4 unclaimed\n"
        ; Block_id.Memory_os_recall, recall_text
        ]
      ~assembled:(Some ("board: 4 unclaimed\n" ^ recall_text));
    match Capture.read ~config ~keeper with
    | Error error -> Alcotest.failf "read failed: %s" (Capture.read_error_to_string error)
    | Ok capture ->
      Alcotest.(check string) "trace id" "trace-a" capture.trace_id;
      Alcotest.(check int) "turn" 17534 capture.absolute_turn;
      Alcotest.(check (list string))
        "blocks keep assembly order"
        [ "dynamic_context"; "memory_os_recall" ]
        (List.map
           (fun (b : Capture.block) -> Block_id.to_string b.id)
           capture.blocks);
      (match capture.blocks with
       | [ _; recall ] ->
         Alcotest.(check string) "recall text is byte-identical" recall_text recall.text
       | _ -> Alcotest.fail "expected two blocks");
      Alcotest.(check (option string))
        "assembled text is byte-identical"
        (Some ("board: 4 unclaimed\n" ^ recall_text))
        capture.assembled)
;;

(* One turn, not a history. A prompt history would grow at the rate the keeper
   runs, which is the cost this subsystem exists to bound. *)
let test_capture_overwrites_rather_than_accumulates () =
  with_workspace (fun config ->
    Capture.write ~config ~keeper ~trace_id:"trace-a" ~absolute_turn:1
      ~blocks:[ Block_id.Keeper_instructions, "first" ] ~assembled:(Some "first");
    Capture.write ~config ~keeper ~trace_id:"trace-b" ~absolute_turn:2
      ~blocks:[ Block_id.Keeper_instructions, "second" ] ~assembled:(Some "second");
    match Capture.read ~config ~keeper with
    | Error error -> Alcotest.failf "read failed: %s" (Capture.read_error_to_string error)
    | Ok capture ->
      Alcotest.(check int) "only the last turn remains" 2 capture.absolute_turn;
      Alcotest.(check (option string)) "and its text" (Some "second") capture.assembled)
;;

(* [None] is a turn that assembled no blocks. An empty string would be a block
   that rendered to nothing — a different observation. *)
let test_no_blocks_is_none_not_empty_string () =
  with_workspace (fun config ->
    Capture.write ~config ~keeper ~trace_id:"trace-a" ~absolute_turn:1 ~blocks:[]
      ~assembled:None;
    match Capture.read ~config ~keeper with
    | Error error -> Alcotest.failf "read failed: %s" (Capture.read_error_to_string error)
    | Ok capture ->
      Alcotest.(check (option string)) "assembled is absent" None capture.assembled;
      Alcotest.(check int) "no blocks" 0 (List.length capture.blocks))
;;

let test_never_captured_is_its_own_error () =
  with_workspace (fun config ->
    match Capture.read ~config ~keeper:"never-ran" with
    | Ok _ -> Alcotest.fail "a keeper that never assembled must not read as captured"
    | Error Capture.Not_captured -> ()
    | Error error ->
      Alcotest.failf "expected Not_captured, got %s" (Capture.read_error_to_string error))
;;

let test_invalid_keeper_name_is_refused () =
  with_workspace (fun config ->
    match Capture.read ~config ~keeper:"../escape" with
    | Ok _ -> Alcotest.fail "an invalid keeper name must not resolve"
    | Error (Capture.Unknown_keeper _) -> ()
    | Error error ->
      Alcotest.failf "expected Unknown_keeper, got %s" (Capture.read_error_to_string error))
;;

(* A block id this build does not know is rejected, not dropped. Dropping it
   would make a capture written by a wider build read as a shorter one, and the
   operator comparing block counts is the one who would be misled. *)
let test_unknown_block_id_is_malformed_not_dropped () =
  with_workspace (fun config ->
    Capture.write ~config ~keeper ~trace_id:"trace-a" ~absolute_turn:1
      ~blocks:[ Block_id.Keeper_instructions, "text" ] ~assembled:(Some "text");
    let path = Capture.path_for config keeper in
    let contents =
      match Fs_compat.load_file_opt path with
      | Some c -> c
      | None -> Alcotest.fail "capture was not written"
    in
    let widened =
      Str.global_replace (Str.regexp_string {|"id":"keeper_instructions"|}) {|"id":"future_block"|} contents
    in
    (match Fs_compat.save_file_atomic path widened with
     | Ok () -> ()
     | Error detail -> Alcotest.failf "rewrite failed: %s" detail);
    match Capture.read ~config ~keeper with
    | Ok capture ->
      Alcotest.failf
        "an unknown block id must not decode; got %d blocks"
        (List.length capture.blocks)
    | Error (Capture.Malformed detail) ->
      Alcotest.(check bool)
        "the reason quotes the unknown id"
        true
        (Astring.String.is_infix ~affix:"future_block" detail)
    | Error error ->
      Alcotest.failf "expected Malformed, got %s" (Capture.read_error_to_string error))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper prompt capture"
    [ ( "round trip"
      , [ Alcotest.test_case "text survives the round trip" `Quick
            test_text_survives_the_round_trip
        ; Alcotest.test_case "no blocks is None, not empty string" `Quick
            test_no_blocks_is_none_not_empty_string
        ] )
    ; ( "bounded"
      , [ Alcotest.test_case "capture overwrites rather than accumulates" `Quick
            test_capture_overwrites_rather_than_accumulates
        ] )
    ; ( "boundaries"
      , [ Alcotest.test_case "never captured is its own error" `Quick
            test_never_captured_is_its_own_error
        ; Alcotest.test_case "invalid keeper name is refused" `Quick
            test_invalid_keeper_name_is_refused
        ; Alcotest.test_case "unknown block id is malformed, not dropped" `Quick
            test_unknown_block_id_is_malformed_not_dropped
        ] )
    ]
;;
