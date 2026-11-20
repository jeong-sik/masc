open Alcotest
open Masc

module Outcome = Keeper_cache_outcome
module Reading = Keeper_cache_outcome_reading
module H = Keeper_hooks_agent_core
module Snapshot = Keeper_provider_input_snapshot
module T = Agent_core.Types

let keeper = "keeper-a"
let trace = "trace"
let runtime_a = "claude.sonnet"
let runtime_b = "glm.air"

(* Whole seconds, as the ledger writes them. *)
let t0 = 1_795_000_000.0

let request_row = Cost_ledger.Raw_observation Runtime_usage_scope.Per_request

(* Agent_core.Types has two constructors of this name. *)
let provider_default : T.cache_write_lifetime = T.Provider_default

(* One cost row as the writer writes it, stamped [at] seconds after [t0]. *)
let row
      ?(agent = keeper)
      ?(trace_id = trace)
      ?(runtime = runtime_a)
      ?latency_ms
      ?lifetime
      ~turn
      ~at
      projection
  =
  let telemetry =
    { T.default_inference_telemetry with
      T.request_latency_ms = latency_ms
    ; cache_write_lifetime = lifetime
    }
  in
  let json =
    H.cost_event_payload
      ~agent_name:agent
      ~task_id:None
      ~trace_id
      ~keeper_turn_id:turn
      ~agent_core_turn_ordinal:0
      ~model:"model"
      ~usage_projection:projection
      ~runtime_attempt:("routing-run", runtime, 0)
      ~input_tokens:100
      ~output_tokens:1
      ~cost_usd:0.0
      ~cache_creation_input_tokens:30
      ~cache_read_input_tokens:60
      ~telemetry
      ()
  in
  match json with
  | `Assoc fields ->
    `Assoc
      (( "timestamp"
       , `String (Masc_domain.iso8601_of_unix_seconds (t0 +. Float.of_int at)) )
       :: List.remove_assoc "timestamp" fields)
  | other -> other
;;

let turn_ref turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
let one_hour _runtime_id = 3600.0
let claude_default runtime_id =
  if String.equal runtime_id runtime_a then Ok 300.0 else Error Reading.Default_undeclared
;;
let user text = T.text_message T.User text

(* A snapshot of a turn whose last request [runtime] answered: the system
   prompt digest [system], then [messages]. *)
let view ?(runtime = runtime_a) ~system messages : Outcome.snapshot_view =
  let sized payload =
    String.length (Snapshot.payload_bytes payload), Snapshot.payload_sha256 payload
  in
  let message_part (message : T.message) =
    let bytes, sha256 = sized (Snapshot.message_payload message) in
    Snapshot.Message { role = T.role_to_string message.T.role }, bytes, sha256
  in
  { Outcome.runtime_profile = runtime
  ; parts =
      List.mapi
        (fun part_index (part_kind, part_bytes, part_sha256) ->
           { Snapshot.part_index; part_kind; part_bytes; part_sha256 })
        ((Snapshot.System_prompt, 0, system) :: List.map message_part messages)
  }
;;

(* Rows are listed oldest first and visited newest first, as the ledger
   reader delivers them. *)
let walk ~turn entries_oldest_first =
  List.fold_left
    Outcome.visit
    (Outcome.start ~keeper ~turn_ref:(turn_ref turn) ~horizon_s:one_hour)
    (List.rev entries_oldest_first)
;;

let parsed rows = List.map (fun json -> Dated_jsonl.Parsed json) rows

let reading
      ?(current_snapshot = Error "no snapshot")
      ?(earlier_snapshot = fun _ -> Error "no snapshot")
      walk
  =
  Outcome.reading_of_walk
    walk
    ~provider_default_s:claude_default
    ~current_snapshot
    ~earlier_snapshot
;;

let rec member path json =
  match path, json with
  | [], value -> value
  | key :: rest, `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> member rest value
     | None -> failf "no %s in %s" key (Yojson.Safe.to_string json))
  | key :: _, other -> failf "%s: not an object: %s" key (Yojson.Safe.to_string other)
;;

let check_json label expected path reading =
  check
    string
    label
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string (member path (Reading.to_json reading)))
;;

(* Turn 100 and turn 102 ran on runtime A, turn 101 on runtime B between
   them. The earlier request of turn 102 is the last of turn 100: B's
   request could not have touched A's cache, and neither could another
   Keeper's request on A. *)
let fallback_turns =
  [ row ~turn:100 ~at:20 ~latency_ms:20_000 ~lifetime:provider_default request_row
  ; row ~turn:100 ~at:40 ~latency_ms:15_000 ~lifetime:provider_default request_row
  ; row ~turn:100 ~at:41 Cost_ledger.Resolved_delta
  ; row ~turn:101 ~at:300 ~runtime:runtime_b ~latency_ms:10_000 request_row
  ; row ~turn:101 ~at:301 Cost_ledger.Resolved_delta
  ; row ~agent:"keeper-b" ~turn:7 ~at:350 ~latency_ms:1_000 request_row
  ; row ~turn:102 ~at:425 ~latency_ms:20_000 request_row
  ; row ~turn:102 ~at:450 ~latency_ms:5_000 request_row
  ; row ~turn:102 ~at:451 Cost_ledger.Resolved_delta
  ]
;;

let test_the_earlier_request_is_the_same_runtimes () =
  let walked = walk ~turn:102 (parsed fallback_turns) in
  check bool "the walk ends at the earlier request" true (Outcome.finished walked);
  let history = [ user "a"; user "b" ] in
  let reading =
    reading
      ~earlier_snapshot:(fun turn ->
        if Ids.Turn_ref.equal turn (turn_ref 100)
        then Ok (view ~system:"s" history)
        else Error "only turn 100's snapshot holds the earlier request")
      ~current_snapshot:(Ok (view ~system:"s" (history @ [ user "c" ])))
      walked
  in
  check int "another Keeper's row is not counted as unattributed" 0
    reading.Reading.unattributed_rows;
  check_json "the turn's oldest row is its first request" (`Float (t0 +. 425.))
    [ "outcome"; "request"; "ended_at" ] reading;
  check_json "the runtime used in between" (`String runtime_b)
    [ "outcome"; "other_runtime_since" ] reading;
  check_json "the earlier request is turn 100's last" (`Float (t0 +. 40.))
    [ "outcome"; "earlier"; "request"; "ended_at" ] reading;
  check_json "idle from start to start" (`Float 380.)
    [ "outcome"; "earlier"; "idle"; "idle_s" ] reading;
  check_json "the provider default the catalog declares" (`Float 300.)
    [ "outcome"; "earlier"; "idle"; "lifetime"; "lifetime_s" ] reading;
  check_json "outlived" (`String "outlived")
    [ "outcome"; "earlier"; "idle"; "lifetime"; "check" ] reading;
  check_json "turn 100's snapshot is compared with this turn's" (`String "appended")
    [ "outcome"; "earlier"; "prefix"; "messages"; "kind" ] reading
;;

let test_the_search_stops_before_the_horizon () =
  let first = row ~turn:200 ~at:5_000 ~latency_ms:10_000 request_row in
  let rows =
    [ row ~turn:199 ~at:1_000 ~latency_ms:10_000 ~lifetime:T.One_hour request_row
    ; row ~turn:199 ~at:1_001 Cost_ledger.Resolved_delta
    ; first
    ]
  in
  (* Another runtime's row inside the hour keeps the search going. *)
  let partial =
    walk
      ~turn:200
      (parsed [ row ~turn:199 ~runtime:runtime_b ~at:4_000 request_row; first ])
  in
  check bool "another runtime's request does not end the walk" false
    (Outcome.finished partial);
  (* The first request started at t0 + 4990; the floor is an hour and the
     clock's second before that. *)
  let floor = t0 +. 4_990. -. 3_600. -. 1. in
  check bool "a day ending after the floor is read" true
    (Outcome.reads_before partial (floor +. 1.));
  check bool "a day ending before it is not" false
    (Outcome.reads_before partial (floor -. 1.));
  check_json "no request of the runtime within the hour" (`String "none_within")
    [ "outcome"; "earlier"; "kind" ] (reading (walk ~turn:200 (parsed rows)))
;;

let test_a_turn_without_rows_ends_at_a_lower_turn () =
  let walked =
    walk
      ~turn:105
      (parsed [ row ~turn:103 ~at:10 request_row; row ~turn:104 ~at:20 request_row ])
  in
  check bool "a lower turn number ends the walk" true (Outcome.finished walked);
  check_json "the turn is not in the ledger" (`String "turn_not_in_ledger")
    [ "outcome"; "kind" ] (reading walked)
;;

(* The turn count runs on across a trace rotation, so a lower number of an
   earlier trace ends the walk too, and the reader opens no older day. *)
let test_a_lower_turn_of_an_earlier_trace_ends_the_walk () =
  let walked =
    walk ~turn:105 (parsed [ row ~trace_id:"earlier-trace" ~turn:104 ~at:10 request_row ])
  in
  check bool "an earlier trace's lower number ends the walk" true
    (Outcome.finished walked);
  check_json "the turn is not in the ledger" (`String "turn_not_in_ledger")
    [ "outcome"; "kind" ] (reading walked)
;;

let test_an_unsettled_earlier_turn_is_not_compared () =
  let rows =
    [ row ~turn:300 ~at:100 ~latency_ms:1_000 request_row
    ; row ~turn:301 ~at:200 ~latency_ms:1_000 request_row
    ]
  in
  let reading = reading (walk ~turn:301 (parsed rows)) in
  check_json "its snapshot may hold a later failed request"
    (`String "earlier_turn_not_settled")
    [ "outcome"; "earlier"; "prefix"; "reason"; "kind" ] reading;
  check_json "a row without a lifetime leaves it unrecorded" (`String "unrecorded")
    [ "outcome"; "earlier"; "idle"; "lifetime"; "kind" ] reading
;;

let test_rows_that_cannot_be_read () =
  let malformed =
    Dated_jsonl.Malformed_json { path = "day"; line_number = Some 1; detail = "x" }
  in
  let counted =
    walk ~turn:400 [ Dated_jsonl.Parsed (row ~turn:400 ~at:10 request_row); malformed ]
  in
  check int "a row nobody can be named for is counted" 1
    (reading counted).Reading.unattributed_rows;
  let unreadable =
    match row ~turn:400 ~at:10 request_row with
    | `Assoc fields ->
      `Assoc
        (("cache_write_lifetime", `String "forever")
         :: List.remove_assoc "cache_write_lifetime" fields)
    | other -> other
  in
  check_json "the Keeper's own unreadable request row ends the walk"
    (`String "ledger_row_unreadable") [ "outcome"; "kind" ]
    (reading (walk ~turn:400 [ Dated_jsonl.Parsed unreadable ]))
;;

let test_the_lifetime_check_allows_the_clock_second () =
  let render = function
    | Reading.Outlived -> "outlived"
    | Reading.Within -> "within"
    | Reading.Undecided -> "undecided"
  in
  let check_at idle_s expected =
    check string (Printf.sprintf "idle %.1f against 300" idle_s) expected
      (render (Outcome.lifetime_check ~idle_s ~lifetime_s:300.))
  in
  check_at 301. "outlived";
  check_at 300.5 "undecided";
  check_at 299.5 "undecided";
  check_at 299. "within"
;;

let test_an_inactive_runtime_leaves_its_default_unknown () =
  let request ~at : Reading.request =
    { Reading.turn_ref = turn_ref 1
    ; runtime_id = runtime_b
    ; scope = Runtime_usage_scope.Per_request
    ; ended_at = t0 +. at
    ; latency_ms = Some 1_000
    ; cache_read_tokens = None
    ; cache_creation_tokens = None
    ; lifetime = Some provider_default
    }
  in
  let lifetime =
    match
      Outcome.idle
        ~provider_default_s:(fun _ -> Error Reading.Runtime_inactive)
        ~earlier:(request ~at:10.)
        ~current:(request ~at:400.)
    with
    | Reading.Start_unrecorded -> "start unrecorded"
    | Reading.Idle { lifetime = Reading.Lifetime_unrecorded; _ } -> "unrecorded"
    | Reading.Idle { lifetime = Reading.Provider_default_unknown Reading.Default_undeclared; _ }
      -> "undeclared"
    | Reading.Idle { lifetime = Reading.Provider_default_unknown Reading.Runtime_inactive; _ }
      -> "runtime inactive"
    | Reading.Idle { lifetime = Reading.Lifetime_declared _; _ } -> "declared"
  in
  check string "not the catalog's silence" "runtime inactive" lifetime
;;

let test_snapshots_compare_the_two_turns () =
  let request turn : Reading.request =
    { Reading.turn_ref = turn_ref turn
    ; runtime_id = runtime_a
    ; scope = Runtime_usage_scope.Per_request
    ; ended_at = t0
    ; latency_ms = None
    ; cache_read_tokens = None
    ; cache_creation_tokens = None
    ; lifetime = None
    }
  in
  let compare ~earlier_view ~current_view =
    Outcome.compare_prefix
      ~earlier:(request 1)
      ~earlier_snapshot:(Ok earlier_view)
      ~current:(request 2)
      ~current_snapshot:(Ok current_view)
  in
  let render prefix =
    Yojson.Safe.to_string
      (member
         [ "outcome"; "earlier"; "prefix" ]
         (Reading.to_json
            { Reading.keeper
            ; turn_ref = turn_ref 2
            ; unattributed_rows = 0
            ; outcome =
                Reading.First_request
                  { request = request 2
                  ; other_runtime_since = None
                  ; earlier =
                      Reading.Earlier
                        { request = request 1; idle = Reading.Start_unrecorded; prefix }
                  }
            }))
  in
  let history = [ user "a"; user "b" ] in
  check string "the history only grew"
    {|{"kind":"compared","system_changed":false,"tools_changed":false,"messages":{"kind":"appended","kept":2,"added":1}}|}
    (render
       (compare
          ~earlier_view:(view ~system:"s1" history)
          ~current_view:(view ~system:"s1" (history @ [ user "c" ]))));
  check string "the system prompt changed"
    {|{"kind":"compared","system_changed":true,"tools_changed":false,"messages":{"kind":"appended","kept":2,"added":0}}|}
    (render
       (compare
          ~earlier_view:(view ~system:"s1" history)
          ~current_view:(view ~system:"s2" history)));
  check string "another runtime answered the turn's last request"
    {|{"kind":"not_compared","reason":{"kind":"snapshot_of_other_runtime","turn_ref":"trace#2","runtime_profile":"glm.air"}}|}
    (render
       (compare
          ~earlier_view:(view ~system:"s1" history)
          ~current_view:(view ~runtime:runtime_b ~system:"s1" history)))
;;

(* Every shape a reading can take, once. *)
let readings_of_every_shape () =
  let request ?latency_ms ?lifetime ?(scope = Runtime_usage_scope.Per_request) turn
    : Reading.request
    =
    { Reading.turn_ref = turn_ref turn
    ; runtime_id = runtime_a
    ; scope
    ; ended_at = t0 +. Float.of_int turn
    ; latency_ms
    ; cache_read_tokens = Option.map (fun ms -> ms * 2) latency_ms
    ; cache_creation_tokens = Option.map (fun ms -> ms * 3) latency_ms
    ; lifetime
    }
  in
  let reading outcome =
    { Reading.keeper; turn_ref = turn_ref 9; unattributed_rows = 2; outcome }
  in
  let first ?other_runtime_since earlier =
    reading
      (Reading.First_request
         { request = request ~latency_ms:1_500 9; other_runtime_since; earlier })
  in
  let earlier idle prefix =
    Reading.Earlier
      { request = request ~latency_ms:900 ~lifetime:provider_default 8; idle; prefix }
  in
  let idle lifetime = Reading.Idle { idle_s = 412.5; lifetime } in
  let declared lifetime_s check = Reading.Lifetime_declared { lifetime_s; check } in
  let compared messages =
    Reading.Compared { system_changed = true; tools_changed = false; messages }
  in
  let module C = Message_list_change in
  [ reading Reading.Turn_not_in_ledger
  ; reading (Reading.Ledger_row_unreadable "a request row names no runtime")
  ; reading
      (Reading.Not_per_request
         (request ~scope:Runtime_usage_scope.Conversation_cumulative 9))
  ; first ~other_runtime_since:runtime_b (Reading.No_earlier_request { horizon_s = 3600. })
  ; first (earlier Reading.Start_unrecorded (Reading.Not_compared Reading.Earlier_turn_not_settled))
  ; first
      (earlier
         (idle Reading.Lifetime_unrecorded)
         (Reading.Not_compared
            (Reading.Snapshot_unread { turn_ref = turn_ref 8; detail = "no snapshot" })))
  ; first
      (earlier
         (idle (Reading.Provider_default_unknown Reading.Default_undeclared))
         (Reading.Not_compared
            (Reading.Snapshot_of_other_runtime
               { turn_ref = turn_ref 8; runtime_profile = runtime_b })))
  ; first
      (earlier
         (idle (Reading.Provider_default_unknown Reading.Runtime_inactive))
         (compared (C.Appended { kept = 4; added = 2 })))
  ; first
      (earlier
         (idle (declared 300. Reading.Outlived))
         (compared (C.Tail_removed { kept = 3; removed = 1 })))
  ; first
      (earlier
         (idle (declared 3600. Reading.Within))
         (compared (C.Block_dropped { at = 1; dropped = 2; kept_after = 3; added = 1 })))
  ; first
      (earlier
         (idle (declared 300. Reading.Undecided))
         (compared
            (C.Rewritten_in_place
               { first_index = 2
               ; last_index = 3
               ; rewritten = 2
               ; previous_bytes = 120
               ; current_bytes = 80
               ; first_previous_role = T.Tool
               ; first_current_role = T.User
               ; added = 0
               })))
  ; first
      (earlier
         (idle (declared 300. Reading.Within))
         (compared
            (C.Diverged_at
               { index = 1
               ; previous_role = T.Assistant
               ; previous_bytes = 10
               ; current_role = T.System
               ; current_bytes = 12
               ; previous_count = 5
               ; current_count = 6
               })))
  ; reading
      (Reading.First_request
         { request = request ~latency_ms:20 ~lifetime:T.One_hour 9
         ; other_runtime_since = None
         ; earlier = Reading.No_earlier_request { horizon_s = 3600. }
         })
  ]
;;

let test_a_reading_reads_back_as_written () =
  List.iteri
    (fun index reading ->
       let written = Reading.to_json reading in
       match Reading.of_json written with
       | Error detail -> failf "shape %d did not read back: %s" index detail
       | Ok read ->
         check
           string
           (Printf.sprintf "shape %d" index)
           (Yojson.Safe.to_string written)
           (Yojson.Safe.to_string (Reading.to_json read)))
    (readings_of_every_shape ())
;;

let test_a_reading_of_another_shape_is_refused () =
  let written =
    Reading.to_json
      { Reading.keeper
      ; turn_ref = turn_ref 9
      ; unattributed_rows = 0
      ; outcome = Reading.Turn_not_in_ledger
      }
  in
  let replace key value = function
    | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
    | other -> other
  in
  let refused label json =
    check bool label true (Result.is_error (Reading.of_json json))
  in
  refused "another schema" (replace "schema" (`String "masc.other.v1") written);
  refused "an unknown outcome kind"
    (replace "outcome" (`Assoc [ "kind", `String "cache_hit" ]) written);
  refused "a negative row count" (replace "unattributed_rows" (`Int (-1)) written);
  refused "not an object" (`List [ written ])
;;

let () =
  Alcotest.run
    "keeper cache outcome"
    [ ( "walk"
      , [ test_case "the earlier request is the same runtime's" `Quick
            test_the_earlier_request_is_the_same_runtimes
        ; test_case "the search stops before the horizon" `Quick
            test_the_search_stops_before_the_horizon
        ; test_case "a turn without rows ends at a lower turn" `Quick
            test_a_turn_without_rows_ends_at_a_lower_turn
        ; test_case "a lower turn of an earlier trace ends the walk" `Quick
            test_a_lower_turn_of_an_earlier_trace_ends_the_walk
        ; test_case "an unsettled earlier turn is not compared" `Quick
            test_an_unsettled_earlier_turn_is_not_compared
        ; test_case "rows that cannot be read" `Quick test_rows_that_cannot_be_read
        ] )
    ; ( "outcome"
      , [ test_case "the lifetime check allows the clock second" `Quick
            test_the_lifetime_check_allows_the_clock_second
        ; test_case "an inactive runtime leaves its default unknown" `Quick
            test_an_inactive_runtime_leaves_its_default_unknown
        ; test_case "snapshots compare the two turns" `Quick
            test_snapshots_compare_the_two_turns
        ] )
    ; ( "json"
      , [ test_case "a reading reads back as written" `Quick
            test_a_reading_reads_back_as_written
        ; test_case "a reading of another shape is refused" `Quick
            test_a_reading_of_another_shape_is_refused
        ] )
    ]
;;
