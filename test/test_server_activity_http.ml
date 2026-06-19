(** Unit tests for [Server_activity_http.slice_default_events_to_limit].

    RFC-0201 Step 1 follow-up (issue #19313).  Guards the default-query
    path that serves [Dashboard_snapshot.current ()].activity_events_default. *)

open Alcotest

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let mk_event ~seq kind =
  `Assoc [ ("seq", `Int seq); ("kind", `String kind) ]

let mk_input ?(after_seq = 0) ?next_after_seq ?(limit = 200) events =
  let base =
    [ ("events", `List events)
    ; ("count", `Int (List.length events))
    ; ("limit", `Int limit)
    ; ("after_seq", `Int after_seq)
    ]
  in
  match next_after_seq with
  | Some n -> `Assoc (("next_after_seq", `Int n) :: base)
  | None -> `Assoc base

let get_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let get_int_field key json =
  match get_field key json with
  | Some (`Int n) -> Some n
  | _ -> None

let get_list_field key json =
  match get_field key json with
  | Some (`List xs) -> Some xs
  | _ -> None

let test_len_lt_limit () =
  (* Case 1: fewer events than limit — events preserved, limit refreshed. *)
  let events = [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b" ] in
  let input = mk_input events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check (option int) "limit updated" (Some 10) (get_int_field "limit" got);
  check (option int) "count preserved" (Some 2) (get_int_field "count" got);
  check (option int) "after_seq preserved" (Some 0)
    (get_int_field "after_seq" got);
  check (list yojson) "events preserved" events
    (Option.value (get_list_field "events" got) ~default:[])

let test_len_eq_limit () =
  (* Case 2: exactly at limit — events preserved, limit refreshed. *)
  let events = [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b" ] in
  let input = mk_input events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:2 in
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got);
  check (list yojson) "events preserved" events
    (Option.value (get_list_field "events" got) ~default:[])

let test_len_gt_limit () =
  (* Case 3: more events than limit — drop oldest, keep tail. *)
  let events =
    [ mk_event ~seq:1 "a"
    ; mk_event ~seq:2 "b"
    ; mk_event ~seq:3 "c"
    ; mk_event ~seq:4 "d"
    ]
  in
  let input = mk_input ~next_after_seq:0 events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:2 in
  let expected_events = [ mk_event ~seq:3 "c"; mk_event ~seq:4 "d" ] in
  check (list yojson) "tail 2 kept" expected_events
    (Option.value (get_list_field "events" got) ~default:[]);
  check (option int) "count updated" (Some 2) (get_int_field "count" got);
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got);
  (* next_after_seq comes from the last kept event's seq *)
  check (option int) "next_after_seq from last seq" (Some 4)
    (get_int_field "next_after_seq" got)

let test_empty_events () =
  (* Case 4: empty list — next_after_seq falls back to after_seq. *)
  let input = mk_input ~after_seq:42 ~next_after_seq:0 [] in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check (list yojson) "events empty" []
    (Option.value (get_list_field "events" got) ~default:[]);
  check (option int) "next_after_seq falls back to after_seq" (Some 42)
    (get_int_field "next_after_seq" got)

let test_missing_seq () =
  (* Case 5: last event lacks seq — next_after_seq falls back to
     input's next_after_seq field. *)
  let event_no_seq = `Assoc [ ("kind", `String "x") ] in
  let input = mk_input ~next_after_seq:99 [ event_no_seq ] in
  let got =
    Server_activity_http.slice_default_events_to_limit input ~limit:10
  in
  check (option int) "next_after_seq falls back to field" (Some 99)
    (get_int_field "next_after_seq" got)

let test_non_assoc_passthrough () =
  (* Case 6: non-Assoc input — passthrough unchanged. *)
  let input = `String "not an object" in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check yojson "passthrough" input got

let test_count_and_limit_updated () =
  (* When slicing occurs, count and limit fields are refreshed. *)
  let events =
    [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b"; mk_event ~seq:3 "c" ]
  in
  let input = mk_input events in
  let got =
    Server_activity_http.slice_default_events_to_limit input ~limit:2
  in
  check (option int) "count updated" (Some 2) (get_int_field "count" got);
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got)

(* #21562 regression: the keepalive loop must terminate when the client is
   gone ([send] returns [false]) instead of spinning on the server-lifetime
   switch until shutdown.  [sleep] is injected as a no-op so the control flow
   is exercised deterministically without a clock. *)
let test_keepalive_loop_terminates_on_client_gone () =
  let stop = ref false in
  let sends = ref 0 in
  let send () =
    incr sends;
    (* client alive for two keepalives, disconnected on the third *)
    !sends < 3
  in
  Server_activity_http.run_keepalive_loop ~sleep:(fun () -> ()) ~stop ~send;
  check bool "stop is set once the client is gone" true !stop;
  check int "loop halts on the failing send (no further iterations)" 3 !sends

(* The loop must also honour an externally-set [stop] (e.g. [close_stream]
   from the disconnect path) at the top guard. *)
let test_keepalive_loop_honours_external_stop () =
  let stop = ref false in
  let sends = ref 0 in
  let send () =
    incr sends;
    stop := true;
    true
  in
  Server_activity_http.run_keepalive_loop ~sleep:(fun () -> ()) ~stop ~send;
  check int "loop halts at the top guard after external stop" 1 !sends

let () =
  run "Server_activity_http"
    [ ( "keepalive_loop"
      , [ test_case "terminates when client is gone" `Quick
            test_keepalive_loop_terminates_on_client_gone
        ; test_case "honours external stop" `Quick
            test_keepalive_loop_honours_external_stop
        ] )
    ; ( "slice_default_events_to_limit"
      , [ test_case "len < limit" `Quick test_len_lt_limit
        ; test_case "len == limit" `Quick test_len_eq_limit
        ; test_case "len > limit" `Quick test_len_gt_limit
        ; test_case "empty events" `Quick test_empty_events
        ; test_case "missing seq fallback" `Quick test_missing_seq
        ; test_case "non-Assoc passthrough" `Quick test_non_assoc_passthrough
        ; test_case "count and limit updated" `Quick test_count_and_limit_updated
        ] )
    ]
