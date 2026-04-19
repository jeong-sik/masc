(** Test Event_kind: roundtrip + coverage invariants.

    The point of the variant SSOT (#8455) is that every name defined on
    the emit side has a reverse route on the parse boundary, and that
    [all] enumerates every variant. These tests catch drift — e.g. a
    new variant added to [t] without extending [to_string]/[of_string]. *)

(* Issue #8645 drive-by: Event_kind moved to Masc_coord library
   (cross-library reference fix). Test uses Event_kind directly via
   masc_test_deps re-export. *)

let () =
  (* Round-trip: to_string → of_string = Some original *)
  List.iter
    (fun v ->
      let s = Event_kind.Task.to_string v in
      match Event_kind.Task.of_string s with
      | Some v' when v' = v -> ()
      | Some _ ->
          Printf.eprintf
            "event_kind Task roundtrip mismatch for %s\n%!" s;
          exit 1
      | None ->
          Printf.eprintf
            "event_kind Task of_string returned None for %s\n%!" s;
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
      if not (String.length s > 5 && String.sub s 0 5 = "task.") then begin
        Printf.eprintf
          "event_kind Task name does not start with \"task.\": %s\n%!" s;
        exit 1
      end)
    Event_kind.Task.all;
  print_endline "test_event_kind: OK"
