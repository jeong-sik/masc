open Keeper_event_queue

let fail fmt =
  Printf.ksprintf (fun message -> print_endline ("FAIL: " ^ message); exit 1) fmt

let test_event_queue_state_rejects_foreign_schema () =
  (* Round-trip a minimal state, then re-label it with a foreign schema.
     The loader must refuse it — this is exactly what saved the WAL from
     #29601, and what the snapshot row comparison must keep doing. *)
  let state_json =
    `Assoc
      [ ("schema", `String Keeper_event_queue_state.schema)
      ; ("revision", `Int 0)
      ; ("pending", `List [])
      ; ("last_transition", `Null)
      ; ("projected_dispositions", `List [])
      ; ("transition_outbox", `List [])
      ; ("accepted_transfer_projections", `List [])
      ]
  in
  let same_marker = Keeper_event_queue_state.of_yojson state_json in
  (match same_marker with Ok _ -> () | Error e -> fail "baseline decode failed: %s" e);
  let relabeled =
    match state_json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "schema", `String _ -> ("schema", `String (Keeper_event_queue_state.schema ^ ".foreign"))
             | kv -> kv)
           fields)
    | _ -> assert false
  in
  (match Keeper_event_queue_state.of_yojson relabeled with
   | Ok _ -> fail "a foreign-generation snapshot decoded as current"
   | Error message ->
     if not (String.length message > 0) then fail "rejection message must not be empty")

let () =
  test_event_queue_state_rejects_foreign_schema ();
  print_endline "test_schema_boundary: pass"
