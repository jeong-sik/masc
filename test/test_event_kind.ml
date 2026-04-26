(** Test Event_kind: roundtrip + coverage invariants.

    The point of the variant SSOT (#8455) is that every name defined on
    the emit side has a reverse route on the parse boundary, and that
    [all] enumerates every variant. These tests catch drift — e.g. a
    new variant added to [t] without extending [to_string]/[of_string]. *)

(* Issue #8394 drive-by: Event_kind moved to Masc_coord library
   (cross-library reference fix from #8635). Test reaches Event_kind
   via masc_test_deps re-export of masc_mcp.masc_coord. *)

let () =
  (* Round-trip: to_string → of_string = Some original *)
  List.iter
    (fun v ->
       let s = Event_kind.Task.to_string v in
       match Event_kind.Task.of_string s with
       | Some v' when v' = v -> ()
       | Some _ ->
         Printf.eprintf "event_kind Task roundtrip mismatch for %s\n%!" s;
         exit 1
       | None ->
         Printf.eprintf "event_kind Task of_string returned None for %s\n%!" s;
         exit 1)
    Event_kind.Task.all;
  (* Unknown input must not accidentally resolve *)
  (match Event_kind.Task.of_string "task.clamied" with
   | Some _ ->
     prerr_endline "event_kind Task.of_string accepted a typo";
     exit 1
   | None -> ());
  (* All names are dotted-form under [task.] *)
  List.iter
    (fun v ->
       let s = Event_kind.Task.to_string v in
       if not (String.length s > 5 && String.sub s 0 5 = "task.")
       then (
         Printf.eprintf "event_kind Task name does not start with \"task.\": %s\n%!" s;
         exit 1))
    Event_kind.Task.all;
  (* Message family *)
  List.iter
    (fun v ->
       let s = Event_kind.Message.to_string v in
       match Event_kind.Message.of_string s with
       | Some v' when v' = v -> ()
       | Some _ ->
         Printf.eprintf "event_kind Message roundtrip mismatch for %s\n%!" s;
         exit 1
       | None ->
         Printf.eprintf "event_kind Message of_string returned None for %s\n%!" s;
         exit 1)
    Event_kind.Message.all;
  (match Event_kind.Message.of_string "message.brodacast" with
   | Some _ ->
     prerr_endline "event_kind Message.of_string accepted a typo";
     exit 1
   | None -> ());
  List.iter
    (fun v ->
       let s = Event_kind.Message.to_string v in
       if not (String.length s > 8 && String.sub s 0 8 = "message.")
       then (
         Printf.eprintf
           "event_kind Message name does not start with \"message.\": %s\n%!"
           s;
         exit 1))
    Event_kind.Message.all;
  (* Board family: same three invariants *)
  List.iter
    (fun v ->
       let s = Event_kind.Board.to_string v in
       match Event_kind.Board.of_string s with
       | Some v' when v' = v -> ()
       | Some _ ->
         Printf.eprintf "event_kind Board roundtrip mismatch for %s\n%!" s;
         exit 1
       | None ->
         Printf.eprintf "event_kind Board of_string returned None for %s\n%!" s;
         exit 1)
    Event_kind.Board.all;
  (match Event_kind.Board.of_string "board.potsed" with
   | Some _ ->
     prerr_endline "event_kind Board.of_string accepted a typo";
     exit 1
   | None -> ());
  List.iter
    (fun v ->
       let s = Event_kind.Board.to_string v in
       if not (String.length s > 6 && String.sub s 0 6 = "board.")
       then (
         Printf.eprintf "event_kind Board name does not start with \"board.\": %s\n%!" s;
         exit 1))
    Event_kind.Board.all;
  print_endline "test_event_kind: OK"
;;
