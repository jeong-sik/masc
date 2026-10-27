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

let test_every_kind_names_one_producer () =
  let label = Inspector.input_source_label in
  Alcotest.(check string)
    "the system prompt is assembled" "turn prompt assembly"
    (label (Inspector.exact_input_source Inspector.System_prompt));
  Alcotest.(check string)
    "a schema comes from the tool surface" "effective tool surface"
    (label
       (Inspector.exact_input_source
          (Inspector.Tool_schema { name = "masc_check" })));
  Alcotest.(check string)
    "a message comes from the provider list" "provider message list"
    (label (Inspector.exact_input_source (Inspector.Message { role = "tool" })));
  Alcotest.(check string)
    "a prompt block is assembled" "turn prompt assembly"
    (label
       (Inspector.input_source
          (Turn_record.Prompt_block Prompt_block_id.Memory_os_recall)));
  Alcotest.(check string)
    "tool schemas are the tool surface" "effective tool surface"
    (label (Inspector.input_source Turn_record.Tool_schemas));
  Alcotest.(check string)
    "tool results ride the message list" "provider message list"
    (label (Inspector.input_source Turn_record.Message_tool_result));
  Alcotest.(check (list string))
    "the flow order, each producer once"
    [ "turn prompt assembly"; "effective tool surface"; "provider message list" ]
    (List.map label Inspector.input_sources)

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

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "an unattributed page still reads" `Quick
            test_page_without_attribution_still_reads
        ; test_case "recent turns carry the provider counts" `Quick
            test_recent_turns_carry_the_provider_counts
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
        ; Alcotest.test_case "every kind names one producer" `Quick
            test_every_kind_names_one_producer
        ] )
    ]
