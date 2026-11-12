open Alcotest

module Inspector = Masc_tui_context_inspector
open Turn_record

let turn_ref trace turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn

let record ?(blocks = []) ?input_components ?(usage_scope = Runtime_usage_scope.Per_request)
    ~trace ~turn () : Turn_record.t =
  { request_observations = [];  execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks
  ; input_components
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason = Some "stop"
  ; context_window = Some 200_000
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some
        { transmitted_atoms = 3
        ; total_atoms = 4
        ; measurement = Wire_shape
        ; model_input_front = Model_input_front.At_atom (String.make 64 'c')
        }
  ; response_observed_model_input = None
  ; refused_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = usage_scope
      ; input_provenance = None
      }
  ; turn_output_tokens = None
  ; ts = 1_787_600_000.
  }

let envelope records =
  `Assoc
    [ ( "entries"
      , `List
          (List.map
             (fun record ->
                `Assoc
                  [ "record", Turn_record.to_json record
                  ; "diff_vs_prev", `Null
                  ])
             records) )
    ]

(* The per-turn figures ride along on the page the caller already fetched,
   newest first. A provider that counts its usage across the whole
   conversation carries a number that is not about any one turn; the
   reading must not offer it as this turn's input even though the record
   holds it. *)
let test_recent_turns_carry_the_provider_counts () =
  let newest = record ~trace:"trace-b" ~turn:7 () in
  let cumulative =
    record ~trace:"trace-b" ~turn:6
      ~usage_scope:Runtime_usage_scope.Conversation_cumulative ()
  in
  let middle = record ~trace:"trace-b" ~turn:5 () in
  let unavailable =
    record ~trace:"trace-b" ~turn:4
      ~usage_scope:Runtime_usage_scope.Usage_scope_unavailable ()
  in
  match
    Inspector.decode_turn_records
      (envelope [ unavailable; middle; cumulative; newest ])
  with
  | Error detail -> fail detail
  | Ok decoded -> (
      check int "one row per page row" 4
        (List.length decoded.Inspector.recent);
      match decoded.Inspector.recent with
      | first :: second :: _ :: unavailable_row :: _ ->
          check int "newest first" 7 first.Inspector.turn;
          check bool "the provider's per-request figure rides along" true
            (first.Inspector.input_tokens = Some 1000);
          check bool "a cumulative scope yields no per-request figure" true
            (second.Inspector.input_tokens = None);
          check bool
            "an unknown scope is not a per-request figure" true
            (unavailable_row.Inspector.input_tokens = None)
      | _ -> fail "the page held four rows")

(* The cursor a short list can hold: selection, rendered detail and Enter
   read one normalized value, so a refresh that shortens the component
   list under a cursor set against the old one leaves every reader naming
   the same row. (#47714) *)
let test_normalized_cursor_holds_the_list () =
  check int "a cursor inside the list stays" 2
    (Inspector.normalized_cursor ~count:5 2);
  check int "a cursor past a shortened list clamps to its last row" 2
    (Inspector.normalized_cursor ~count:3 4);
  check int "an empty list holds cursor zero" 0
    (Inspector.normalized_cursor ~count:0 4);
  check int "a negative cursor never survives" 0
    (Inspector.normalized_cursor ~count:5 (-2))

let test_recent_input_trend_keeps_unavailable_and_zero () =
  let with_input input_tokens (record : Turn_record.t) =
    { record with usage = { record.usage with input_tokens } }
  in
  let oldest = record ~trace:"trend" ~turn:1 () |> with_input (Some 100) in
  let cumulative =
    record ~trace:"trend" ~turn:2
      ~usage_scope:Runtime_usage_scope.Conversation_cumulative ()
    |> with_input (Some 999)
  in
  let zero = record ~trace:"trend" ~turn:3 () |> with_input (Some 0) in
  let absent = record ~trace:"trend" ~turn:4 () |> with_input None in
  let invalid = record ~trace:"trend" ~turn:5 () |> with_input (Some (-1)) in
  let newest = record ~trace:"trend" ~turn:6 () |> with_input (Some 200) in
  let trend records =
    match Inspector.decode_turn_records (envelope records) with
    | Error detail -> fail detail
    | Ok selection -> Inspector.recent_input_trend selection.recent in
  let observed = trend [oldest; cumulative; zero; absent; invalid; newest] in
  check bool "one typed observation per turn, oldest first" true
    (observed.samples =
       [ Inspector.Input_count 100; Inspector.Input_unavailable; Inspector.Input_count 0
       ; Inspector.Input_unavailable; Inspector.Input_invalid (-1); Inspector.Input_count 200 ]);
  check int "only nonnegative counts set the scale" 3 observed.measured_count;
  check int "no estimates in this page" 0 observed.estimate_count;
  check (option (pair int int)) "zero is included in the bounds"
    (Some (0, 200)) observed.bounds;
  let no_valid = trend [absent; invalid] in
  check bool "missing and invalid turns remain distinct" true
    (no_valid.samples = [Inspector.Input_unavailable; Inspector.Input_invalid (-1)]);
  check int "no valid counts" 0 no_valid.measured_count;
  check (option (pair int int)) "no valid counts have no scale" None no_valid.bounds;
  let only_zero = trend [zero] in
  check int "one zero is valid" 1 only_zero.measured_count;
  check (option (pair int int)) "one zero has a zero scale"
    (Some (0, 0)) only_zero.bounds

(* The active-context figure adds two counts, and a sum the integer range
   cannot hold is not a figure: reporting [None] keeps an unrepresentable
   total in the same place as an unavailable one, while a real zero and a
   single extreme count stay exact. (#47698) *)
let test_client_context_sum_stays_representable () =
  let read ~scope ~input_tokens ~output_tokens =
    Inspector.client_context_tokens
      ~scope:(scope : Runtime_usage_scope.t)
      ~input_tokens ~output_tokens
  in
  check (option int) "a sum past max_int is not a figure" None
    (read ~scope:Runtime_usage_scope.Per_request
       ~input_tokens:(Some max_int) ~output_tokens:(Some 1));
  check (option int) "a sum below min_int is not a figure" None
    (read ~scope:Runtime_usage_scope.Per_request
       ~input_tokens:(Some min_int) ~output_tokens:(Some (-1)));
  check (option int) "a real zero stays a real zero" (Some 0)
    (read ~scope:Runtime_usage_scope.Per_request
       ~input_tokens:(Some 0) ~output_tokens:(Some 0));
  check (option int) "an extreme count alone stays exact" (Some max_int)
    (read ~scope:Runtime_usage_scope.Per_request
       ~input_tokens:(Some max_int) ~output_tokens:None);
  check (option int) "an ordinary sum still adds" (Some 1200)
    (read ~scope:Runtime_usage_scope.Per_request
       ~input_tokens:(Some 1000) ~output_tokens:(Some 200));
  check (option int) "other scopes still report no figure" None
    (read ~scope:Runtime_usage_scope.Conversation_cumulative
       ~input_tokens:(Some 1000) ~output_tokens:(Some 200))

(* An estimate after a compaction and a counted request carry the same bare
   number; the provenance the record keeps is what the trend separates them
   by, and a record without it stays an ordinary count rather than a
   guess. *)
let test_recent_input_trend_marks_estimates_apart () =
  let marked input_tokens provenance (record : Turn_record.t) =
    { record with
      usage =
        { record.usage with input_tokens; input_provenance = provenance }
    }
  in
  let measured =
    record ~trace:"estimate" ~turn:1 ()
    |> marked (Some 100) (Some Turn_input_provenance.Measured_request)
  in
  let estimate =
    record ~trace:"estimate" ~turn:2 ()
    |> marked (Some 45000) (Some Turn_input_provenance.Context_estimate)
  in
  let unmarked = record ~trace:"estimate" ~turn:3 () |> marked (Some 200) None in
  match
    Inspector.decode_turn_records (envelope [ measured; estimate; unmarked ])
  with
  | Error detail -> fail detail
  | Ok selection -> (
      let trend = Inspector.recent_input_trend selection.recent in
      check bool "an estimate keeps its own kind, oldest first" true
        (trend.samples =
           [ Inspector.Input_count 100
           ; Inspector.Input_estimate 45000
           ; Inspector.Input_count 200
           ]);
      check int "measured counts stay measured" 2 trend.measured_count;
      check int "estimates are counted apart" 1 trend.estimate_count;
      check (option (pair int int)) "an estimate still spans the scale"
        (Some (100, 45000)) trend.bounds;
      match selection.recent with
      | _unmarked :: estimate_row :: _ ->
          check bool "the estimate row carries its provenance" true
            (estimate_row.input_provenance
             = Some Turn_input_provenance.Context_estimate)
      | _ -> fail "the page held three rows")

let test_recent_page_skipped_count_is_not_invented () =
  let row = record ~trace:"skipped" ~turn:1 () in
  let count fields =
    match envelope [row] with
    | `Assoc entries ->
        (match Inspector.decode_turn_records (`Assoc (fields @ entries)) with
         | Error detail -> fail detail
         | Ok selection -> selection.skipped_rows)
    | _ -> fail "envelope is an object" in
  check (option int) "reported skips survive" (Some 2)
    (count ["skipped_rows", `Int 2]);
  check (option int) "reported zero remains known" (Some 0)
    (count ["skipped_rows", `Int 0]);
  check (option int) "missing count stays unknown" None (count []);
  check (option int) "negative count stays unknown" None
    (count ["skipped_rows", `Int (-1)]);
  check (option int) "malformed count stays unknown" None
    (count ["skipped_rows", `String "2"])

let test_page_failure_is_distinct_from_partial_failures () =
  let offline = Inspector.Request_failed "offline" in
  let unreadable = Inspector.Turn_read_failed
      { detail = "unreadable"; forecast = Error "unavailable" } in
  check bool "request failure has no page" true
    (Inspector.page_read_failed offline);
  check bool "first failure starts at the beginning" true
    (Inspector.page_scroll_should_reset ~previous:None offline);
  check bool "the same failure keeps its reading position" false
    (Inspector.page_scroll_should_reset ~previous:(Some offline) offline);
  check bool "a changed failure starts at the beginning" true
    (Inspector.page_scroll_should_reset ~previous:(Some offline)
       (Inspector.Request_failed "timeout"));
  check bool "turn failure has no page" true
    (Inspector.page_read_failed unreadable);
  check bool "same turn failure keeps its reading position" false
    (Inspector.page_scroll_should_reset ~previous:(Some unreadable) unreadable);
  check bool "a different turn failure starts at the beginning" true
    (Inspector.page_scroll_should_reset ~previous:(Some unreadable)
       (Inspector.Turn_read_failed { detail = "damaged"; forecast = Error "unavailable" }));
  check bool "a different failure kind starts at the beginning" true
    (Inspector.page_scroll_should_reset ~previous:(Some offline) unreadable);
  let selection =
    match Inspector.decode_turn_records (envelope [record ~trace:"page" ~turn:1 ()]) with
    | Ok selection -> selection
    | Error detail -> fail detail in
  let partial = Inspector.Turn_read
      { selection; provider_input = Error "unavailable"
      ; response = Error "unavailable"; forecast = Error "unavailable" } in
  check bool "partial errors still have a page" false
    (Inspector.page_read_failed partial);
  check bool "a recovered page starts at the beginning" true
    (Inspector.page_scroll_should_reset ~previous:(Some offline) partial);
  check bool "a successful refresh keeps its reading position" false
    (Inspector.page_scroll_should_reset ~previous:(Some partial) partial)

let test_newest_exact_composition_wins () =
  let observed =
    record ~trace:"trace-a" ~turn:1
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Dynamic_context
          ; bytes = 120
          }
        ; { component = Tool_schemas; bytes = 80 }
        ]
      ()
  in
  let unobserved = record ~trace:"trace-a" ~turn:2 () in
  match Inspector.decode_turn_records (envelope [ observed; unobserved ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is the newest one, attributed or not" 2
        decoded.Inspector.latest.absolute_turn;
      check int "rows keeps the whole page" 2
        (List.length decoded.Inspector.rows);
      check int "rows is newest first" 2
        (List.hd decoded.Inspector.rows).absolute_turn;
      (match decoded.Inspector.attributed with
       | None -> fail "an attributed row was on the page and must be reported"
       | Some attributed ->
           check int "attribution comes from the newest attributed row" 1
             attributed.Inspector.record.absolute_turn;
           check int "and the reading says how far back that row is" 1
             attributed.Inspector.turns_behind_latest;
           check int "attributed bytes" 200
             (List.fold_left
                (fun total (component : Turn_record.input_component) ->
                  total + component.bytes)
                0 attributed.Inspector.components))

(* On 2026-09-01 every row of two keepers' 50-turn pages was
   unattributed, and the reading failed outright -- discarding the token,
   usage, wire and window readings the newest row did carry. *)
let test_page_without_attribution_still_reads () =
  let older = record ~trace:"trace-a" ~turn:7 () in
  let newer = record ~trace:"trace-a" ~turn:8 () in
  match Inspector.decode_turn_records (envelope [ older; newer ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is still reported" 8
        decoded.Inspector.latest.absolute_turn;
      check bool "with no attribution to show" true
        (Option.is_none decoded.Inspector.attributed)

(* The provider-input fetch, the proof tab's drawing and its j/k and Enter
   keys read one row, so a stepped-back turn's keys walk that turn's
   components. *)
let test_viewing_record_names_one_row () =
  let attributed =
    record ~trace:"trace-a" ~turn:3
      ~input_components:[ { component = Tool_schemas; bytes = 80 } ]
      ()
  in
  let middle = record ~trace:"trace-a" ~turn:4 () in
  let newest = record ~trace:"trace-a" ~turn:5 () in
  match
    Inspector.decode_turn_records (envelope [ attributed; middle; newest ])
  with
  | Error detail -> fail detail
  | Ok decoded ->
      let viewed turn_back =
        Option.map
          (fun (row : Turn_record.t) -> row.absolute_turn)
          (Inspector.viewing_record decoded ~turn_back)
      in
      check (option int) "the newest reading views the attributed row"
        (Some 3) (viewed 0);
      check (option int) "a stepped-back turn views its own row" (Some 4)
        (viewed 1);
      check (option int) "the oldest step views that row" (Some 3) (viewed 2);
      check (option int) "a step past the page borrows no other row" None
        (viewed 3)

let test_empty_page_is_an_error () =
  check bool "an empty page has no latest row to report" true
    (Result.is_error (Inspector.decode_turn_records (envelope [])))

let test_malformed_row_is_not_dropped () =
  let good = record ~trace:"trace-a" ~turn:1 ~input_components:[] () in
  let json =
    match envelope [ good ] with
    | `Assoc [ "entries", `List rows ] ->
      `Assoc [ "entries", `List (`Assoc [ "diff_vs_prev", `Null ] :: rows) ]
    | _ -> fail "fixture shape changed"
  in
  check bool "malformed row fails the whole reading" true
    (Result.is_error (Inspector.decode_turn_records json))

let digest text = Agent_core_sha256.(digest_string text |> to_hex)

let wire =
  Llm_provider.Request_wire_observer.observation
    ~capture_id:(Some "capture-1")
    ~provider:"glm"
    ~model:"glm-5.3"
    ~http_codec:"openai_chat"
    ~stream:true
    ~body:"serialized provider body"

let message_text =
  Yojson.Safe.to_string
    (`Assoc
       [ "role", `String "tool"
       ; ( "content_blocks"
         , `List
             [ `Assoc
                 [ "type", `String "tool_result"
                 ; "tool_use_id", `String "call-1"
                 ; "content", `String "large result"
                 ; "is_error", `Bool false
                 ]
             ] )
       ])

let tool_text =
  Yojson.Safe.to_string
    (`Assoc
       [ "name", `String "masc_execute"
       ; "description", `String "Execute one command"
       ; "input_schema", `Assoc [ "type", `String "object" ]
       ])

let part_json ~index ~kind ?label text =
  `Assoc
    ([ "index", `Int index; "kind", `String kind ]
     @ (match label with
        | None -> []
        | Some (key, value) -> [ key, `String value ])
     @ [ "bytes", `Int (String.length text); "sha256", `String (digest text) ])

let provider_input_response ?(keeper = "omega") ?(trace = "trace-map")
    ?(turn = 9) system_prompt =
  `Assoc
    [ "dashboard_surface", `String "/api/v1/keepers/:name/provider-input"
    ; "schema", `String "masc.provider-input-manifest.v1"
    ; "keeper", `String keeper
    ; "trace_id", `String trace
    ; "absolute_turn", `Int turn
    ; "turn_ref", Ids.Turn_ref.to_yojson (turn_ref trace turn)
    ; "runtime_profile", `String "glm-coding"
    ; "captured_at", `Float 1_787_600_000.
    ; "wire", Llm_provider.Request_wire_observer.observation_to_yojson wire
    ; ( "parts"
      , `List
          [ part_json ~index:0 ~kind:"system_prompt" system_prompt
          ; part_json ~index:1 ~kind:"message" ~label:("role", "tool") message_text
          ; part_json ~index:2 ~kind:"tool_schema" ~label:("name", "masc_execute")
              tool_text
          ] )
    ]

let part_response ?(keeper = "omega") ?(turn = 9) ~part text =
  `Assoc
    [ "dashboard_surface", `String "/api/v1/keepers/:name/provider-input/part"
    ; "schema", `String "masc.provider-input-part.v1"
    ; "keeper", `String keeper
    ; "turn_ref", Ids.Turn_ref.to_yojson (turn_ref "trace-map" turn)
    ; "part", part
    ; "text", `String text
    ]

let decode_provider_input system_prompt =
  Inspector.decode_provider_input
    ~expected_keeper:"omega"
    ~expected_turn_ref:(turn_ref "trace-map" 9)
    (provider_input_response system_prompt)

let test_provider_input_is_bound_to_exact_turn () =
  let system_prompt = "immutable keeper instructions" in
  match decode_provider_input system_prompt with
  | Error detail -> fail detail
  | Ok input ->
    check string "exact turn ref" "trace-map#9"
      (Ids.Turn_ref.to_string input.turn_ref);
    check int "system + message + tool" 3
      (List.length (Inspector.exact_input_items input));
    check string "serialized request digest survives" wire.body_sha256
      input.wire.body_sha256;
    check string "tool result is openable" "Message · tool"
      (Inspector.exact_input_label
         (List.nth (Inspector.exact_input_items input) 1).kind)

let test_provider_input_rejects_another_keeper_or_turn () =
  let system_prompt = "immutable keeper instructions" in
  check bool "wrong keeper rejected" true
    (Result.is_error
       (Inspector.decode_provider_input
          ~expected_keeper:"omega"
          ~expected_turn_ref:(turn_ref "trace-map" 9)
          (provider_input_response ~keeper:"other" system_prompt)));
  check bool "wrong turn rejected" true
    (Result.is_error
       (Inspector.decode_provider_input
          ~expected_keeper:"omega"
          ~expected_turn_ref:(turn_ref "trace-map" 9)
          (provider_input_response ~turn:10 system_prompt)))

let test_input_map_opens_only_digest_verified_system_prompt () =
  let system_prompt = "immutable keeper instructions" in
  let block =
    { block = Prompt_block_id.Keeper_instructions
    ; bytes = String.length system_prompt
    ; digest = digest system_prompt
    }
  in
  let observed =
    record ~trace:"trace-map" ~turn:9 ~blocks:[ block ]
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Keeper_instructions
          ; bytes = String.length system_prompt
          }
        ; { component = Message_tool_result; bytes = 12 }
        ]
      ()
  in
  let input =
    match decode_provider_input system_prompt with
    | Ok input -> input
    | Error detail -> fail detail
  in
  let rows = Inspector.input_map_rows observed (Some input) in
  check (option int) "system prompt verified against its listed part" (Some 0)
    (Option.map
       (fun (item : Inspector.exact_input_item) -> item.index)
       (List.nth rows 0).verified_item);
  check bool "system prompt has verified evidence" true
    ((List.nth rows 0).evidence = Inspector.Verified_exact_text);
  check bool "message points to the same-turn serialized snapshot" true
    ((List.nth rows 1).evidence = Inspector.Serialized_turn_snapshot);
  check bool "message names its typed source" true
    ((List.nth rows 1).source = Inspector.Provider_message_list);
  check (option string) "prompt block retains its producer digest"
    (Some block.digest) (List.nth rows 0).digest;
  let changed =
    { observed with blocks = [ { block with digest = digest "other" } ] }
  in
  let changed_row = List.hd (Inspector.input_map_rows changed (Some input)) in
  check bool "digest mismatch is not opened" true
    (Option.is_none changed_row.verified_item);
  check bool "digest mismatch is not mislabeled verified" true
    (changed_row.evidence = Inspector.Serialized_turn_snapshot);
  let without_snapshot = Inspector.input_map_rows observed None in
  check bool "prompt digest remains explicit without a snapshot" true
    ((List.nth without_snapshot 0).evidence = Inspector.Producer_digest_only);
  check bool "a component with no digest or snapshot stays byte-only" true
    ((List.nth without_snapshot 1).evidence = Inspector.Byte_count_only)

let decoded_input () =
  match decode_provider_input "immutable keeper instructions" with
  | Ok input -> input
  | Error detail -> fail detail

let key_for (input : Inspector.provider_input) index =
  { Inspector.part_keeper = "omega"
  ; part_turn_ref = input.turn_ref
  ; part_item = List.nth input.items index
  }

let test_a_part_is_its_listed_bytes () =
  let input = decoded_input () in
  let message = key_for input 1 in
  let listed = part_json ~index:1 ~kind:"message" ~label:("role", "tool") message_text in
  (match Inspector.decode_part message (part_response ~part:listed message_text) with
   | Ok text ->
     check bool "a message reads as its JSON" true
       (Yojson.Safe.equal
          (Yojson.Safe.from_string message_text)
          (Yojson.Safe.from_string text))
   | Error detail -> fail detail);
  let prompt = key_for input 0 in
  let prompt_part = part_json ~index:0 ~kind:"system_prompt" "immutable keeper instructions" in
  check (result string string) "the system prompt reads as its text"
    (Ok "immutable keeper instructions")
    (Inspector.decode_part prompt
       (part_response ~part:prompt_part "immutable keeper instructions"));
  check bool "bytes that do not hash to the listed digest are refused" true
    (Result.is_error
       (Inspector.decode_part prompt
          (part_response ~part:prompt_part "immutable keeper instructionz")));
  check bool "another listed part is refused" true
    (Result.is_error
       (Inspector.decode_part prompt (part_response ~part:listed message_text)));
  check bool "another turn's part is refused" true
    (Result.is_error
       (Inspector.decode_part prompt
          (part_response ~turn:10 ~part:prompt_part "immutable keeper instructions")));
  check bool "another keeper's part is refused" true
    (Result.is_error
       (Inspector.decode_part prompt
          (part_response ~keeper:"other" ~part:prompt_part
             "immutable keeper instructions")))

let test_parts_must_be_numbered_without_a_gap () =
  let gapped =
    match provider_input_response "immutable keeper instructions" with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "parts", `List (first :: _ :: rest) -> "parts", `List (first :: rest)
             | field -> field)
           fields)
    | _ -> fail "fixture shape changed"
  in
  check bool "a list with a missing index is refused" true
    (Result.is_error
       (Inspector.decode_provider_input
          ~expected_keeper:"omega"
          ~expected_turn_ref:(turn_ref "trace-map" 9)
          gapped))

let test_a_pane_reads_the_part_it_shows () =
  let system_prompt = "immutable keeper instructions" in
  let observed =
    record ~trace:"trace-map" ~turn:9
      ~blocks:
        [ { block = Prompt_block_id.Keeper_instructions
          ; bytes = String.length system_prompt
          ; digest = digest system_prompt
          }
        ]
      ~input_components:
        [ { component = Message_tool_result; bytes = 12 }
        ; { component = Prompt_block Prompt_block_id.Keeper_instructions
          ; bytes = String.length system_prompt
          }
        ]
      ()
  in
  let selection =
    match Inspector.decode_turn_records (envelope [ observed ]) with
    | Ok selection -> selection
    | Error detail -> fail detail
  in
  let input = decoded_input () in
  let reading =
    Inspector.Turn_read
      { selection
      ; provider_input = Ok input
      ; response = Error "not read"
      ; forecast = Error "not read"
      }
  in
  let shown ~tab ~opened ~cursor =
    Option.map
      (fun (key : Inspector.part_key) -> key.part_item.index)
      (Inspector.shown_part ~keeper:"omega" ~tab ~target:(Inspector.Recent 0) ~opened ~cursor
         reading)
  in
  check (option int) "the request tab reads the item under the cursor" (Some 2)
    (shown ~tab:Inspector.Exact_input ~opened:None ~cursor:2);
  check (option int) "a cursor past the list reads the last item" (Some 2)
    (shown ~tab:Inspector.Exact_input ~opened:None ~cursor:7);
  check (option int) "an opened item wins over the cursor" (Some 1)
    (shown ~tab:Inspector.Exact_input ~opened:(Some 1) ~cursor:2);
  check (option int) "an opened item past the list reads nothing" None
    (shown ~tab:Inspector.Exact_input ~opened:(Some 5) ~cursor:0);
  check (option int) "a verified proof row reads its listed part" (Some 0)
    (shown ~tab:Inspector.Input_map ~opened:None ~cursor:1);
  check (option int) "an unverified proof row reads nothing" None
    (shown ~tab:Inspector.Input_map ~opened:None ~cursor:0);
  check (option int) "the composition tab reads nothing" None
    (shown ~tab:Inspector.Composition ~opened:None ~cursor:0)

let test_pinned_input_survives_record_failure () =
  let input = decoded_input () in
  let reading = Inspector.Exact_read
      { turn_ref = input.turn_ref
      ; record = Observed (Error "canonical history unavailable")
      ; provider_input = Observed (Ok input)
      ; response = Pending } in
  let target = Inspector.Pinned input.turn_ref in
  check bool "response remains pending" true (Inspector.is_loading reading);
  check bool "input survives record failure" true (Option.is_some (Inspector.observed_input reading));
  check bool "no substitute record" true (Option.is_none (Inspector.inspected_record ~target reading));
  let shown = Inspector.shown_part ~keeper:"omega" ~tab:Inspector.Exact_input
      ~target ~opened:None ~cursor:0 reading in
  (match shown with
   | None -> fail "known original input was hidden by unrelated record failure"
   | Some key -> check bool "part names the original turn" true
       (Ids.Turn_ref.equal key.part_turn_ref input.turn_ref));
  check bool "a foreign pinned turn cannot borrow the part" true
    (Option.is_none (Inspector.shown_part ~keeper:"omega" ~tab:Inspector.Exact_input
      ~target:(Inspector.Pinned (turn_ref "other-trace" 9)) ~opened:None ~cursor:0 reading));
  check bool "a recent target cannot borrow a pinned reading" true
    (Option.is_none (Inspector.shown_part ~keeper:"omega" ~tab:Inspector.Exact_input
      ~target:(Inspector.Recent 0) ~opened:None ~cursor:0 reading))

let test_pinned_unattributed_record_stays_exact () =
  let input = decoded_input () in
  let original = record ~trace:"trace-map" ~turn:9 () in
  let reading = Inspector.Exact_read
      { turn_ref = input.turn_ref
      ; record = Observed (Ok { record = original; skipped_rows = 2 })
      ; provider_input = Observed (Ok input)
      ; response = Observed (Error "history page unavailable") } in
  check bool "settled failure is not an endless loading state" false (Inspector.is_loading reading);
  (match Inspector.inspected_record ~target:(Inspector.Pinned input.turn_ref) reading with
   | None -> fail "an unattributed original became an absent source"
   | Some found -> check bool "no attributed/latest replacement" true
       (Ids.Turn_ref.equal found.turn_ref original.turn_ref));
  check bool "proof does not invent component rows" true
    (Option.is_none (Inspector.shown_part ~keeper:"omega" ~tab:Inspector.Input_map
      ~target:(Inspector.Pinned input.turn_ref) ~opened:None ~cursor:0 reading));
  check bool "bracket navigation preserves pinned source" true
    (Option.is_none (Inspector.step_recent (Inspector.Pinned input.turn_ref) ~older:true ~count:80))

let test_late_pending_snapshot_cannot_erase_progress () =
  let input = decoded_input () in
  let held : Inspector.reading = Exact_read
      { turn_ref = input.turn_ref
      ; record = Observed (Error "unreadable record")
      ; provider_input = Observed (Ok input)
      ; response = Pending } in
  let incoming : Inspector.reading = Exact_read
      { turn_ref = input.turn_ref; record = Pending; provider_input = Pending
      ; response = Observed (Ok { parts = []; source = Inspector.Newest_history_page }) } in
  let combined = Inspector.merge_progress ~previous:(Some held) incoming in
  check bool "all observations have now settled" false (Inspector.is_loading combined);
  check bool "input remains usable after out-of-order pending fields" true
    (Option.is_some (Inspector.observed_input combined));
  let foreign : Inspector.reading = Exact_read
      { turn_ref = turn_ref "new-source" 9; record = Pending; provider_input = Pending; response = Pending } in
  let changed = Inspector.merge_progress ~previous:(Some combined) foreign in
  check bool "another source starts pending" true (Inspector.is_loading changed);
  check bool "another source does not inherit original input" true
    (Option.is_none (Inspector.observed_input changed))

let test_exact_bytes_preserves_distinct_sizes_and_digit_order () =
  check string "zero bytes" "0 B" (Inspector.exact_bytes 0);
  check string "negative clamps to zero" "0 B" (Inspector.exact_bytes (-7));
  check string "below one thousand" "999 B" (Inspector.exact_bytes 999);
  check string "one thousand" "1,000 B" (Inspector.exact_bytes 1_000);
  check string "125,705 stays distinct from 125,780" "125,705 B"
    (Inspector.exact_bytes 125_705);
  check string "125,780 keeps group order" "125,780 B"
    (Inspector.exact_bytes 125_780);
  check string "nine digits keep group order" "123,456,789 B"
    (Inspector.exact_bytes 123_456_789)

let test_provider_usage_distinguishes_unreported_cache_from_reported_zero () =
  let ollama_json =
    {|{"model":"qwen3:8b","done":true,"done_reason":"stop","message":{"role":"assistant","content":"ok"},"prompt_eval_count":100,"eval_count":20}|}
  in
  let ollama_resp =
    match Llm_provider.Backend_ollama.parse_ollama_response ollama_json with
    | Ok resp -> resp
    | Error err -> fail ("ollama parse: " ^ err)
  in
  let ollama_turn_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Per_request
      ~usage:(Option.get ollama_resp.usage)
      ~telemetry:ollama_resp.telemetry
  in
  check (option int) "ollama cache read stays None" None
    ollama_turn_usage.cache_read_input_tokens;
  check (option int) "ollama cache creation stays None" None
    ollama_turn_usage.cache_creation_input_tokens;
  check string "ollama renders unreported without ratio"
    "Provider usage (last reported request in this turn) · input 100 · cache read unreported"
    (Inspector.provider_usage_summary ollama_turn_usage);
  let openai_zero_json =
    {|{"id":"c1","model":"glm-5.3","choices":[{"index":0,"finish_reason":"stop","message":{"content":"ok"}}],"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":0}}}|}
  in
  let openai_zero_resp =
    match Llm_provider.Backend_openai_parse.parse_openai_response_result openai_zero_json with
    | Ok resp -> resp
    | Error _ -> fail "openai zero parse failed"
  in
  let openai_turn_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Per_request
      ~usage:(Option.get openai_zero_resp.usage)
      ~telemetry:openai_zero_resp.telemetry
  in
  check (option int) "reported zero cache read stays Some 0" (Some 0)
    openai_turn_usage.cache_read_input_tokens;
  check (option int) "unreported cache creation stays None" None
    openai_turn_usage.cache_creation_input_tokens;
  check string "reported zero renders 0 (0.0% of input)"
    "Provider usage (last reported request in this turn) · input 100 · cache read 0 (0.0% of input)"
    (Inspector.provider_usage_summary openai_turn_usage);
  let muse_turn ?prompt_tokens ?cache_read_tokens ?cache_write_tokens ()
      : Runtime_muse_serve.turn_result =
    { session_id = "s-muse"
    ; turn_id = "t-muse"
    ; model = Some "claude-sonnet-4"
    ; text = Some "ok"
    ; usage =
        Some
          { Runtime_muse_msp.input_tokens = 120
          ; output_tokens = 30
          ; cached_tokens = 0
          ; reasoning_tokens = 0
          ; prompt_tokens
          ; cache_read_tokens
          ; cache_write_tokens
          }
    ; last_call_usage = None
    ; tool_calls = 0
    ; approvals_decided = 0
    ; call_models = []
    ; resumed = false
    ; server_version = "1.4.0"
    }
  in
  let muse_terminal_only_resp =
    Masc.Keeper_muse_runtime.For_testing.completed_turn_response
      ~runtime_id:"muse.test"
      ~configured_model:None
      ~latency_ms:10
      (muse_turn ~cache_read_tokens:40 ~cache_write_tokens:10 ())
  in
  let muse_terminal_only_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Turn_total
      ~usage:(Option.get muse_terminal_only_resp.usage)
      ~telemetry:muse_terminal_only_resp.telemetry
  in
  check (option int) "terminal-only muse cache read stays None" None
    muse_terminal_only_usage.cache_read_input_tokens;
  check string "terminal-only muse renders unreported without fabricated 0"
    "Provider usage (client turn total) · input 120 · cache read unreported"
    (Inspector.provider_usage_summary muse_terminal_only_usage);
  let muse_zero_resp =
    Masc.Keeper_muse_runtime.For_testing.completed_turn_response
      ~runtime_id:"muse.test"
      ~configured_model:None
      ~latency_ms:10
      (muse_turn ~prompt_tokens:120 ~cache_read_tokens:0 ~cache_write_tokens:0 ())
  in
  let muse_zero_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Turn_total
      ~usage:(Option.get muse_zero_resp.usage)
      ~telemetry:muse_zero_resp.telemetry
  in
  check (option int) "muse explicit zero cache read stays Some 0" (Some 0)
    muse_zero_usage.cache_read_input_tokens;
  check string "muse explicit zero renders 0"
    "Provider usage (client turn total) · input 120 · cache read 0 · cache created 0"
    (Inspector.provider_usage_summary muse_zero_usage);
  let claude_turn_resp ?cache_creation ?cache_read () =
    Masc.Keeper_claude_code_runtime.For_testing.completed_turn_response
      ~latency_ms:10
      ~turn_id:"turn-claude"
      ~model:"claude-sonnet-4-6"
      ~text:"ok"
      ~turn_total:
        (Some
           { Runtime_claude_code.input_tokens = 120
           ; output_tokens = 30
           ; cache_creation_input_tokens = Option.value cache_creation ~default:0
           ; cache_read_input_tokens = Option.value cache_read ~default:0
           ; reported_cache_creation_input_tokens = cache_creation
           ; reported_cache_read_input_tokens = cache_read
           })
  in
  let claude_unreported_resp = claude_turn_resp () in
  let claude_unreported_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Turn_total
      ~usage:(Option.get claude_unreported_resp.usage)
      ~telemetry:claude_unreported_resp.telemetry
  in
  check (option int) "claude unreported cache read stays None" None
    claude_unreported_usage.cache_read_input_tokens;
  check string "claude unreported renders unreported without fabricated 0"
    "Provider usage (client turn total) · input 120 · cache read unreported"
    (Inspector.provider_usage_summary claude_unreported_usage);
  let claude_zero_resp = claude_turn_resp ~cache_creation:0 ~cache_read:0 () in
  let claude_zero_usage =
    Turn_record.usage_of_reported_counts
      ~scope:Runtime_usage_scope.Turn_total
      ~usage:(Option.get claude_zero_resp.usage)
      ~telemetry:claude_zero_resp.telemetry
  in
  check string "claude explicit zero renders 0"
    "Provider usage (client turn total) · input 120 · cache read 0 · cache created 0"
    (Inspector.provider_usage_summary claude_zero_usage);
  let claude_request_input ?cache_creation ?cache_read ()
    : Runtime_claude_code.request_input
    =
    { input_tokens = 120
    ; cache_creation_input_tokens = Option.value cache_creation ~default:0
    ; cache_read_input_tokens = Option.value cache_read ~default:0
    ; reported_cache_creation_input_tokens = cache_creation
    ; reported_cache_read_input_tokens = cache_read
    }
  in
  let claude_unreported_ctx =
    Masc.Keeper_claude_code_runtime.For_testing.request_context_of_request_input
      (claude_request_input ())
  in
  check bool "claude assistant request without cache fields has cache = None" true
    (Option.is_none claude_unreported_ctx.cache);
  let claude_zero_ctx =
    Masc.Keeper_claude_code_runtime.For_testing.request_context_of_request_input
      (claude_request_input ~cache_creation:0 ~cache_read:0 ())
  in
  check (option int) "claude assistant explicit zero cache read stays Some 0"
    (Some 0)
    (Option.map
       (fun (c : Runtime_observation.request_cache) -> c.cache_read_input_tokens)
       claude_zero_ctx.cache);
  let claude_pos_ctx =
    Masc.Keeper_claude_code_runtime.For_testing.request_context_of_request_input
      (claude_request_input ~cache_creation:10 ~cache_read:40 ())
  in
  check int "claude assistant positive cache inclusive input" 170
    claude_pos_ctx.input_tokens;
  check (option int) "claude assistant positive cache read is Some 40"
    (Some 40)
    (Option.map
       (fun (c : Runtime_observation.request_cache) -> c.cache_read_input_tokens)
       claude_pos_ctx.cache)

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "an unattributed page still reads" `Quick
            test_page_without_attribution_still_reads
        ; test_case "recent turns carry the provider counts" `Quick
            test_recent_turns_carry_the_provider_counts
        ; test_case "recent input history keeps gaps and zero" `Quick
            test_recent_input_trend_keeps_unavailable_and_zero
        ; test_case "client context sum stays representable" `Quick
            test_client_context_sum_stays_representable
        ; test_case "recent input history marks estimates apart" `Quick
            test_recent_input_trend_marks_estimates_apart
        ; test_case "normalized cursor holds the list" `Quick
            test_normalized_cursor_holds_the_list
        ; test_case "recent page keeps skipped-count availability" `Quick
            test_recent_page_skipped_count_is_not_invented
        ; test_case "page failure is distinct from partial failures" `Quick
            test_page_failure_is_distinct_from_partial_failures
        ; test_case "fetch, drawing and keys read one row" `Quick
            test_viewing_record_names_one_row
        ; test_case "an empty page is an error" `Quick
            test_empty_page_is_an_error
        ; test_case "rejects malformed rows" `Quick
            test_malformed_row_is_not_dropped
        ; test_case "binds provider input to exact turn" `Quick
            test_provider_input_is_bound_to_exact_turn
        ; test_case "rejects another keeper or turn" `Quick
            test_provider_input_rejects_another_keeper_or_turn
        ; test_case "opens only digest-verified system prompt" `Quick
            test_input_map_opens_only_digest_verified_system_prompt
        ; test_case "a part is its listed bytes" `Quick
            test_a_part_is_its_listed_bytes
        ; test_case "parts are numbered without a gap" `Quick
            test_parts_must_be_numbered_without_a_gap
        ; test_case "a pane reads the part it shows" `Quick
            test_a_pane_reads_the_part_it_shows
        ; test_case "pinned input survives record failure" `Quick
            test_pinned_input_survives_record_failure
        ; test_case "an unattributed pinned record stays exact" `Quick
            test_pinned_unattributed_record_stays_exact
        ; test_case "late pending snapshots preserve progress" `Quick
            test_late_pending_snapshot_cannot_erase_progress
        ; test_case "exact_bytes preserves distinct sizes and digit order" `Quick
            test_exact_bytes_preserves_distinct_sizes_and_digit_order
        ; test_case "provider usage distinguishes unreported cache from reported zero"
            `Quick
            test_provider_usage_distinguishes_unreported_cache_from_reported_zero
        ] )
    ]
