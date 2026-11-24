(* Memory use events: the retrieval sidecar codec, append and read,
   and the projection a consumer builds from it and the journal lineage. No
   strength or score is stored, so every number here is recomputed from the
   events and lineage the test supplies. *)

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

let link superseded superseded_by : Types.revision = { superseded; superseded_by }

let summaries ?(revisions = []) ?(retractions = []) ~memory_ids events =
  Events.summaries_for ~memory_ids ~revisions ~retractions events
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
    ; retrieved ~memory_id:id_b ~at:1002. "another fact"
    ; retrieved ~trace_id:"" ~at:1003. "no turn"
    ]
;;

let test_wire_carries_the_kind_payload () =
  let fields = function
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> fail "event json is not an object"
  in
  check (list string) "retrieved fields"
    [ "kind"; "memory_id"; "query"; "recorded_at"; "trace_id" ]
    (fields (Events.event_to_json (retrieved ~at:1. "q")))
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
  check_names "undeclared payload" "tool"
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
    (require_error "list" (Events.event_of_json (`List [])))
;;

(* Revisions and retractions are journal lineage now (#37433). The rows
   earlier builds appended after a commit are not read as events. *)
let test_commit_rows_of_earlier_builds_are_rejected () =
  let common =
    [ "recorded_at", `Float 1.; "memory_id", `String id_b; "trace_id", `String "t" ]
  in
  check_names "revised row" "kind"
    (require_error "revised"
       (Events.event_of_json
          (`Assoc
             (("kind", `String "revised")
              :: ("superseded_by", `String id_a)
              :: common))));
  check_names "retracted row" "kind"
    (require_error "retracted"
       (Events.event_of_json (`Assoc (("kind", `String "retracted") :: common))))
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

let read_ok ~keepers_dir ~keeper_id =
  match Events.read ~keepers_dir ~keeper_id with
  | Ok rows -> rows
  | Error error -> fail (Events.file_read_error_to_string error)
;;

let test_append_then_read_in_order () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let written =
    [ retrieved ~at:1000. "first"
    ; retrieved ~memory_id:id_b ~at:1001. "second"
    ; retrieved ~memory_id:id_c ~at:1002. "third"
    ]
  in
  List.iter
    (fun e ->
       match Events.append ~keepers_dir ~keeper_id e with
       | Ok () -> ()
       | Error error -> fail (Events.append_error_to_string error))
    written;
  let rows = read_ok ~keepers_dir ~keeper_id in
  check (list int) "indices follow file order" [ 0; 1; 2 ] (List.map fst rows);
  check (list event_testable) "every row reads back" written (events_only rows)
;;

let test_append_all_writes_every_valid_event_in_order () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let written =
    [ retrieved ~at:1000. "first"
    ; retrieved ~memory_id:id_b ~at:1001. "second"
    ; retrieved ~memory_id:id_c ~at:1002. "third"
    ]
  in
  check int "nothing comes back" 0
    (List.length (Events.append_all ~keepers_dir ~keeper_id written));
  check (list event_testable) "the events read back in the order given" written
    (events_only (read_ok ~keepers_dir ~keeper_id))
;;

let test_append_cuts_a_torn_tail_first () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let path = Events.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let kept = retrieved ~at:1. "kept" in
  let kept_line = Yojson.Safe.to_string (Events.event_to_json kept) in
  let oc = open_out_bin path in
  output_string oc
    (kept_line ^ "\n" ^ String.sub kept_line 0 (String.length kept_line / 2));
  close_out oc;
  let next = retrieved ~at:2. "next" in
  (match Events.append ~keepers_dir ~keeper_id next with
   | Ok () -> ()
   | Error error -> fail (Events.append_error_to_string error));
  let rows = read_ok ~keepers_dir ~keeper_id in
  check (list event_testable) "both whole rows read, the cut row is gone"
    [ kept; next ] (events_only rows);
  check int "no unreadable line is left behind" 2 (List.length rows)
;;

let test_missing_sidecar_reads_as_no_events () =
  with_temp_keepers @@ fun keepers_dir ->
  check int "no file, no rows" 0
    (List.length (read_ok ~keepers_dir ~keeper_id:"nobody"))
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
  let rows = read_ok ~keepers_dir ~keeper_id in
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

let test_streaming_fold_matches_read () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "heat" in
  let path = Events.path_for_keepers_dir ~keepers_dir ~keeper_id in
  let good = Yojson.Safe.to_string (Events.event_to_json (retrieved ~at:1. "scope")) in
  List.iter (fun suffix ->
    Out_channel.with_open_bin path (fun oc -> output_string oc (good ^ "\n\nnot json\n{}\n" ^ suffix));
    let listed = read_ok ~keepers_dir ~keeper_id |> List.map snd in
    let folded = match Events.fold ~keepers_dir ~keeper_id ~init:[] ~f:(fun acc row -> row :: acc) with
      | Error err -> fail (Events.file_read_error_to_string err) | Ok rev -> List.rev rev in
    check bool "streaming heat has the same valid, malformed, blank, and final rows" true (listed = folded))
    [good ^ "\n"; good; "broken"; "   "; ""]
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

let test_retraction_and_following_retrieval_are_counted () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  (match Events.append ~keepers_dir ~keeper_id (retrieved ~at:3. "kept") with
   | Ok () -> ()
   | Error error -> fail (Events.append_error_to_string error));
  let read = read_ok ~keepers_dir ~keeper_id in
  check int "all rows are accounted for" 1 (List.length read);
  let summary =
    summaries ~retractions:[ id_a ] ~memory_ids:[id_a] (events_only read) |> List.hd
  in
  check int "the journal retraction is counted" 1 summary.retracted_count;
  check int "the following retrieval is counted" 1 summary.retrieved_count
;;

let test_append_all_returns_only_the_failures () =
  with_temp_keepers @@ fun keepers_dir ->
  let keeper_id = "keeper" in
  let failures =
    Events.append_all ~keepers_dir ~keeper_id
      [ retrieved ~at:1. "first"
      ; retrieved ~memory_id:"not-an-id" ~at:2. "bad"
      ; retrieved ~at:3. "third"
      ]
  in
  check int "one failure back" 1 (List.length failures);
  (match failures with
   | [ Events.Invalid_event error ] ->
     check_names "the failure names the field" "memory_id" (Types.wire_error_to_string error)
   | _ -> fail "expected the invalid event's own rejection");
  check int "the valid ones were written" 2
    (List.length (events_only (read_ok ~keepers_dir ~keeper_id)))
;;

let test_sidecar_read_failure_is_not_empty_history () =
  with_temp_keepers @@ fun keepers_dir ->
  let parent = Filename.concat keepers_dir "not-a-directory" in
  Fs_compat.save_file parent "occupied";
  match Events.read ~keepers_dir:parent ~keeper_id:"keeper" with
  | Error { path; message = _ } ->
    check string "failed sidecar path is retained"
      (Events.path_for_keepers_dir ~keepers_dir:parent ~keeper_id:"keeper") path
  | Ok _ -> fail "a non-directory sidecar parent must not become empty history"
;;

(* ---------- projection ---------- *)

let test_summary_counts_only_this_fact () =
  let events =
    [ retrieved ~at:(10. *. day +. 100.) "one"
    ; retrieved ~at:(10. *. day +. 500.) "one again"
    ; retrieved ~at:(12. *. day +. 1.) "later day"
    ; retrieved ~memory_id:id_b ~at:(13. *. day) "another fact"
    ]
  in
  let revisions = [ link id_b id_a; link id_c id_a; link id_c id_a; link id_a id_b ] in
  let retractions = [ id_a; id_c ] in
  let s = summaries ~revisions ~retractions ~memory_ids:[id_a] events |> List.hd in
  check int "retrieved count" 3 s.retrieved_count;
  check int "two UTC days, not three retrievals" 2 s.retrieved_distinct_days;
  check (option (float 0.0)) "last retrieval is the latest" (Some (12. *. day +. 1.))
    s.last_retrieved_at;
  check int "retracted once" 1 s.retracted_count;
  check (list string) "revised from both predecessors, once each" [ id_b; id_c ] s.revised_from
;;

let test_summary_json_names_every_field () =
  let s =
    summaries ~revisions:[ link id_b id_a ] ~memory_ids:[id_a]
      [ retrieved ~at:(10. *. day) "q" ]
    |> List.hd
  in
  let json = Events.summary_to_json s in
  let field k =
    match json with
    | `Assoc fields -> List.assoc k fields
    | _ -> fail "summary json is not an object"
  in
  check bool "retrieved_count" true (field "retrieved_count" = `Int 1);
  check bool "retrieved_distinct_days" true (field "retrieved_distinct_days" = `Int 1);
  check bool "last_retrieved_at is the time" true (field "last_retrieved_at" = `Float (10. *. day));
  check bool "retracted_count" true (field "retracted_count" = `Int 0);
  check bool "revised_from lists the predecessor" true (field "revised_from" = `List [ `String id_b ]);
  match Events.summary_to_json (List.hd (summaries ~memory_ids:[id_c] [])) with
  | `Assoc fields -> check bool "never retrieved is null, not zero" true (List.assoc "last_retrieved_at" fields = `Null)
  | _ -> fail "summary json is not an object"
;;

let test_summary_of_an_unused_fact_is_empty () =
  let s =
    summaries ~revisions:[ link id_a id_b ] ~retractions:[ id_a ] ~memory_ids:[id_c]
      [ retrieved ~at:1. "q" ]
    |> List.hd
  in
  check int "no retrievals" 0 s.retrieved_count;
  check int "no days" 0 s.retrieved_distinct_days;
  check (option (float 0.0)) "never retrieved" None s.last_retrieved_at;
  check int "no retractions" 0 s.retracted_count;
  check (list string) "no predecessors" [] s.revised_from
;;

(* A per-fact scan is the oracle for the shared index. Keep it independent of
   the index's map and sets, including the self-revision rule. *)
let reference_summary ~memory_id ~revisions ~retractions events : Events.summary =
  let open Events in
  let times = List.filter_map (fun (event : event) ->
    match event.kind with
    | Retrieved _ when String.equal event.memory_id memory_id -> Some event.recorded_at
    | Retrieved _ -> None) events in
  { retrieved_count = List.length times
  ; retrieved_distinct_days = List.map (fun at -> int_of_float (Float.floor (at /. day))) times
      |> List.sort_uniq Int.compare |> List.length
  ; last_retrieved_at = List.fold_left (fun latest at ->
      Some (match latest with None -> at | Some seen -> Float.max seen at)) None times
  ; retracted_count = List.filter (String.equal memory_id) retractions |> List.length
  ; revised_from = List.filter_map (fun (link : Types.revision) ->
      if String.equal link.superseded_by memory_id
         && not (String.equal link.superseded memory_id)
      then Some link.superseded else None) revisions |> List.sort_uniq String.compare
  }
;;

let summary_testable =
  testable (fun fmt summary -> Yojson.Safe.pretty_print fmt (Events.summary_to_json summary))
    (fun left right -> left = right)
;;

let test_summary_index_matches_per_fact_scan () =
  let id_d = memory_id 'd' in
  let absent = memory_id 'e' in
  let events =
    [ retrieved ~at:(3. *. day +. 1.) "latest first"
    ; retrieved ~memory_id:id_b ~at:day "another fact"
    ; retrieved ~at:(-1.) "before UTC epoch"
    ; retrieved ~at:0. "next UTC day"
    ; retrieved ~at:(day -. 1.) "same UTC day"
    ; retrieved ~at:(3. *. day +. 1.) "duplicate retrieval still counts"
    ; retrieved ~memory_id:id_b ~at:(day +. 1.) "same day, another fact"
    ]
  in
  let revisions =
    [ link id_c id_a; link id_b id_a; link id_c id_a; link id_a id_a; link id_a id_b
    ; link id_c id_d ]
  in
  let retractions = [ id_a; id_a; id_c ] in
  List.iter (fun (rows, revisions, retractions) ->
    List.iter (fun memory_ids ->
      check (list summary_testable) "selected summaries preserve requested order and duplicates"
        (List.map (fun memory_id -> reference_summary ~memory_id ~revisions ~retractions rows)
           memory_ids)
        (summaries ~revisions ~retractions ~memory_ids rows))
      [[]; [id_a]; [id_b]; [id_a; id_b; id_c; id_d; absent];
       [absent; id_d; id_a; id_a]];
    let current = summaries ~revisions ~retractions ~memory_ids:[id_a] rows |> List.hd in
    check int "duplicates still count as retrievals" 5 current.retrieved_count;
    check int "UTC days include the negative timestamp day" 3 current.retrieved_distinct_days;
    check int "each journal retraction counts" 2 current.retracted_count;
    check (list string) "self revisions are excluded, predecessors sorted and deduplicated"
      [id_b; id_c] current.revised_from;
    check (list string) "a successor need not own any event"
      [id_c]
      (List.hd (summaries ~revisions ~retractions ~memory_ids:[id_d] rows)).revised_from;
    let next = summaries ~memory_ids:[id_a] [retrieved ~at:0. "new capture"] in
    check summary_testable "new captures do not keep previous history"
      (reference_summary ~memory_id:id_a ~revisions:[] ~retractions:[]
         [retrieved ~at:0. "new capture"])
      (List.hd next);
    check summary_testable "a later capture does not replace earlier results"
      (reference_summary ~memory_id:id_a ~revisions ~retractions rows) current)
    [ events, revisions, retractions
    ; List.rev events, List.rev revisions, List.rev retractions ]
;;

let () =
  run
    "keeper_memory_os_events"
    [ ( "codec"
      , [ test_case "fixture ids are memory ids" `Quick test_ids_are_memory_ids
        ; test_case "each kind round-trips" `Quick test_round_trip_each_kind
        ; test_case "a line carries only its kind payload" `Quick test_wire_carries_the_kind_payload
        ; test_case "the decoder rejects and names the field" `Quick test_decoder_rejects_and_names
        ; test_case "commit rows of earlier builds are rejected" `Quick
            test_commit_rows_of_earlier_builds_are_rejected
        ] )
    ; ( "sidecar"
      , [ test_case "append then read in order" `Quick test_append_then_read_in_order
        ; test_case "streaming fold preserves the complete lifetime observation" `Quick test_streaming_fold_matches_read
        ; test_case "append_all writes every valid event in order" `Quick
            test_append_all_writes_every_valid_event_in_order
        ; test_case "an append cuts a torn tail first" `Quick test_append_cuts_a_torn_tail_first
        ; test_case "a missing file is no events" `Quick test_missing_sidecar_reads_as_no_events
        ; test_case "an unreadable line stays in the list" `Quick test_unreadable_line_stays_in_the_list
        ; test_case "a journal retraction and a sidecar retrieval are both counted" `Quick
            test_retraction_and_following_retrieval_are_counted
        ; test_case "append refuses what read would refuse" `Quick
            test_append_refuses_what_read_would_refuse
        ; test_case "append_all returns only the failures" `Quick
            test_append_all_returns_only_the_failures
        ; test_case "a sidecar read failure is not empty history" `Quick
            test_sidecar_read_failure_is_not_empty_history
        ] )
    ; ( "projection"
      , [ test_case "the summary counts only this fact" `Quick test_summary_counts_only_this_fact
        ; test_case "an unused fact has an empty summary" `Quick
            test_summary_of_an_unused_fact_is_empty
        ; test_case "the summary json names every field" `Quick
            test_summary_json_names_every_field
        ; test_case "one index preserves per-fact summaries across ids and captures" `Quick
            test_summary_index_matches_per_fact_scan
        ] )
    ]
;;
