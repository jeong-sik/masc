(* The Overview Providers section, drawn from a [/api/v1/runtime/resolved]
   document shaped like the server's (#38380): one account that reported, one
   that has not reported since the server started, and one whose reset time
   has passed with no newer report. *)

open Alcotest
module Tui_decode = Masc.Tui_decode
module Types = Masc_tui_types
module Providers = Masc_tui_overview_providers

let now = 1790180180.0

(* claude_code: heard 3 minutes ago, 5h resets in 4h12m, 7d in six days.
   kimi: at its full value, reset time ten minutes ago. codex and
   ollama_cloud: nothing heard since the server started. Every display name
   differs from its id, so a row that draws the id instead is caught. *)
let resolved state_word =
  Yojson.Safe.from_string
    (Printf.sprintf
       {|{
  "provider_usage_windows_since": 1790179140.2,
  "provider_usage_windows": [
    { "scope": "provider:codex", "providers": [{"id": "codex", "display_name": "Codex Pro"}],
      "state": "not_reported_since_start", "windows": [] },
    { "scope": "provider:kimi", "providers": [{"id": "kimi", "display_name": "Kimi Coding"}], "state": "reported",
      "windows": [
        { "limit_id": null, "window": {"kind": "duration_minutes", "minutes": 300},
          "role": "gates_model_calls",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790179580, "observed_at": 1790170000.0,
          "source": "codex.account_rate_limits_updated" } ] },
    { "scope": "provider:claude_code", "providers": [{"id": "claude_code", "display_name": "Claude Max"}], "state": %S,
      "windows": [
        { "limit_id": null, "window": {"kind": "five_hour"}, "role": "gates_model_calls",
          "utilization": {"unit": "fraction", "value": 0.67},
          "resets_at": 1790195300, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" },
        { "limit_id": null, "window": {"kind": "seven_day"}, "role": "gates_model_calls",
          "utilization": {"unit": "fraction", "value": 0.44},
          "resets_at": 1790700000, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" } ] },
    { "scope": "provider:ollama_cloud", "providers": [{"id": "ollama_cloud", "display_name": "Ollama Cloud"}],
      "state": "not_reported_since_start", "windows": [] }
  ]
}|}
       state_word)

let runtime ?resets ~scope ~exhausted id : Tui_decode.runtime_option =
  { ro_id = id
  ; ro_provider = "p"
  ; ro_provider_id = "p"
  ; ro_model = id
  ; ro_exact_slot_group = Tui_decode.Exact_http_slots
  ; ro_effective_max_context = 200_000
  ; ro_max_context_source = Tui_decode.Runtime_context_capability
  ; ro_max_output_tokens = None
  ; ro_declared_reasoning_effort = None
  ; ro_is_local = false
  ; ro_is_default = false
  ; ro_quota_exhausted = exhausted
  ; ro_quota_resets_at = resets
  ; ro_quota_scope = Some scope
  }

let contains ~affix text = Astring.String.is_infix ~affix text
let plain = Masc_tui_theme.strip_sgr
let meter_open = "\xe2\x96\x95"
let meter_close = "\xe2\x96\x8f"

(* Every glyph this section draws is one cell wide. *)
let code_points text =
  String.fold_left
    (fun count byte ->
      if Char.code byte land 0xC0 = 0x80 then count else count + 1)
    0 text

let width = 160

(* The meter between the row's opening edge and its last closing edge, and
   its width in cells (one code point per cell). *)
let meter_of row =
  let start =
    match Astring.String.find_sub ~sub:meter_open row with
    | Some i -> i + String.length meter_open
    | None -> failf "no meter in %S" row
  in
  let stop =
    match Astring.String.find_sub ~rev:true ~sub:meter_close row with
    | Some i when i >= start -> i
    | Some _ | None -> failf "no closed meter in %S" row
  in
  let meter = String.sub row start (stop - start) in
  (meter, code_points meter)

let test_section_draws_three_line_shapes () =
  let windows =
    match Tui_decode.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let runtimes =
    Types.Quota_read
      [ runtime ~scope:"provider:kimi" ~exhausted:true
          ~resets:(now +. 7200.0) "kimi.k3"
      ; runtime ~scope:"provider:claude_code" ~exhausted:false "claude_code.sonnet"
      ]
  in
  let section =
    match
      Providers.section ~providers:(Types.Providers_read windows) ~runtimes ~now
        ~width
    with
    | Some section -> section
    | None -> fail "a read draws a section"
  in
  let lines = List.map plain section.lines in
  List.iter
    (fun line ->
      if code_points line > width then
        failf "row is %d cells, wider than %d: %S" (code_points line) width line)
    lines;
  check string "plain usage title" " Plan usage" (plain section.title);
  check int "four accounts behind five rows" 4 section.account_count;
  check (list int) "account row groups" [ 1; 2; 1; 1 ]
    section.account_row_counts;
  let short = Providers.visible_rows section ~rows:4 in
  check int "two complete accounts shown" 2 short.shown_accounts;
  check int "two accounts hidden" 2 short.hidden_accounts;
  check int "three account rows, never half a second window" 3
    (List.length short.lines);
  check bool "the second window remains with its account" true
    (List.exists (contains ~affix:"7d") (List.map plain short.lines));
  let tighter = Providers.visible_rows section ~rows:3 in
  check int "two-row account does not split at a short height" 1
    tighter.shown_accounts;
  check int "only the complete first account row remains" 1
    (List.length tighter.lines);
  match lines with
  | [ kimi; five_hour; seven_day; codex; ollama ] ->
      (* The exhausted account comes first: a budget cut from the bottom
         keeps the reason a Keeper is stuck. *)
      check bool "the exhausted account is the first row" true
        (contains ~affix:"Kimi Coding" kimi);
      (* A reported account: meter, value in its own unit, countdown, age. *)
      check bool "claude 5h row" true
        (contains ~affix:"Claude Max" five_hour
         && (not (contains ~affix:"claude_code" five_hour))
         && contains ~affix:"5h" five_hour
         && contains ~affix:"67%" five_hour
         && contains ~affix:"\xe2\x86\xbb " five_hour
         && contains ~affix:" in 4h12m" five_hour
         && contains ~affix:"heard 3m00s ago" five_hour);
      check bool "claude 7d row: same report, no second age" true
        (contains ~affix:"7d" seven_day
         && contains ~affix:"44%" seven_day
         && (not (contains ~affix:"heard" seven_day))
         && not (contains ~affix:"Claude Max" seven_day));
      let meter, cells = meter_of five_hour in
      check string "the row's meter is the eighth-block meter at 0.67" meter
        (Providers.meter ~cells 0.67);
      (* A passed reset keeps the last value and says so. *)
      check bool "kimi: passed reset, full meter, observed tag" true
        (contains ~affix:"reset time passed \xc2\xb7 no newer report" kimi
         && contains ~affix:"100%" kimi
         && contains ~affix:"5h" kimi
         && contains ~affix:"exhausted (observed)" kimi
         (* The catalogue's reopen time, apart from the provider's reset. *)
         && contains ~affix:"catalogue reopens " kimi
         && contains ~affix:" in 2h00m" kimi);
      (* The box cuts from the right, so the tag sits before the reset text. *)
      check bool "the tag comes before the reset text" true
        (match
           ( Astring.String.find_sub ~sub:"exhausted (observed)" kimi
           , Astring.String.find_sub ~sub:"reset time passed" kimi )
         with
         | Some tag, Some reset -> tag < reset
         | _ -> false);
      let kimi_meter, kimi_cells = meter_of kimi in
      check string "a value at its full value fills the meter" kimi_meter
        (String.concat "" (List.init kimi_cells (fun _ -> "\xe2\x96\x88")));
      (* Not reported is its own line, never an empty meter. *)
      List.iter
        (fun (name, row) ->
          check bool (name ^ " says it has not reported") true
            (contains ~affix:name row
             && contains ~affix:"no usage data" row
             && not (contains ~affix:meter_open row)))
        [ ("Codex Pro", codex); ("Ollama Cloud", ollama) ]
  | _ -> failf "expected five rows, got %d" (List.length lines)

let reported_section ~width =
  let windows =
    match Tui_decode.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let runtimes =
    Types.Quota_read
      [ runtime ~scope:"provider:kimi" ~exhausted:true
          ~resets:(now +. 7200.0) "kimi.k3"
      ]
  in
  match
    Providers.section ~providers:(Types.Providers_read windows) ~runtimes ~now
      ~width
  with
  | Some section -> List.map plain section.lines
  | None -> fail "a read draws a section"

let claude_five_hour lines =
  match List.find_opt (contains ~affix:"Claude Max") lines with
  | Some row -> row
  | None -> fail "no Claude Max row"

(* A wide terminal does not stretch the meter past what the value column can
   tell apart; a narrow one keeps a readable meter and drops the hearing age
   instead (#38611). *)
let test_meter_width_is_bounded () =
  let wide = claude_five_hour (reported_section ~width:220) in
  let _, wide_cells = meter_of wide in
  check int "a wide terminal draws a 24-cell meter" 24 wide_cells;
  check bool "a wide terminal keeps the hearing age" true
    (contains ~affix:"heard 3m00s ago" wide);
  let narrow = claude_five_hour (reported_section ~width:100) in
  let _, narrow_cells = meter_of narrow in
  check int "a narrow terminal keeps a 10-cell meter" 10 narrow_cells;
  check bool "a narrow terminal drops the hearing age first" false
    (contains ~affix:"heard" narrow)

(* Z.AI's TIME_LIMIT counts MCP and tool calls: at 100% it refuses no model
   call, so it is not drawn in the exhausted tone, while the account's token
   window beside it is still drawn as reported. A window with no reset time
   says so with the no-value mark rather than a sentence per row. *)
let test_window_that_gates_nothing_is_not_an_alarm () =
  let json =
    Yojson.Safe.from_string
      {|{
  "provider_usage_windows_since": 1790179140.2,
  "provider_usage_windows": [
    { "scope": "provider:glm", "providers": [{"id": "glm", "display_name": "Z.AI Coding"}],
      "state": "reported",
      "windows": [
        { "limit_id": "TIME_LIMIT",
          "window": {"kind": "provider_label", "label": "1 x unit 5"},
          "role": "counts_other_use",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": null, "observed_at": 1790180000.0,
          "source": "zai.quota_limit" },
        { "limit_id": "TOKENS_LIMIT", "window": {"kind": "five_hour"},
          "role": "gates_model_calls",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790195300, "observed_at": 1790180000.0,
          "source": "zai.quota_limit" } ] }
  ]
}|}
  in
  let windows =
    match Tui_decode.decode_provider_usage_windows json with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let section =
    match
      Providers.section ~providers:(Types.Providers_read windows)
        ~runtimes:Types.Quota_unread ~now ~width
    with
    | Some section -> section
    | None -> fail "a read draws a section"
  in
  let bad = Masc_tui_ansi.Theme.bad () in
  (* An empty tone would be found in every row and prove nothing. *)
  check bool "the exhausted tone is drawn with a code" true (not (String.equal bad ""));
  match section.lines with
  | [ time_limit; tokens_limit ] ->
      check bool "the MCP window reads its own label once" true
        (contains ~affix:"TIME_LIMIT 1 x unit 5" (plain time_limit));
      check bool "a full MCP window is not drawn exhausted" false
        (contains ~affix:bad time_limit);
      check bool "a full token window is drawn exhausted" true
        (contains ~affix:bad tokens_limit);
      check bool "no reset time is the no-value mark" true
        (contains ~affix:Masc_tui_theme.Glyph.no_value (plain time_limit)
         && not (contains ~affix:"not reported" (plain time_limit)))
  | lines -> failf "expected two rows, got %d" (List.length lines)

let test_unknown_role_is_rejected () =
  let json =
    Yojson.Safe.from_string
      {|{
  "provider_usage_windows_since": 1790179140.2,
  "provider_usage_windows": [
    { "scope": "provider:glm", "providers": [{"id": "glm", "display_name": "Z.AI Coding"}],
      "state": "reported",
      "windows": [
        { "limit_id": null, "window": {"kind": "five_hour"}, "role": "advisory",
          "utilization": {"unit": "percent", "value": 1},
          "resets_at": null, "observed_at": 1790180000.0,
          "source": "zai.quota_limit" } ] }
  ]
}|}
  in
  check bool "an unknown role fails the reading" true
    (Result.is_error (Tui_decode.decode_provider_usage_windows json))

let full_cells n = String.concat "" (List.init n (fun _ -> "\xe2\x96\x88"))

let test_meter_uses_eighth_blocks () =
  check string "0.67 of 16 cells is 10 whole cells and five eighths"
    (full_cells 10 ^ "\xe2\x96\x8b" ^ "     ")
    (Providers.meter ~cells:16 0.67);
  check string "zero is empty" "    " (Providers.meter ~cells:4 0.0);
  check string "some use never reads as none" ("\xe2\x96\x8f" ^ "   ")
    (Providers.meter ~cells:4 0.001);
  check string "just under full is not full"
    (full_cells 15 ^ "\xe2\x96\x89")
    (Providers.meter ~cells:16 0.9999);
  check string "exactly full is full" (full_cells 16)
    (Providers.meter ~cells:16 1.0);
  (* Percent 100 and 140 as the section normalizes them for drawing. *)
  check string "percent 100 is full" (full_cells 16)
    (Providers.meter ~cells:16 (float_of_int 100 /. 100.0));
  check string "percent 140 draws full, not wider" (full_cells 16)
    (Providers.meter ~cells:16 (float_of_int 140 /. 100.0));
  check string "zero cells draw nothing" "" (Providers.meter ~cells:0 0.5);
  check string "negative cells draw nothing" "" (Providers.meter ~cells:(-3) 0.5)

let test_values_read_in_one_unit () =
  List.iter
    (fun (label, utilization, expected) ->
      check string label expected (Providers.utilization_text utilization))
    [ ("a fraction reads as a percent", Tui_decode.Utilization_fraction 0.67, "67%")
    ; ("binary noise does not lose a percent", Tui_decode.Utilization_fraction 0.29, "29%")
    ; ("just under full is not full", Tui_decode.Utilization_fraction 0.9999, "99%")
    ; ("a full fraction is 100%", Tui_decode.Utilization_fraction 1.0, "100%")
    ; ("past full is not clamped", Tui_decode.Utilization_fraction 1.4, "140%")
    ; ("a percent reads as reported", Tui_decode.Utilization_percent 100, "100%")
    ; ("a percent past full as reported", Tui_decode.Utilization_percent 140, "140%")
    ]

let test_failed_read_is_one_line () =
  match
    Providers.section ~providers:(Types.Providers_failed "connection refused")
      ~runtimes:Types.Quota_unread ~now ~width:80
  with
  | Some section ->
      check (list string) "one explicit line"
        [ " usage data unavailable: connection refused" ]
        (List.map plain section.lines)
  | None -> fail "a failed read is drawn"

let test_empty_read_names_missing_usage_data () =
  let empty : Tui_decode.provider_usage_windows =
    { puws_since = now; puws_accounts = [] }
  in
  match
    Providers.section ~providers:(Types.Providers_read empty)
      ~runtimes:Types.Quota_unread ~now ~width:80
  with
  | Some section ->
      check int "no account is reported" 0 section.account_count;
      check (list string) "the missing data is visible" [ " no usage data" ]
        (List.map plain section.lines)
  | None -> fail "an empty account list disappeared"

let test_unknown_state_is_rejected () =
  check bool "an unknown state fails the reading" true
    (Result.is_error
       (Tui_decode.decode_provider_usage_windows (resolved "paused")))

let () =
  run "tui_overview_providers"
    [ ( "providers"
      , [ test_case "three line shapes" `Quick test_section_draws_three_line_shapes
        ; test_case "eighth-block meter" `Quick test_meter_uses_eighth_blocks
        ; test_case "values read in one unit" `Quick test_values_read_in_one_unit
        ; test_case "failed read is one line" `Quick test_failed_read_is_one_line
        ; test_case "empty read names missing usage" `Quick
            test_empty_read_names_missing_usage_data
        ; test_case "unknown state is rejected" `Quick test_unknown_state_is_rejected
        ; test_case "meter width is bounded" `Quick test_meter_width_is_bounded
        ; test_case "a window that gates nothing is not an alarm" `Quick
            test_window_that_gates_nothing_is_not_an_alarm
        ; test_case "unknown role is rejected" `Quick test_unknown_role_is_rejected
        ] )
    ]
