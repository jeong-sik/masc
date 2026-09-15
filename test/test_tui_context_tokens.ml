(* The context inspector reads in tokens first. The window a request has to
   fit is sized in tokens, and the provider counts tokens; bytes are what
   masc could measure before dispatch. The composition rows therefore carry
   an estimated token figure beside their bytes when the same turn holds
   both a serialized body and a per-request input count, and the serialized
   request band leads with the count. *)

let record ~wire ~scope : Turn_record.t =
  { execution_ids = []
  ; keeper = "alpha"
  ; agent_name = "alpha-agent"
  ; turn_kind = Turn_record.Autonomous
  ; trace_id = "trace-1780648779957-00000"
  ; absolute_turn = 4071
  ; turn_ref =
      Ids.Turn_ref.make ~trace_id:"trace-1780648779957-00000" ~absolute_turn:4071
  ; blocks = []
  ; input_components =
      Some
        [ { component = Turn_record.Tool_schemas; bytes = 8192 }
        ; { component = Turn_record.Message_user; bytes = 256 }
        ]
  ; tool_surface_ref = None
  ; runtime_profile = "ollama_cloud.deepseek-v4-flash"
  ; selected_model = Some "deepseek-v4-flash"
  ; finish_reason = Some "completed"
  ; context_window = Some 131072
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = None
  ; ttfrc_ms = None
  ; request_wire_observation =
      Option.map
        (fun body_bytes ->
          { Turn_record.runtime_profile = "ollama_cloud.deepseek-v4-flash"
          ; body_bytes
          })
        wire
  ; model_input_window = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = None; top_p = None; max_tokens = None; enable_thinking = None }
  ; usage =
      { input_tokens = Some 18_000
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope
      }
  ; ts = 1781200000.5
  }

let selection turn : Masc_tui_context_inspector.selection =
  let components =
    match turn.Turn_record.input_components with
    | Some components -> components
    | None -> []
  in
  { latest = turn
  ; attributed = Some { record = turn; components; turns_behind_latest = 0 }
  ; recent = []
  ; rows = [ turn ]
  }

let lines turn =
  Masc_tui_render_prim.context_composition_lines ~cols:140 ~turn_back:0
    (selection turn)

let contains needle line =
  let n = String.length needle and l = String.length line in
  let rec go i = i + n <= l && (String.sub line i n = needle || go (i + 1)) in
  go 0

let find needle rows =
  List.find_opt (contains needle) rows

let index_of needle rows =
  let rec go i = function
    | [] -> None
    | row :: rest -> if contains needle row then Some i else go (i + 1) rest
  in
  go 0 rows

(* 8,192 schema bytes at 18,000 tokens over 560,513 wire bytes is 263 tokens. *)
let test_rows_carry_an_estimate_when_the_ratio_is_known () =
  let rows = lines (record ~wire:(Some 560_513) ~scope:Runtime_usage_scope.Per_request) in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool) "the row ends in its estimated tokens" true
        (contains "\xe2\x89\x88    263 tok" row);
      Alcotest.(check bool) "the prose names the ratio the estimate used" true
        (Option.is_some (find "31.14 bytes per provider-counted token" rows))

let test_no_estimate_without_a_wire_body () =
  let rows = lines (record ~wire:None ~scope:Runtime_usage_scope.Per_request) in
  Alcotest.(check bool) "no row carries an approximation sign" false
    (List.exists (contains "\xe2\x89\x88") rows);
  Alcotest.(check bool) "the prose says why" true
    (Option.is_some (find "request bytes were not observed, so nothing here" rows))

let test_no_estimate_from_a_cumulative_count () =
  let rows =
    lines
      (record ~wire:(Some 560_513)
         ~scope:Runtime_usage_scope.Conversation_cumulative)
  in
  Alcotest.(check bool) "the rows are still drawn" true
    (Option.is_some (find "Tool schemas" rows));
  Alcotest.(check bool) "the count is named as the conversation's" true
    (Option.is_some (find "tokens counted across the conversation" rows));
  Alcotest.(check bool) "a cumulative count is never divided by one request" false
    (List.exists (contains "\xe2\x89\x88") rows);
  Alcotest.(check bool) "the prose says why" true
    (Option.is_some (find "count across the whole conversation is not divided" rows))

(* The band above prints a count of unknown scope as if it were this
   request's; the rows do not divide by it, and the prose says so rather
   than claiming the count was missing. *)
let test_no_estimate_from_a_count_of_unknown_scope () =
  let rows =
    lines
      (record ~wire:(Some 560_513)
         ~scope:Runtime_usage_scope.Usage_scope_unavailable)
  in
  Alcotest.(check bool) "the rows are still drawn" true
    (Option.is_some (find "Tool schemas" rows));
  Alcotest.(check bool) "no row divides by a count of unknown scope" false
    (List.exists (contains "\xe2\x89\x88") rows);
  Alcotest.(check bool) "the prose names the unknown scope" true
    (Option.is_some (find "did not say whether its input count covers" rows))

let test_no_estimate_beside_zero_attributed_bytes () =
  let turn = record ~wire:(Some 560_513) ~scope:Runtime_usage_scope.Per_request in
  let turn =
    { turn with
      input_components =
        Some [ { component = Turn_record.Tool_schemas; bytes = 0 } ]
    }
  in
  let rows = lines turn in
  Alcotest.(check bool) "a zero-byte row gets no figure to explain" false
    (List.exists (contains "\xe2\x89\x88") rows)

let test_the_request_band_leads_with_tokens () =
  let rows = lines (record ~wire:(Some 560_513) ~scope:Runtime_usage_scope.Per_request) in
  match index_of "18.0k / 131.1k tokens" rows, index_of "prepared request" rows with
  | Some tokens, Some bytes ->
      Alcotest.(check bool) "the token count stands above the byte figure" true
        (tokens < bytes)
  | None, _ -> Alcotest.fail "the per-request token line is drawn"
  | _, None -> Alcotest.fail "the prepared-request byte line is drawn"

let () =
  Alcotest.run "tui_context_tokens"
    [ ( "composition"
      , [ Alcotest.test_case "rows carry an estimate when the ratio is known"
            `Quick test_rows_carry_an_estimate_when_the_ratio_is_known
        ; Alcotest.test_case "no estimate without a wire body" `Quick
            test_no_estimate_without_a_wire_body
        ; Alcotest.test_case "no estimate from a cumulative count" `Quick
            test_no_estimate_from_a_cumulative_count
        ; Alcotest.test_case "no estimate from a count of unknown scope" `Quick
            test_no_estimate_from_a_count_of_unknown_scope
        ; Alcotest.test_case "no estimate beside zero attributed bytes" `Quick
            test_no_estimate_beside_zero_attributed_bytes
        ] )
    ; ( "serialized request"
      , [ Alcotest.test_case "the band leads with tokens" `Quick
            test_the_request_band_leads_with_tokens
        ] )
    ]
