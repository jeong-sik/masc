(* The context inspector reads every size in tokens. The window a request
   has to fit is sized in tokens and the provider counts tokens; bytes are
   what masc could measure before dispatch. So each composition row carries
   an estimated token figure, the serialized request band leads with the
   provider's own count, and the bytes stand once under the rows beside the
   sentence that names where the ratio came from: this turn's own wire body
   over its per-request count, else the median of the page, else the fleet
   figure. *)

let record ?(tokens = Some 18_000) ~wire ~scope () : Turn_record.t =
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
      { input_tokens = tokens
      ; output_tokens = Some 412
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = None
      ; scope
      }
  ; ts = 1781200000.5
  }

let selection ?rows turn : Masc_tui_context_inspector.selection =
  let components =
    match turn.Turn_record.input_components with
    | Some components -> components
    | None -> []
  in
  { latest = turn
  ; attributed = Some { record = turn; components; turns_behind_latest = 0 }
  ; recent = []
  ; rows = (match rows with Some rows -> rows | None -> [ turn ])
  }

let lines ?rows turn =
  Masc_tui_render_prim.context_composition_lines ~cols:140 ~turn_back:0
    (selection ?rows turn)

let contains needle line =
  let n = String.length needle and l = String.length line in
  let rec go i = i + n <= l && (String.sub line i n = needle || go (i + 1)) in
  go 0

let find needle rows = List.find_opt (contains needle) rows

let index_of needle rows =
  let rec go i = function
    | [] -> None
    | row :: rest -> if contains needle row then Some i else go (i + 1) rest
  in
  go 0 rows

let approx = "\xe2\x89\x88"

let per_request = Runtime_usage_scope.Per_request

(* 8,192 schema bytes at 18,000 tokens over 560,513 wire bytes is 263 tokens. *)
let test_rows_read_at_this_turns_ratio () =
  let rows = lines (record ~wire:(Some 560_513) ~scope:per_request ()) in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool) "the row carries its estimated tokens" true
        (contains (approx ^ "   263 tok") row);
      Alcotest.(check bool) "and no byte figure" false
        (contains "KB" row || contains " B" row);
      Alcotest.(check bool) "the note names this turn's ratio" true
        (Option.is_some (find "31.14 bytes per provider-counted token" rows));
      Alcotest.(check bool) "the bytes stand once under the rows" true
        (Option.is_some (find "KB) attributed here against" rows))

(* Two older rows on the page carried a body beside a count, at 3.0 and 4.0
   bytes per token; the median of their token-per-byte ratios is one token
   per 3.43 bytes, so 8,192 bytes read as 2,389 tokens. *)
let test_rows_read_at_the_page_median_when_this_turn_has_no_body () =
  let latest = record ~wire:None ~scope:per_request () in
  let older ~wire =
    { (record ~tokens:(Some 100_000) ~wire:(Some wire) ~scope:per_request ()) with
      absolute_turn = 4070
    }
  in
  let rows = lines ~rows:[ latest; older ~wire:300_000; older ~wire:400_000 ] latest in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool) "the row reads at the page median" true
        (contains (approx ^ "  2.4k tok") row);
      Alcotest.(check bool) "the note names the median and its sample count" true
        (Option.is_some
           (find "3.43 bytes per provider-counted token, the median of 2 turns" rows))

(* Nothing on the page carried both: 8,192 bytes at the fleet's 3.39 bytes
   per token is 2,417 tokens. *)
let test_rows_read_at_the_fleet_figure_when_the_page_has_no_body () =
  let rows = lines (record ~wire:None ~scope:per_request ()) in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool) "the row reads at the fleet figure" true
        (contains (approx ^ "  2.4k tok") row);
      Alcotest.(check bool) "the note names the fleet measurement" true
        (Option.is_some (find "fleet median measured 2026-09-13..15" rows));
      Alcotest.(check bool) "and says there was no serialized figure" true
        (Option.is_some (find "request bytes were not observed" rows))

(* A conversation-cumulative count is a number about the whole conversation;
   it never divides this request's bytes, even with a body beside it. *)
let test_a_cumulative_count_never_becomes_the_ratio () =
  let rows =
    lines
      (record ~wire:(Some 560_513)
         ~scope:Runtime_usage_scope.Conversation_cumulative ())
  in
  Alcotest.(check bool) "the rows are still drawn, in tokens" true
    (Option.is_some (find (approx ^ "  2.4k tok") rows));
  Alcotest.(check bool) "the count is named as the conversation's" true
    (Option.is_some (find "tokens counted across the conversation" rows));
  Alcotest.(check bool) "the ratio fell through to the fleet figure" true
    (Option.is_some (find "fleet median measured 2026-09-13..15" rows))

let test_a_count_of_unknown_scope_never_becomes_the_ratio () =
  let rows =
    lines
      (record ~wire:(Some 560_513)
         ~scope:Runtime_usage_scope.Usage_scope_unavailable ())
  in
  Alcotest.(check bool) "the ratio fell through to the fleet figure" true
    (Option.is_some (find "fleet median measured 2026-09-13..15" rows))

let test_the_request_band_leads_with_the_providers_count () =
  let rows = lines (record ~wire:(Some 560_513) ~scope:per_request ()) in
  match index_of "18.0k / 131.1k tokens" rows, index_of "prepared request" rows with
  | Some tokens, Some bytes ->
      Alcotest.(check bool) "the count stands above the estimate" true
        (tokens < bytes);
      Alcotest.(check bool) "the estimate names the bytes it was read from" true
        (contains (approx ^ "18.0k tok prepared request (547.4 KB)")
           (List.nth rows bytes))
  | None, _ -> Alcotest.fail "the per-request token line is drawn"
  | _, None -> Alcotest.fail "the prepared-request line is drawn"

(* This turn's own ratio wins over a page whose other rows disagree. *)
let test_this_turn_outranks_the_page () =
  let turn = record ~wire:(Some 560_513) ~scope:per_request () in
  let other = record ~tokens:(Some 100_000) ~wire:(Some 300_000) ~scope:per_request () in
  match Masc_tui_token_scale.of_turn ~rows:[ turn; other ] turn with
  | { Masc_tui_token_scale.basis = This_turn { wire_bytes = 560_513; tokens = 18_000 }; _ } -> ()
  | { basis = This_turn _ | Keeper_page _ | Fleet_measured; _ } ->
      Alcotest.fail "the record's own body and count set the scale"

let () =
  Alcotest.run "tui_context_tokens"
    [ ( "composition"
      , [ Alcotest.test_case "rows read at this turn's ratio" `Quick
            test_rows_read_at_this_turns_ratio
        ; Alcotest.test_case "rows read at the page median when this turn has no body"
            `Quick test_rows_read_at_the_page_median_when_this_turn_has_no_body
        ; Alcotest.test_case "rows read at the fleet figure when the page has no body"
            `Quick test_rows_read_at_the_fleet_figure_when_the_page_has_no_body
        ; Alcotest.test_case "a cumulative count never becomes the ratio" `Quick
            test_a_cumulative_count_never_becomes_the_ratio
        ; Alcotest.test_case "a count of unknown scope never becomes the ratio"
            `Quick test_a_count_of_unknown_scope_never_becomes_the_ratio
        ] )
    ; ( "serialized request"
      , [ Alcotest.test_case "the band leads with the provider's count" `Quick
            test_the_request_band_leads_with_the_providers_count
        ] )
    ; ( "token scale"
      , [ Alcotest.test_case "this turn outranks the page" `Quick
            test_this_turn_outranks_the_page
        ] )
    ]
