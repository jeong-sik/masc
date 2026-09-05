(* Memory use events (RFC-0418): the sidecar codec, append and read, and the
   projection a consumer builds from them. No strength or score is stored, so
   every number here is recomputed from the events the test wrote. *)

open Alcotest
module Events = Masc.Keeper_memory_os_events
module Types = Masc.Keeper_memory_os_types

let with_temp_keepers f =
  let path = Filename.temp_file "memory-os-events-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

(* The shape [Types.is_memory_id] accepts; pinned below so a change to the id
   format fails here first. *)
let memory_id c = "sha256:" ^ String.make 64 c
let id_a = memory_id 'a'
let id_b = memory_id 'b'
let id_c = memory_id 'c'
let day = 86_400.

let event ?(trace_id = "trace-1") ?(memory_id = id_a) ~at kind : Events.event =
  { recorded_at = at; memory_id; trace_id; kind }
;;

let retrieved ?trace_id ?memory_id ~at query =
  event ?trace_id ?memory_id ~at (Events.Retrieved { query })
;;

let cited ?memory_id ~at tool = event ?memory_id ~at (Events.Cited { tool })

let revised ~memory_id ~at superseded_by =
  event ~memory_id ~at (Events.Revised { superseded_by })
;;

let require_ok what = function
  | Ok v -> v
  | Error error -> failf "%s: %s" what (Types.wire_error_to_string error)
;;

let require_error what = function
  | Ok _ -> failf "%s: expected a rejection" what
  | Error error -> Types.wire_error_to_string error
;;

let contains needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  go 0
;;

let check_names what needle text =
  check bool (what ^ " names " ^ needle) true (contains needle text)
;;

let event_testable =
  let pp fmt (e : Events.event) = Yojson.Safe.pretty_print fmt (Events.event_to_json e) in
  testable pp (fun (a : Events.event) b -> a = b)
;;

(* ---------- codec ---------- *)

let test_ids_are_memory_ids () =
  check bool "fixture ids pass the store's own predicate" true
    (List.for_all Types.is_memory_id [ id_a; id_b; id_c ])
;;

let test_round_trip_each_kind () =
  List.iter
    (fun e ->
       let back = Events.event_of_json (Events.event_to_json e) |> require_ok "decode" in
       check event_testable "round trip" e back)
    [ retrieved ~at:1000. "deploy needs assets"
    ; cited ~at:1001. "keeper_memory_retract"
    ; revised ~memory_id:id_b ~at:1002. id_a
    ; retrieved ~trace_id:"" ~at:1003. "no turn"
    ]
;;

let test_wire_carries_one_payload_field () =
  let fields = function
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> fail "event json is not an object"
  in
  check (list string) "retrieved fields"
    [ "kind"; "memory_id"; "query"; "recorded_at"; "trace_id" ]
    (fields (Events.event_to_json (retrieved ~at:1. "q")));
  check (list string) "cited fields"
    [ "kind"; "memory_id"; "recorded_at"; "tool"; "trace_id" ]
    (fields (Events.event_to_json (cited ~at:1. "t")));
  check (list string) "revised fields"
    [ "kind"; "memory_id"; "recorded_at"; "superseded_by"; "trace_id" ]
    (fields (Events.event_to_json (revised ~memory_id:id_b ~at:1. id_a)))
;;

let with_field json key value =
  match json with
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | other -> other
;;

let without_field json key =
  match json with
  | `Assoc fields -> `Assoc (List.remove_assoc key fields)
  | other -> other
;;

let test_decoder_rejects_and_names () =
  let base = Events.event_to_json (retrieved ~at:1000. "q") in
  check_names "unknown kind" "kind"
    (require_error "kind" (Events.event_of_json (with_field base "kind" (`String "seen"))));
  check_names "extra field" "reinforcement"
    (require_error "extra"
       (Events.event_of_json (with_field base "reinforcement" (`Int 3))));
  check_names "payload of another kind" "tool"
    (require_error "wrong payload"
       (Events.event_of_json (with_field base "tool" (`String "x"))));
  check_names "missing payload" "query"
    (require_error "missing" (Events.event_of_json (without_field base "query")));
  check_names "bad memory id" "memory_id"
    (require_error "id"
       (Events.event_of_json (with_field base "memory_id" (`String "m1"))));
  check_names "blank query" "query"
    (require_error "blank" (Events.event_of_json (with_field base "query" (`String "  "))));
  check_names "non-object" "expected"
    (require_error "list" (Events.event_of_json (`List [])));
  let revised_json = Events.event_to_json (revised ~memory_id:id_b ~at:1. id_a) in
  check_names "successor must be a memory id" "superseded_by"
    (require_error "successor"
       (Events.event_of_json (with_field revised_json "superseded_by" (`String "new"))))
;;

(* ---------- sidecar ---------- *)

let events_only rows =
  List.filter_map
    (fun (_, row) ->
       match row with
       | Ok e -> Some e
       | Error _ -> None)
    rows
;;

let test_append_then_read_in_order () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let written =
    [ retrieved ~at:1000. "first"
    ; cited ~at:1001. "keeper_memory_retract"
    ; revised ~memory_id:id_b ~at:1002. id_a
    ]
  in
  List.iter
    (fun e ->
       match Events.append ~keepers_dir ~keeper_id e with
       | Ok () -> ()
       | Error error -> fail (Events.append_error_to_string error))
    written;
  let rows = Events.read ~keepers_dir ~keeper_id in
  check (list int) "indices follow file order" [ 0; 1; 2 ] (List.map fst rows);
  check (list event_testable) "every row reads back" written (events_only rows)
;;

let test_missing_sidecar_reads_as_no_events () =
  with_temp_keepers @@ fun keepers_dir ->
  check int "no file, no rows" 0 (List.length (Events.read ~keepers_dir ~keeper_id:"nobody"))
;;

let test_unreadable_line_stays_in_the_list () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let path = Events.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let good = Yojson.Safe.to_string (Events.event_to_json (retrieved ~at:1. "kept")) in
  let stale =
    Yojson.Safe.to_string
      (with_field (Events.event_to_json (retrieved ~at:2. "old")) "score" (`Int 1))
  in
  let oc = open_out path in
  output_string oc (good ^ "\n" ^ "not json\n" ^ "\n" ^ stale ^ "\n" ^ good ^ "\n");
  close_out oc;
  let rows = Events.read ~keepers_dir ~keeper_id in
  check int "blank line does not count" 4 (List.length rows);
  let tag (index, row) =
    match row with
    | Ok _ -> Printf.sprintf "%d ok" index
    | Error (Events.Not_json _) -> Printf.sprintf "%d not-json" index
    | Error (Events.Malformed _) -> Printf.sprintf "%d malformed" index
  in
  check (list string) "each bad line is named at its index"
    [ "0 ok"; "1 not-json"; "2 malformed"; "3 ok" ]
    (List.map tag rows);
  (match List.nth rows 2 with
   | _, Error (Events.Malformed error) ->
     check_names "the stale field is named" "score" (Types.wire_error_to_string error)
   | _, Ok _ | _, Error (Events.Not_json _) -> fail "line 2 should be the malformed one");
  check int "good rows still read" 2 (List.length (events_only rows))
;;

let test_append_refuses_what_read_would_refuse () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let bad = retrieved ~memory_id:"m1" ~at:1. "q" in
  (match Events.append ~keepers_dir ~keeper_id bad with
   | Ok () -> fail "an event with a non-memory id was written"
   | Error (Events.Invalid_event error) ->
     check_names "refusal" "memory_id" (Types.wire_error_to_string error)
   | Error (Events.Write_failed _) -> fail "refused for the wrong reason");
  check bool "nothing was written" false
    (Sys.file_exists (Events.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

(* ---------- projection ---------- *)

let test_summary_counts_only_this_fact () =
  let events =
    [ retrieved ~at:(10. *. day +. 100.) "one"
    ; retrieved ~at:(10. *. day +. 500.) "one again"
    ; retrieved ~at:(12. *. day +. 1.) "later day"
    ; retrieved ~memory_id:id_b ~at:(13. *. day) "another fact"
    ; cited ~at:(11. *. day) "keeper_memory_retract"
    ; cited ~memory_id:id_c ~at:(11. *. day) "keeper_memory_retract"
    ; revised ~memory_id:id_b ~at:(14. *. day) id_a
    ; revised ~memory_id:id_c ~at:(14. *. day) id_a
    ; revised ~memory_id:id_c ~at:(15. *. day) id_a
    ; revised ~memory_id:id_a ~at:(16. *. day) id_b
    ]
  in
  let s = Events.summary_for ~memory_id:id_a events in
  check int "retrieved count" 3 s.retrieved_count;
  check int "two UTC days, not three retrievals" 2 s.retrieved_distinct_days;
  check (option (float 0.0)) "last retrieval is the latest" (Some (12. *. day +. 1.))
    s.last_retrieved_at;
  check int "cited once" 1 s.cited_count;
  check (list string) "revised from both predecessors, once each" [ id_b; id_c ] s.revised_from
;;

let test_summary_of_an_unused_fact_is_empty () =
  let s = Events.summary_for ~memory_id:id_c [ retrieved ~at:1. "q"; cited ~at:2. "t" ] in
  check int "no retrievals" 0 s.retrieved_count;
  check int "no days" 0 s.retrieved_distinct_days;
  check (option (float 0.0)) "never retrieved" None s.last_retrieved_at;
  check int "no citations" 0 s.cited_count;
  check (list string) "no predecessors" [] s.revised_from
;;

let () =
  run
    "keeper_memory_os_events"
    [ ( "codec"
      , [ test_case "fixture ids are memory ids" `Quick test_ids_are_memory_ids
        ; test_case "each kind round-trips" `Quick test_round_trip_each_kind
        ; test_case "a line carries one payload field" `Quick test_wire_carries_one_payload_field
        ; test_case "the decoder rejects and names the field" `Quick test_decoder_rejects_and_names
        ] )
    ; ( "sidecar"
      , [ test_case "append then read in order" `Quick test_append_then_read_in_order
        ; test_case "a missing file is no events" `Quick test_missing_sidecar_reads_as_no_events
        ; test_case "an unreadable line stays in the list" `Quick test_unreadable_line_stays_in_the_list
        ; test_case "append refuses what read would refuse" `Quick
            test_append_refuses_what_read_would_refuse
        ] )
    ; ( "projection"
      , [ test_case "the summary counts only this fact" `Quick test_summary_counts_only_this_fact
        ; test_case "an unused fact has an empty summary" `Quick
            test_summary_of_an_unused_fact_is_empty
        ] )
    ]
;;
