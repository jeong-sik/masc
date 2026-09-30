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
    { "scope": "provider:codex", "scope_id": "id-codex", "providers": [{"id": "codex", "display_name": "Codex Pro"}],
      "state": "not_reported_since_start", "windows": [] },
    { "scope": "provider:kimi", "scope_id": "id-kimi", "providers": [{"id": "kimi", "display_name": "Kimi Coding"}], "state": "reported",
      "windows": [
        { "limit_id": null, "window": {"kind": "duration_minutes", "minutes": 300},
          "role": "gates_model_calls",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790179580, "observed_at": 1790170000.0,
          "source": "codex.account_rate_limits_updated" } ] },
    { "scope": "provider:claude_code", "scope_id": "id-claude_code", "providers": [{"id": "claude_code", "display_name": "Claude Max"}], "state": %S,
      "windows": [
        { "limit_id": null, "window": {"kind": "five_hour"}, "role": "gates_model_calls",
          "utilization": {"unit": "fraction", "value": 0.67},
          "resets_at": 1790195300, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" },
        { "limit_id": null, "window": {"kind": "seven_day"}, "role": "gates_model_calls",
          "utilization": {"unit": "fraction", "value": 0.44},
          "resets_at": 1790700000, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" } ] },
    { "scope": "provider:ollama_cloud", "scope_id": "id-ollama_cloud", "providers": [{"id": "ollama_cloud", "display_name": "Ollama Cloud"}],
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
  ; ro_rate_limited = false
  ; ro_rate_limit_resets_at = None
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
    match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
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
      Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows) ~runtimes ~now
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
  (* Codex Pro and Ollama Cloud have not reported and are not observed
     exhausted, so they draw nothing: two accounts, three rows. *)
  match lines with
  | [ kimi; five_hour; seven_day ] ->
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
      check bool "no row names an account that has not reported" true
        (not
           (List.exists
              (fun line -> contains ~affix:"Codex Pro" line || contains ~affix:"Ollama Cloud" line)
              lines))
  | _ -> failf "expected three rows, got %d" (List.length lines)

(* The one silent account kept: its quota is observed exhausted, and that tag
   is the reason a Keeper on it is stuck. It draws no meter. *)
let test_silent_account_draws_only_its_exhaustion () =
  let windows =
    match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let runtimes =
    Types.Quota_read [ runtime ~scope:"provider:codex" ~exhausted:true "codex.gpt" ]
  in
  match
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows) ~runtimes ~now ~width
  with
  | None -> fail "a read draws a section"
  | Some section ->
      let lines = List.map plain section.lines in
      (match List.filter (contains ~affix:"Codex Pro") lines with
       | [ codex ] ->
           check bool "the exhausted silent account says so, without a meter" true
             (contains ~affix:"no usage data" codex
              && contains ~affix:"exhausted (observed)" codex
              && not (contains ~affix:meter_open codex))
       | rows -> failf "expected one Codex Pro row, got %d" (List.length rows));
      check bool "the silent account that is not exhausted draws nothing" true
        (not (List.exists (contains ~affix:"Ollama Cloud") lines))

let reported_section ~width =
  let windows =
    match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
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
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows) ~runtimes ~now
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
    (contains ~affix:"heard" narrow);
  (* The box cuts a row from the right; the value must sit inside the cut. *)
  let value_end =
    match Astring.String.find_sub ~sub:"67%" narrow with
    | Some i -> code_points (String.sub narrow 0 i) + String.length "67%"
    | None -> fail "no value in the narrow row"
  in
  check bool "the value is inside a narrow row" true (value_end <= 100)

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
    { "scope": "provider:glm", "scope_id": "id-glm", "providers": [{"id": "glm", "display_name": "Z.AI Coding"}],
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
    match Masc.Tui_decode_usage.decode_provider_usage_windows json with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let section =
    match
      Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows)
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
      check bool "a full MCP window is drawn dim" true
        (contains ~affix:(Masc_tui_ansi.Ansi.dim ^ meter_open) time_limit);
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
    { "scope": "provider:glm", "scope_id": "id-glm", "providers": [{"id": "glm", "display_name": "Z.AI Coding"}],
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
    (Result.is_error (Masc.Tui_decode_usage.decode_provider_usage_windows json))

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
    [ ("a fraction reads as a percent", Masc.Tui_decode_usage.Utilization_fraction 0.67, "67%")
    ; ("binary noise does not lose a percent", Masc.Tui_decode_usage.Utilization_fraction 0.29, "29%")
    ; ("just under full is not full", Masc.Tui_decode_usage.Utilization_fraction 0.9999, "99%")
    ; ("a full fraction is 100%", Masc.Tui_decode_usage.Utilization_fraction 1.0, "100%")
    ; ("past full is not clamped", Masc.Tui_decode_usage.Utilization_fraction 1.4, "140%")
    ; ("a percent reads as reported", Masc.Tui_decode_usage.Utilization_percent 100, "100%")
    ; ("a percent past full as reported", Masc.Tui_decode_usage.Utilization_percent 140, "140%")
    ]

let test_failed_read_is_one_line () =
  match
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_failed "connection refused")
      ~runtimes:Types.Quota_unread ~now ~width:80
  with
  | Some section ->
      check (list string) "one explicit line"
        [ " usage data unavailable: connection refused" ]
        (List.map plain section.lines)
  | None -> fail "a failed read is drawn"

let test_empty_read_names_missing_usage_data () =
  let empty : Masc.Tui_decode_usage.provider_usage_windows =
    { puws_since = now; puws_accounts = [] }
  in
  match
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read empty)
      ~runtimes:Types.Quota_unread ~now ~width:80
  with
  | Some section ->
      check (list string) "the missing data is visible" [ " no usage data" ]
        (List.map plain section.lines)
  | None -> fail "an empty account list disappeared"

(* An account's email sits under its name and scope id. An email that fits goes
   on the account's second window row, a wider one or the email of a
   one-window account takes a row of its own, so the meters never narrow. An
   account that draws no row draws no email either. *)
let test_account_emails_name_their_accounts () =
  let windows =
    match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let section account_emails =
    match
      Providers.section ~providers:(Types.Providers_read windows)
        ~runtimes:Types.Quota_unread ~account_emails ~now ~width
    with
    | Some section -> section
    | None -> fail "a read draws a section"
  in
  let read ?(unreadable_rows = 0) emails =
    section (Types.Account_emails_read { emails; unreadable_rows })
  in
  let starts row prefix = String.starts_with ~prefix (plain row) in
  let without = section Types.Account_emails_unread in
  let fitting =
    read [ ("claude_code", "c@x.io"); ("kimi", "kimi@example.com"); ("codex", "codex@example.com") ]
  in
  (match fitting.lines with
   | [ claude_5h; claude_7d; kimi; kimi_email ] ->
       check bool "the name and scope stay on the first row" true
         (starts claude_5h " Claude Max · id-claud  5h");
       check bool "an email that fits goes under the name, on the next window row" true
         (starts claude_7d " c@x.io " && contains ~affix:"7d" claude_7d
          && contains ~affix:meter_open claude_7d);
       check bool "drawn dim" true (contains ~affix:(Masc_tui_ansi.Ansi.dim ^ "c@x.io") claude_7d);
       check bool "a one-window account names it on a row of its own" true
         (starts kimi " Kimi Coding · id-kimi  "
          && String.equal (String.trim (plain kimi_email)) "kimi@example.com");
       check bool "the email row has no meter" false (contains ~affix:meter_open kimi_email)
   | lines -> failf "expected four rows, got %d" (List.length lines));
  check bool "an account that draws no row draws no email" false
    (List.exists (contains ~affix:"codex@example.com") fitting.lines);
  let wide_email = "claude.with.long.address@example.com" in
  let wide = read [ ("claude_code", wide_email) ] in
  (match wide.lines, without.lines with
   | [ claude_5h; claude_7d; claude_email; kimi ], [ bare_5h; bare_7d; bare_kimi ] ->
       check (list string) "a wider email leaves every window row as it was"
         [ plain bare_5h; plain bare_7d; plain bare_kimi ]
         [ plain claude_5h; plain claude_7d; plain kimi ];
       check string "and takes a row of its own under the account" wide_email
         (String.trim (plain claude_email))
   | lines, bare -> failf "expected four and three rows, got %d and %d" (List.length lines) (List.length bare));
  check (list string) "a failed read is said once, after the rows"
    (List.map plain without.lines @ [ " account emails unread: HTTP 403" ])
    (List.map plain (section (Types.Account_emails_failed "HTTP 403")).lines);
  check bool "and no row names an email" false
    (List.exists (contains ~affix:"@") (section (Types.Account_emails_failed "HTTP 403")).lines);
  check (list string) "rows this build cannot read are counted"
    (List.map plain without.lines @ [ " account emails: 2 rows this build cannot read" ])
    (List.map plain (read ~unreadable_rows:2 []).lines)

let test_unknown_state_is_rejected () =
  check bool "an unknown state fails the reading" true
    (Result.is_error
       (Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "paused")))

let test_history_preserves_reported_days_and_units () =
  let json = Yojson.Safe.from_string
    {|{"days":14,"generated_at":1780000000.0,"sampling":"latest_provider_report_per_utc_day","unreadable_reports":0,"points":[{"scope_id":"abc12345","kind":"five_hour","limit_id":null,"unit":"fraction","value":0.4,"observed_at":1779999900.0,"source":"codex.account_rate_limits_read","resets_at":null}]}|}
  in
  match Masc.Tui_decode_usage.decode_provider_usage_history json with
  | Error detail -> fail detail
  | Ok history ->
      check int "declared UTC days" 14 history.puh_days;
      (match history.puh_points with
       | [point] ->
           check string "opaque scope" "abc12345" point.puhp_scope_id;
           (match point.puhp_unit with
            | Masc.Tui_decode_usage.Utilization_fraction value ->
                check (float 0.0001) "reported fraction" 0.4 value
            | Masc.Tui_decode_usage.Utilization_percent _ -> fail "unit changed")
       | _ -> fail "expected one reported point")

(* The trend is built once from the answer. A day without a report is the
   no-report mark, never the lowest bar; a scope whose only point is outside
   the window keeps its row and says it reported no day. *)
let test_trend_is_built_from_the_answer () =
  let point ~scope_id ~observed_at unit : Masc.Tui_decode_usage.provider_usage_history_point =
    { puhp_scope_id = scope_id; puhp_kind = "five_hour"; puhp_limit_id = None;
      puhp_unit = unit; puhp_observed_at = observed_at }
  in
  let generated_at = 1780000000.0 in
  let day = 86400.0 in
  let history : Masc.Tui_decode_usage.provider_usage_history =
    { puh_days = 3; puh_generated_at = generated_at; puh_unreadable_reports = 1;
      puh_points =
        [ point ~scope_id:"s1" ~observed_at:(generated_at -. (2.0 *. day))
            (Masc.Tui_decode_usage.Utilization_fraction 0.0)
        ; point ~scope_id:"s1" ~observed_at:generated_at
            (Masc.Tui_decode_usage.Utilization_percent 100)
        ; point ~scope_id:"s0" ~observed_at:(generated_at -. (30.0 *. day))
            (Masc.Tui_decode_usage.Utilization_fraction 0.5)
        ] }
  in
  let trend =
    Masc_tui_usage_trend.of_history ~share:Providers.share_of_full history
  in
  check int "the unreadable count is carried" 1 trend.unreadable_reports;
  let none = Masc_tui_usage_trend.no_report_mark in
  check (list (triple string string int)) "rows, marks and reported days"
    [ ("s0", none ^ none ^ none, 0)
    ; ("s1", "\xe2\x96\x81" ^ none ^ "\xe2\x96\x88", 2)
    ]
    (List.map
       (fun (row : Masc_tui_usage_trend.row) ->
         (row.scope_id, row.marks, row.reported_days))
       trend.rows)

(* The id the section names a scope by is the server's, carried on the row,
   so the trend's points and the current windows cannot disagree. *)
let test_scope_id_is_the_servers () =
  match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
  | Error err -> failf "fixture should decode: %s" err
  | Ok windows ->
      check (list string) "ids as the server sent them"
        [ "id-codex"; "id-kimi"; "id-claude_code"; "id-ollama_cloud" ]
        (List.map Providers.scope_id windows.puws_accounts)

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
        ; test_case "history uses reported points" `Quick
            test_history_preserves_reported_days_and_units
        ; test_case "trend is built from the answer" `Quick
            test_trend_is_built_from_the_answer
        ; test_case "scope id is the server's" `Quick test_scope_id_is_the_servers
        ; test_case "a silent account draws only its exhaustion" `Quick
            test_silent_account_draws_only_its_exhaustion
        ; test_case "meter width is bounded" `Quick test_meter_width_is_bounded
        ; test_case "a window that gates nothing is not an alarm" `Quick
            test_window_that_gates_nothing_is_not_an_alarm
        ; test_case "unknown role is rejected" `Quick test_unknown_role_is_rejected
        ; test_case "account emails name their accounts" `Quick
            test_account_emails_name_their_accounts
        ] )
    ]
