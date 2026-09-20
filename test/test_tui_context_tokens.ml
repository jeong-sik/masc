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

let lines ?rows ?(forecast = Error "next-request not fetched") turn =
  Masc_tui_render_prim.context_composition_lines ~cols:140 ~turn_back:0 ~forecast
    (selection ?rows turn)

let contains needle line =
  let n = String.length needle and l = String.length line in
  let rec go i = i + n <= l && (String.sub line i n = needle || go (i + 1)) in
  go 0

let find needle rows = List.find_opt (contains needle) rows

(* Prose is folded to the pane, so a sentence can straddle two rows. Strip
   the styling and the indent, join the rows, and search the sentence. *)
let strip line =
  let buffer = Buffer.create (String.length line) in
  let rec go i =
    if i >= String.length line then ()
    else if line.[i] = '\027' then
      match String.index_from_opt line i 'm' with
      | Some stop -> go (stop + 1)
      | None -> ()
    else (
      Buffer.add_char buffer line.[i];
      go (i + 1))
  in
  go 0;
  String.trim (Buffer.contents buffer)

let text rows = String.concat " " (List.map strip rows)

let says needle rows = contains needle (text rows)

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
        (says "31.14 bytes per provider-counted token" rows);
      Alcotest.(check bool) "the bytes stand once under the rows" true
        (says "tok attributed here, " rows)

(* Two older rows on the page carried a body beside a count, at 2.0 and 2.5
   bytes per token; the median of their token-per-byte ratios is one token
   per 2.22 bytes, so 8,192 bytes read as 3,686 tokens -- a figure the fleet
   ratio (2,417) cannot produce, so the row itself proves the page was read. *)
let test_rows_read_at_the_page_median_when_this_turn_has_no_body () =
  let latest = record ~wire:None ~scope:per_request () in
  let older ~wire =
    { (record ~tokens:(Some 100_000) ~wire:(Some wire) ~scope:per_request ()) with
      absolute_turn = 4070
    }
  in
  let rows = lines ~rows:[ latest; older ~wire:200_000; older ~wire:250_000 ] latest in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool) "the row reads at the page median" true
        (contains (approx ^ "  3.7k tok") row);
      Alcotest.(check bool) "the note names the median, its sample count and why" true
        (says "2.22 bytes per provider-counted token, the median of 2 turns on this page that carried a wire body beside a per-request count; this turn carried no serialized body" rows)

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
        (says "fleet median measured 2026-09-13..15" rows);
      Alcotest.(check bool) "and says there was no serialized figure" true
        (says "No body was serialized on this lane" rows)

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
    (says "tokens counted across the conversation" rows);
  Alcotest.(check bool) "the ratio fell through to the fleet figure" true
    (says "fleet median measured 2026-09-13..15" rows)

let test_a_count_of_unknown_scope_never_becomes_the_ratio () =
  let rows =
    lines
      (record ~wire:(Some 560_513)
         ~scope:Runtime_usage_scope.Usage_scope_unavailable ())
  in
  Alcotest.(check bool) "the ratio fell through to the fleet figure" true
    (says "fleet median measured 2026-09-13..15" rows);
  Alcotest.(check bool) "unknown scope is not context occupancy" false
    (says "of the window" rows)

let test_a_turn_total_never_becomes_context_occupancy () =
  let rows =
    lines (record ~wire:(Some 560_513) ~scope:Runtime_usage_scope.Turn_total ())
  in
  Alcotest.(check bool) "raw total stays visible" true
    (says "18.0k tokens counted across the client turn" rows);
  Alcotest.(check bool) "total is not context occupancy" false
    (says "of the window" rows);
  Alcotest.(check bool) "total does not divide request bytes" true
    (says "this count is the client turn's total over requests, so it is not divided" rows)

let test_the_request_band_leads_with_the_providers_count () =
  let rows = lines (record ~wire:(Some 560_513) ~scope:per_request ()) in
  match index_of "18.0k / 131.1k tokens" rows, index_of "in the body masc sent" rows with
  | Some tokens, Some bytes ->
      Alcotest.(check bool) "the count stands above the estimate" true
        (tokens < bytes);
      Alcotest.(check bool) "the estimate names the bytes it was read from" true
        (contains (approx ^ "18.0k tok in the body masc sent")
           (List.nth rows bytes))
  | None, _ -> Alcotest.fail "the per-request token line is drawn"
  | _, None -> Alcotest.fail "the body-as-sent line is drawn"

(* This turn's own ratio wins over a page whose other rows disagree. *)
let test_this_turn_outranks_the_page () =
  let turn = record ~wire:(Some 560_513) ~scope:per_request () in
  let other = record ~tokens:(Some 100_000) ~wire:(Some 300_000) ~scope:per_request () in
  match Masc_tui_token_scale.of_turn ~rows:[ turn; other ] turn with
  | { Masc_tui_token_scale.basis = This_turn { wire_bytes = 560_513; tokens = 18_000 }; _ } -> ()
  | { basis = This_turn _ | Keeper_page _ | Fleet_measured _; _ } ->
      Alcotest.fail "the record's own body and count set the scale"

(* A count above the window is not one request's input; the band says so
   instead of drawing 2823% of a window. *)
let test_a_count_above_the_window_is_not_drawn_as_occupancy () =
  let rows =
    lines (record ~tokens:(Some 3_700_000) ~wire:(Some 560_513) ~scope:per_request ())
  in
  Alcotest.(check bool) "the band names the overflow" true
    (says "3.70M tokens counted this turn, more than the 131.1k-token window" rows);
  Alcotest.(check bool) "and draws no occupancy" false
    (says "of the window" rows)

(* No serialized body is the ordinary case on a lane whose client assembles
   the request. The band says what masc handed over rather than reporting a
   failed observation. *)
let test_no_body_names_what_masc_handed_over () =
  let rows = lines (record ~wire:None ~scope:per_request ()) in
  Alcotest.(check bool) "the band names the client" true
    (says "the runtime client assembled the request itself; masc handed it the" rows);
  (* The history band below reports its own unobserved window on this
     fixture, which is a different reading. The claim under test is about the
     request band, so read only the rows above that band. *)
  let request_band =
    match index_of "HOW FAR BACK" rows with
    | Some stop -> List.filteri (fun index _ -> index < stop) rows
    | None -> rows
  in
  Alcotest.(check bool) "and never calls it unobserved" false
    (says "not observed" request_band)

let with_window measurement turn =
  { turn with
    Turn_record.model_input_window =
      Some
        { transmitted_atoms = 26
        ; total_atoms = 9137
        ; measurement
        ; front_atom_digest = String.make 64 'd'
        }
  }

let test_a_wire_shape_cut_is_labelled_sent () =
  let rows =
    lines (with_window Turn_record.Wire_shape (record ~wire:(Some 560_513) ~scope:per_request ()))
  in
  Alcotest.(check bool) "the pointer says sent" true
    (Option.is_some (find "sent this turn" rows));
  Alcotest.(check bool) "9111 atoms stayed behind" true
    (says "9111 older atoms stayed behind" rows)

let test_a_durable_shape_cut_is_not_labelled_sent () =
  let rows =
    lines (with_window Turn_record.Durable_shape (record ~wire:None ~scope:per_request ()))
  in
  Alcotest.(check bool) "the pointer says in reach" true
    (Option.is_some (find "in reach this turn" rows));
  Alcotest.(check bool) "and never sent" false
    (Option.is_some (find "sent this turn" rows));
  Alcotest.(check bool) "the prose names the resumed client session" true
    (says "resumed client session already holds the earlier ones" rows)

(* A record that carried a body but a conversation-cumulative count: the
   page supplies the ratio and the note says why this turn could not. *)
let test_the_page_note_says_why_this_turn_was_refused () =
  let latest =
    record ~wire:(Some 560_513) ~scope:Runtime_usage_scope.Conversation_cumulative ()
  in
  let older =
    { (record ~tokens:(Some 100_000) ~wire:(Some 200_000) ~scope:per_request ()) with
      absolute_turn = 4070
    }
  in
  let rows = lines ~rows:[ latest; older ] latest in
  Alcotest.(check bool) "one sample is one turn" true
    (says "the median of 1 turn on this page" rows);
  Alcotest.(check bool) "the refusal is the cumulative count, not a missing body" true
    (says "this turn's count covers the whole conversation" rows);
  Alcotest.(check bool) "and the note never claims the body was missing" false
    (says "carried no serialized body" rows)

(* The composition shown is not always the latest turn: when the keeper kept
   turning after its last attributed row, [attributed] is older than
   [latest]. Its bytes must then be read at the attributed turn's own ratio,
   not the latest turn's. Here the attributed turn carried 100,000 tokens
   over 200,000 wire bytes (2.00 bytes per token) while the latest carried
   18,000 over 560,513 (31.14): 8,192 schema bytes read at the attributed
   ratio is 4,096 tokens, at the latest ratio 263. *)
let test_attributed_rows_read_at_the_attributed_turns_ratio () =
  let latest = record ~wire:(Some 560_513) ~scope:per_request () in
  let older =
    { (record ~tokens:(Some 100_000) ~wire:(Some 200_000) ~scope:per_request ()) with
      absolute_turn = 4070
    }
  in
  let components =
    match older.Turn_record.input_components with
    | Some components -> components
    | None -> []
  in
  let selection : Masc_tui_context_inspector.selection =
    { latest
    ; attributed =
        Some { record = older; components; turns_behind_latest = 1 }
    ; recent = []
    ; rows = [ latest; older ]
    }
  in
  let rows =
    Masc_tui_render_prim.context_composition_lines ~cols:140 ~turn_back:0
      ~forecast:(Error "next-request not fetched") selection
  in
  match find "Tool schemas" rows with
  | None -> Alcotest.fail "the tool schemas row is drawn"
  | Some row ->
      Alcotest.(check bool)
        "the attributed row reads at the attributed turn's ratio" true
        (contains (approx ^ "  4.1k tok") row);
      Alcotest.(check bool) "and not at the latest turn's ratio" false
        (contains (approx ^ "   263 tok") row);
      Alcotest.(check bool) "the note names the attributed turn's ratio" true
        (says "2.00 bytes per provider-counted token" rows);
      Alcotest.(check bool) "the gap names the older turn" true
        (says "Measured on turn #4070, 1 turns before" rows)

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
        ; Alcotest.test_case "a client turn total is not context occupancy" `Quick
            test_a_turn_total_never_becomes_context_occupancy
        ; Alcotest.test_case "a count of unknown scope never becomes the ratio"
            `Quick test_a_count_of_unknown_scope_never_becomes_the_ratio
        ; Alcotest.test_case "the page note says why this turn was refused"
            `Quick test_the_page_note_says_why_this_turn_was_refused
        ; Alcotest.test_case
            "attributed rows read at the attributed turn's ratio" `Quick
            test_attributed_rows_read_at_the_attributed_turns_ratio
        ] )
    ; ( "serialized request"
      , [ Alcotest.test_case "the band leads with the provider's count" `Quick
            test_the_request_band_leads_with_the_providers_count
        ; Alcotest.test_case "a count above the window is not drawn as occupancy"
            `Quick test_a_count_above_the_window_is_not_drawn_as_occupancy
        ; Alcotest.test_case "no body names what masc handed over" `Quick
            test_no_body_names_what_masc_handed_over
        ] )
    ; ( "history reach"
      , [ Alcotest.test_case "a wire shape cut is labelled sent" `Quick
            test_a_wire_shape_cut_is_labelled_sent
        ; Alcotest.test_case "a durable shape cut is not labelled sent" `Quick
            test_a_durable_shape_cut_is_not_labelled_sent
        ] )
    ; ( "token scale"
      , [ Alcotest.test_case "this turn outranks the page" `Quick
            test_this_turn_outranks_the_page
        ] )
    ]
