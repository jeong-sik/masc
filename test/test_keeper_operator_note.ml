(* RFC-0366. An operator sentence that lives for one turn.

   The contract that matters is the lifetime: it renders once, and after that
   the record stays so "delivered" and "never existed" are different answers.
   The failure this store exists to prevent is the one-turn instruction that
   becomes permanent — #26729 — so a note that renders twice is the defect,
   not a cosmetic one. *)

module Note = Masc.Keeper_operator_note

let keeper = "test-keeper"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-note-%d-%d" (Unix.getpid ()) (Random.bits ()))
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

let put config text =
  match Note.write ~config ~keeper ~text ~created_by:"operator" with
  | Ok note -> note
  | Error error -> Alcotest.failf "write failed: %s" (Note.write_error_to_string error)
;;

(* The whole point. A note reaches one turn and no more; the second turn must
   see nothing, because a note that keeps rendering is a standing rule the
   operator never wrote. *)
let test_renders_once_then_never_again () =
  with_workspace (fun config ->
    ignore (put config "openssl decision landed; task-195 may resume");
    (match Note.pending ~config ~keeper with
     | None -> Alcotest.fail "first turn must see the note"
     | Some note ->
       Alcotest.(check bool)
         "the rendered block carries the text"
         true
         (match Note.render note with
          | Some block -> Astring.String.is_infix ~affix:"task-195 may resume" block
          | None -> false));
    Note.mark_consumed ~config ~keeper ~absolute_turn:17534;
    match Note.pending ~config ~keeper with
    | None -> ()
    | Some _ -> Alcotest.fail "a consumed note must not render on the next turn")
;;

(* mark_consumed used to swallow every read error the same way it swallows
   "there is no note". An unreadable note then left no trace at all, while the
   save arm beside it reports its failures. *)
let test_consumption_is_quiet_only_when_there_is_no_note () =
  with_workspace (fun config ->
    (* No note: the ordinary case, and nothing to report. *)
    Note.mark_consumed ~config ~keeper ~absolute_turn:1;
    (match Note.read ~config ~keeper with
     | Error Note.No_note -> ()
     | Error other ->
       Alcotest.failf "expected No_note, got %s" (Note.read_error_to_string other)
     | Ok _ -> Alcotest.fail "no note was written");
    (* An invalid keeper name is a read error, not an absent note. It must not
       reach the same arm. *)
    Note.mark_consumed ~config ~keeper:"../escape" ~absolute_turn:2;
    match Note.read ~config ~keeper:"../escape" with
    | Error (Note.Read_unknown_keeper _) -> ()
    | Error other ->
      Alcotest.failf "expected Read_unknown_keeper, got %s" (Note.read_error_to_string other)
    | Ok _ -> Alcotest.fail "an invalid keeper name must not read a note")
;;

(* Deleting the note on consumption would make these two states identical, and
   the first thing an operator asks is whether it went in. *)
let test_consumption_leaves_a_delivery_record () =
  with_workspace (fun config ->
    ignore (put config "note text");
    Note.mark_consumed ~config ~keeper ~absolute_turn:4242;
    match Note.read ~config ~keeper with
    | Error error ->
      Alcotest.failf
        "a consumed note must remain readable: %s"
        (Note.read_error_to_string error)
    | Ok note ->
      Alcotest.(check (option int)) "the turn that consumed it" (Some 4242) note.consumed_turn;
      Alcotest.(check bool) "and when" true (Option.is_some note.consumed_at);
      Alcotest.(check string) "text is unchanged" "note text" note.text)
;;

let test_no_note_and_consumed_note_are_different_answers () =
  with_workspace (fun config ->
    (match Note.read ~config ~keeper with
     | Error Note.No_note -> ()
     | Ok _ -> Alcotest.fail "an unwritten note must not read"
     | Error error ->
       Alcotest.failf "expected No_note, got %s" (Note.read_error_to_string error));
    ignore (put config "text");
    Note.mark_consumed ~config ~keeper ~absolute_turn:1;
    match Note.read ~config ~keeper, Note.pending ~config ~keeper with
    | Ok _, None -> ()
    | Ok _, Some _ -> Alcotest.fail "consumed note must not be pending"
    | Error _, _ -> Alcotest.fail "consumed note must still read")
;;

(* Not a queue. A queue accumulates, which is what the chat path already does
   and what a one-turn lifetime exists to avoid. *)
let test_writing_replaces_rather_than_queues () =
  with_workspace (fun config ->
    ignore (put config "first");
    ignore (put config "second");
    match Note.pending ~config ~keeper with
    | None -> Alcotest.fail "a fresh note must be pending"
    | Some note ->
      Alcotest.(check string) "only the latest survives" "second" note.text;
      Alcotest.(check (option int)) "and it is unconsumed" None note.consumed_turn)
;;

(* A new note after a consumed one is deliverable: replacement clears the
   stamp, otherwise the operator could never send a second instruction. *)
let test_new_note_after_consumption_is_deliverable () =
  with_workspace (fun config ->
    ignore (put config "first");
    Note.mark_consumed ~config ~keeper ~absolute_turn:1;
    ignore (put config "second");
    match Note.pending ~config ~keeper with
    | Some note -> Alcotest.(check string) "the new note is pending" "second" note.text
    | None -> Alcotest.fail "a note written after a consumed one must be deliverable")
;;

(* Truncating an instruction produces a different instruction, and the operator
   who wrote it would not know which one arrived. *)
let test_oversized_note_is_rejected_not_truncated () =
  with_workspace (fun config ->
    let huge = String.make (8 * 1024) 'x' in
    (match Note.write ~config ~keeper ~text:huge ~created_by:"operator" with
     | Ok _ -> Alcotest.fail "an oversized note must not be accepted"
     | Error (Note.Too_large _) -> ()
     | Error error ->
       Alcotest.failf "expected Too_large, got %s" (Note.write_error_to_string error));
    match Note.read ~config ~keeper with
    | Error Note.No_note -> ()
    | Ok _ -> Alcotest.fail "a rejected note must not be stored, truncated or otherwise"
    | Error error ->
      Alcotest.failf "expected No_note, got %s" (Note.read_error_to_string error))
;;

let test_empty_and_invalid_inputs_are_refused () =
  with_workspace (fun config ->
    (match Note.write ~config ~keeper ~text:"   \n " ~created_by:"operator" with
     | Error Note.Empty_text -> ()
     | Ok _ -> Alcotest.fail "whitespace is not an instruction"
     | Error error ->
       Alcotest.failf "expected Empty_text, got %s" (Note.write_error_to_string error));
    match Note.write ~config ~keeper:"../escape" ~text:"x" ~created_by:"operator" with
    | Error (Note.Unknown_keeper _) -> ()
    | Ok _ -> Alcotest.fail "an invalid keeper name must not resolve"
    | Error error ->
      Alcotest.failf "expected Unknown_keeper, got %s" (Note.write_error_to_string error))
;;

(* The rendered block says what it is. A keeper that cannot tell an operator
   note from persisted memory would treat a one-turn instruction as standing
   context, which is the confusion this whole path exists to remove. *)
let test_rendered_block_states_its_lifetime () =
  with_workspace (fun config ->
    let note = put config "resume task-195" in
    match Note.render note with
    | None -> Alcotest.fail "a non-empty note must render"
    | Some block ->
      Alcotest.(check bool)
        "names the author"
        true
        (Astring.String.is_infix ~affix:"operator" block);
      Alcotest.(check bool)
        "says it is not memory"
        true
        (Astring.String.is_infix ~affix:"not stored as memory" block);
      Alcotest.(check bool)
        "says it will not repeat"
        true
        (Astring.String.is_infix ~affix:"will not appear again" block))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "keeper operator note"
    [ ( "lifetime"
      , [ Alcotest.test_case "consumption is quiet only when there is no note" `Quick
            test_consumption_is_quiet_only_when_there_is_no_note
        ; Alcotest.test_case "renders once then never again" `Quick
            test_renders_once_then_never_again
        ; Alcotest.test_case "consumption leaves a delivery record" `Quick
            test_consumption_leaves_a_delivery_record
        ; Alcotest.test_case "no note and consumed note are different answers" `Quick
            test_no_note_and_consumed_note_are_different_answers
        ] )
    ; ( "replacement"
      , [ Alcotest.test_case "writing replaces rather than queues" `Quick
            test_writing_replaces_rather_than_queues
        ; Alcotest.test_case "new note after consumption is deliverable" `Quick
            test_new_note_after_consumption_is_deliverable
        ] )
    ; ( "input"
      , [ Alcotest.test_case "oversized note is rejected, not truncated" `Quick
            test_oversized_note_is_rejected_not_truncated
        ; Alcotest.test_case "empty and invalid inputs are refused" `Quick
            test_empty_and_invalid_inputs_are_refused
        ] )
    ; ( "rendering"
      , [ Alcotest.test_case "rendered block states its lifetime" `Quick
            test_rendered_block_states_its_lifetime
        ] )
    ]
;;
