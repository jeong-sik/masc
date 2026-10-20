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
let resolved ?(kimi_observed_at = 1790170000.0) ?(kimi_resets_at = 1790179580.0)
    state_word =
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
          "resets_at": %.1f, "observed_at": %.1f,
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
       kimi_resets_at kimi_observed_at state_word)

let runtime ?resets ~scope ~exhausted id : Tui_decode.runtime_option =
  { ro_id = id
  ; ro_provider = "p"
  ; ro_provider_id = "p"
  ; ro_model = id
  ; ro_exact_slot_group = Tui_decode.Exact_http_slots
  ; ro_exact_body_deadline_missing = false
  ; ro_effective_max_context = 200_000
  ; ro_max_context_source = Tui_decode.Runtime_context_capability
  ; ro_max_output_tokens = None
  ; ro_declared_reasoning_effort = None
  ; ro_is_local = false
  ; ro_is_default = false
  ; ro_quota_exhausted = exhausted
  ; ro_quota_resets_at = resets
  ; ro_quota_scope_id = None
  ; ro_quota_scope = Some scope
  ; ro_rate_limited = false
  ; ro_rate_limit_resets_at = None
  ; ro_failed_attempt = None
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

let width = 100

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

let plan_section_t =
  testable
    (fun formatter section ->
      Format.pp_print_string formatter
        (match section with
         | Providers.Unusable_now -> "Unusable_now"
         | Providers.Usable -> "Usable"
         | Providers.No_report -> "No_report"))
    (fun left right ->
      match (left, right) with
      | Providers.Unusable_now, Providers.Unusable_now
      | Providers.Usable, Providers.Usable
      | Providers.No_report, Providers.No_report -> true
      | ( Providers.Unusable_now, (Providers.Usable | Providers.No_report)
        | Providers.Usable, (Providers.Unusable_now | Providers.No_report)
        | Providers.No_report, (Providers.Unusable_now | Providers.Usable) ) -> false)

let json_time = function None -> "null" | Some at -> Printf.sprintf "%.1f" at

(* A window named by [id] (its limit id), so a test reads the order off ids. *)
let percent_window ?(role = "gates_model_calls") ?(kind = "five_hour") ?resets
    ?(observed_at = 1790180000.0) ~id percent =
  Printf.sprintf
    {|{"limit_id":%S,"window":{"kind":%S},"role":%S,"utilization":{"unit":"percent","value":%d},"resets_at":%s,"observed_at":%.1f,"source":"t"}|}
    id kind role percent (json_time resets) observed_at

let usd_window ?(role = "gates_model_calls") ?resets ~id ~used limit =
  Printf.sprintf
    {|{"limit_id":%S,"window":{"kind":"provider_label","label":"credit"},"role":%S,"utilization":{"unit":"usd","value":%.4f,"limit":%s},"resets_at":%s,"observed_at":1790180000.0,"source":"t"}|}
    id role used
    (match limit with None -> "null" | Some limit -> Printf.sprintf "%.4f" limit)
    (json_time resets)

let account_json ~name windows =
  Printf.sprintf
    {|{"scope":"scope:%s","scope_id":%S,"providers":[{"id":%S,"display_name":%S}],"state":"reported","windows":[%s]}|}
    name name name name (String.concat "," windows)

let silent_json name =
  Printf.sprintf
    {|{"scope":"scope:%s","scope_id":%S,"providers":[{"id":%S,"display_name":%S}],"state":"not_reported_since_start","windows":[]}|}
    name name name name

let empty_report_json name =
  Printf.sprintf
    {|{"scope":"scope:%s","scope_id":%S,"providers":[{"id":%S,"display_name":%S}],"state":"reported_no_windows","observed_at":1790180000.0,"source":"t","windows":[]}|}
    name name name name

let decode_accounts accounts =
  let json =
    Yojson.Safe.from_string
      (Printf.sprintf {|{"provider_usage_windows_since":1.0,"provider_usage_windows":[%s]}|}
         (String.concat "," accounts))
  in
  match Masc.Tui_decode_usage.decode_provider_usage_windows json with
  | Ok reading -> reading
  | Error detail -> failf "fixture should decode: %s" detail

let exhausted_scope ?resets name =
  runtime ?resets ~scope:("scope:" ^ name) ~exhausted:true (name ^ ".model")

let shape groups =
  List.map
    (fun { Providers.pg_section; pg_entries } ->
      ( pg_section
      , List.map
          (fun (entry : Providers.plan_entry) ->
            ( Providers.scope_id entry.pe_account
            , List.map
                (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
                  Option.value ~default:"-" window.puw_limit_id)
                entry.pe_windows ))
          pg_entries ))
    groups

let plan_shape ?(runtimes = Types.Quota_unread) accounts =
  shape
    (Providers.plan ~now ~runtimes (decode_accounts accounts).puws_accounts)

let shape_t = list (pair plan_section_t (list (pair string (list string))))
let hour = 3600.0

let observed_t =
  testable
    (fun formatter observed ->
      Format.pp_print_string formatter
        (match observed with
         | Providers.Not_observed_exhausted -> "Not_observed_exhausted"
         | Providers.Observed_exhausted None -> "Observed_exhausted None"
         | Providers.Observed_exhausted (Some at) ->
             Printf.sprintf "Observed_exhausted (Some %.1f)" at))
    (fun left right ->
      match (left, right) with
      | Providers.Not_observed_exhausted, Providers.Not_observed_exhausted -> true
      | Providers.Observed_exhausted left, Providers.Observed_exhausted right ->
          Option.equal Float.equal left right
      | Providers.Not_observed_exhausted, Providers.Observed_exhausted _
      | Providers.Observed_exhausted _, Providers.Not_observed_exhausted -> false)

(* The header's numbers as plain values, ((accounts, reporting), (at limit,
   blocked)); [None] is an unknown blocked count. *)
let counts_of ?(runtimes = Types.Quota_unread) accounts =
  let counts = Providers.counts ~runtimes (decode_accounts accounts).puws_accounts in
  ( (counts.accounts, counts.reporting)
  , ( counts.at_limit
    , match counts.blocked with
      | Providers.Blocked_accounts count -> Some count
      | Providers.Blocked_unknown -> None ) )

let counts_t = pair (pair int int) (pair int (option int))

let section_lines ?(runtimes = Types.Quota_unread) ?(account_emails = Types.Account_emails_unread)
    ~width accounts =
  match
    Providers.section ~providers:(Types.Providers_read (decode_accounts accounts))
      ~runtimes ~account_emails ~now ~width ~show_unusable:true
  with
  | Some section -> section.lines
  | None -> fail "a read draws a section"

(* The rows with a bar, as drawn. *)
let bar_rows lines = List.filter (contains ~affix:meter_open) lines

(* The SGR code that marks an at-limit window. Name cells carry their
   section's tone too, so a row is checked where the name is blank. *)
let bad_tone () = Masc_tui_ansi.Theme.bad ()

let test_section_draws_one_line_per_window () =
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
        ~width ~show_unusable:true
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
  let text = String.concat "\n" lines in
  List.iter (fun fact -> check bool ("retains " ^ fact) true (contains ~affix:fact text))
    [ "Kimi Coding"; "Claude Max"; " 67%"; " 44%"; "100%" ];
  check counts_t "the header counts, as typed values" ((4, 2), (1, Some 1))
    (let counts = Providers.counts ~runtimes windows.puws_accounts in
     ( (counts.accounts, counts.reporting)
     , ( counts.at_limit
       , match counts.blocked with
         | Providers.Blocked_accounts count -> Some count
         | Providers.Blocked_unknown -> None ) ));
  let groups =
    Providers.plan ~now ~runtimes windows.puws_accounts
  in
  check (list plan_section_t) "the plan is drawn in section order"
    [ Providers.Unusable_now; Providers.Usable; Providers.No_report ]
    (List.map (fun { Providers.pg_section; _ } -> pg_section) groups);
  let first_account =
    match groups with
    | { Providers.pg_entries = entry :: _; _ } :: _ -> Providers.scope_id entry.pe_account
    | { Providers.pg_entries = []; _ } :: _ | [] -> fail "the plan has an unusable account"
  in
  check string "the account at its limit is drawn first" "id-kimi" first_account;
  check bool "unreported accounts remain visible" true
    (contains ~affix:"Codex Pro" text && contains ~affix:"Ollama Cloud" text);
  let five_hour = List.find (fun line -> contains ~affix:"67%" line) lines in
  let meter, cells = meter_of five_hour in
  check string "the window still draws the reported share" meter (Providers.meter ~cells 0.67);
  check bool "one window is one row" true
    (List.length (bar_rows lines) = 3)

(* A silent account keeps its identity and, when observed, its exhaustion. *)
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
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows) ~runtimes ~now ~width ~show_unusable:true
  with
  | None -> fail "a read draws a section"
  | Some section ->
      let lines = List.map plain section.lines in
      check bool "the silent account keeps its name" true
        (List.exists (contains ~affix:"Codex Pro") lines);
      check bool "the unblocked silent account is visible too" true
        (List.exists (contains ~affix:"Ollama Cloud") lines);
      let groups = Providers.plan ~now ~runtimes windows.puws_accounts in
      let drawn_observations =
        List.concat_map
          (fun { Providers.pg_section; pg_entries } ->
            List.map
              (fun (entry : Providers.plan_entry) ->
                ( pg_section
                , Providers.scope_id entry.pe_account
                , Providers.drawn_observation pg_section entry.pe_observed ))
              pg_entries)
          groups
      in
      check
        (list (triple plan_section_t string observed_t))
        "the exhausted silent account is unusable and draws its observation"
        [ ( Providers.Unusable_now, "id-codex"
          , Providers.Observed_exhausted None )
        ; (Providers.Unusable_now, "id-kimi", Providers.Not_observed_exhausted)
        ; (Providers.Usable, "id-claude_code", Providers.Not_observed_exhausted)
        ; (Providers.No_report, "id-ollama_cloud", Providers.Not_observed_exhausted) ]
        (List.filter
           (fun (_, id, _) ->
             List.mem id [ "id-kimi"; "id-codex"; "id-claude_code"; "id-ollama_cloud" ])
           drawn_observations)

let reported_section ?(current = now) ?(kimi_observed_at = 1790170000.0)
    ?(kimi_resets_at = 1790179580.0) ~width () =
  let windows =
    match Masc.Tui_decode_usage.decode_provider_usage_windows
      (resolved ~kimi_observed_at ~kimi_resets_at "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let runtimes =
    Types.Quota_read
      [ runtime ~scope:"provider:kimi" ~exhausted:true
          ~resets:(current +. 7200.0) "kimi.k3"
      ]
  in
  match
    Providers.section ~account_emails:Types.Account_emails_unread ~providers:(Types.Providers_read windows) ~runtimes ~now:current ~show_unusable:true
      ~width
  with
  | Some section -> List.map plain section.lines
  | None -> fail "a read draws a section"

let claude_five_hour lines =
  match List.find_opt (contains ~affix:"67%") lines with
  | Some row -> row
  | None -> fail "no Claude Max row"

let widths = [ 24; 44; 70; 80; 120; 132 ]

(* The meter stays bounded, shrinks before it grows, and every row of every
   width fits the screen. *)
let test_meter_width_is_bounded () =
  let meter_cells width =
    snd (meter_of (claude_five_hour (reported_section ~width ())))
  in
  let wide = meter_cells 132 and medium = meter_cells 80 and narrow = meter_cells 44 in
  check bool "a wide terminal draws a bounded meter" true (wide >= 6 && wide <= 24);
  check bool "a narrower terminal never draws a longer meter" true
    (narrow <= medium && medium <= wide);
  List.iter
    (fun width ->
      List.iter
        (fun line ->
          check bool (Printf.sprintf "row fits %d cells" width) true
            (Masc_tui_message_layout.display_width line <= width))
        (reported_section ~width ()))
    widths

(* Reset times are drawn in the terminal's zone: a time on another day
   carries its date. Calendar times are built in the runner's own zone, and
   the expected text is fixed by the calendar, not by the formatter. *)
let test_reset_clock_follows_local_dates () =
  let local_time day hour minute =
    let calendar = Unix.localtime now in
    fst (Unix.mktime { calendar with Unix.tm_year = 2026 - 1900; tm_mon = 9 - 1;
      tm_mday = day; tm_hour = hour; tm_min = minute; tm_sec = 0 })
  in
  let current = local_time 24 1 16 in
  let drawn resets_at =
    let reading =
      decode_accounts [ account_json ~name:"a" [ percent_window ~id:"w" ~resets:resets_at 10 ] ]
    in
    match Providers.section ~providers:(Types.Providers_read reading)
            ~runtimes:Types.Quota_unread ~account_emails:Types.Account_emails_unread
            ~now:current ~width:160 ~show_unusable:true with
    | Some section -> String.concat "\n" (List.map plain section.lines)
    | None -> fail "a read draws a section"
  in
  let same_day = local_time 24 23 10 and next_day = local_time 25 2 5 in
  check string "same local day shows only the clock" "23:10"
    (Providers.clock_text ~now:current same_day);
  check string "another local day includes month and day" "09-25 02:05"
    (Providers.clock_text ~now:current next_day);
  List.iter
    (fun at ->
      check bool "the row draws the time the clock function formats" true
        (contains ~affix:(Providers.clock_text ~now:current at) (drawn at)))
    [ same_day; next_day ]

(* A window heard at a different time than its account's newest report says
   so. The others leave the time out. Read as a difference: the same account
   drawn with every window heard together changes only the older window's row. *)
let test_only_a_window_heard_at_another_time_says_so () =
  let rows ~stale_observed_at =
    bar_rows
      (List.map plain
         (section_lines ~width:160
            [ account_json ~name:"a"
                [ percent_window ~id:"fresh" ~observed_at:(now -. 60.0) 10
                ; percent_window ~id:"stale" ~observed_at:stale_observed_at 20
                ; percent_window ~id:"fresh-too" ~observed_at:(now -. 60.0) 30 ]
            ]))
  in
  let together = rows ~stale_observed_at:(now -. 60.0)
  and apart = rows ~stale_observed_at:(now -. 7200.0) in
  check int "three rows either way" 3 (List.length apart);
  (* Rows are in the plan's order: 30%, 20%, 10%. *)
  match (together, apart) with
  | [ t30; t20; t10 ], [ a30; a20; a10 ] ->
      check string "a window heard with the account's newest report is unchanged" t30 a30;
      check string "a window heard with the newest report, again" t10 a10;
      check bool "the older window's row says more" true
        (not (String.equal t20 a20) && String.length a20 > String.length t20)
  | _ -> fail "expected three rows each"

(* The newest report is the account's, whichever section a window falls in. A
   window with room, heard earlier than the full window beside it, still says
   when it was heard. *)
let test_heard_time_is_the_accounts_not_the_sections () =
  let usable_row ~room_observed_at =
    let lines =
      List.map plain
        (section_lines ~width:160
           [ account_json ~name:"a"
               [ percent_window ~id:"full" ~observed_at:(now -. 60.0) 100
               ; percent_window ~id:"room" ~observed_at:room_observed_at 50 ]
           ])
    in
    match bar_rows lines with
    | [ _unusable; usable ] -> usable
    | rows -> failf "expected one row per section, got %d" (List.length rows)
  in
  let together = usable_row ~room_observed_at:(now -. 60.0)
  and apart = usable_row ~room_observed_at:(now -. 7200.0) in
  check bool "the window in the other section says when it was heard" true
    (not (String.equal together apart))

(* Z.AI's TIME_LIMIT counts MCP and tool calls: at 100% it refuses no model
   call, so it is not drawn in the exhausted tone, while the account's token
   window beside it is still drawn as reported. *)
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
        { "limit_id": "WEEK_TOKENS_LIMIT", "window": {"kind": "seven_day"},
          "role": "gates_model_calls",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790700000, "observed_at": 1790180000.0,
          "source": "zai.quota_limit" },
        { "limit_id": "TOKENS_LIMIT", "window": {"kind": "five_hour"},
          "role": "gates_model_calls",
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790195300, "observed_at": 1790180000.0,
          "source": "zai.quota_limit" },
        { "limit_id": "UNKNOWN_LIMIT", "window": {"kind": "seven_day"},
          "role": "unclassified_limit",
          "utilization": {"unit": "percent", "value": 80},
          "resets_at": null, "observed_at": 1790180000.0,
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
        ~runtimes:Types.Quota_unread ~now ~width ~show_unusable:true
    with
    | Some section -> section
    | None -> fail "a read draws a section"
  in
  let bad = Masc_tui_ansi.Theme.bad () in
  (* An empty tone would be found in every row and prove nothing. *)
  check bool "the exhausted tone is drawn with a code" true (not (String.equal bad ""));
  (* The first row of an entry carries the name cell, which has its section's
     tone. TIME_LIMIT and TOKENS_LIMIT are second rows, so their own tone shows. *)
  let time_limit = List.find (fun line -> contains ~affix:"TIME_LIMIT" (plain line)) section.lines in
  let tokens_limit = List.find (fun line -> contains ~affix:"TOKENS_LIMIT" (plain line)) section.lines in
  check bool "the non-gating window is not an alarm" false (contains ~affix:bad time_limit);
  check bool "the model-call window at full is an alarm" true (contains ~affix:bad tokens_limit);
  check shape_t "only the gating windows at full are unusable"
    [ (Providers.Unusable_now, [ ("id-glm", [ "WEEK_TOKENS_LIMIT"; "TOKENS_LIMIT" ]) ])
    ; (Providers.Usable, [ ("id-glm", [ "UNKNOWN_LIMIT"; "TIME_LIMIT" ]) ]) ]
    (shape (Providers.plan ~now ~runtimes:Types.Quota_unread windows.puws_accounts));
  check bool "the source label is retained" true
    (List.exists (fun line -> contains ~affix:"1 x unit 5" (plain line)) section.lines)

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

let test_account_emails_name_their_accounts () =
  let windows =
    match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows
    | Error err -> failf "fixture should decode: %s" err
  in
  let section account_emails =
    match
      Providers.section ~providers:(Types.Providers_read windows)
        ~runtimes:Types.Quota_unread ~account_emails ~now ~width ~show_unusable:true
    with
    | Some section -> section
    | None -> fail "a read draws a section"
  in
  let read ?(unreadable_rows = 0) emails =
    section (Types.Account_emails_read { emails; unreadable_rows })
  in
  let without = section Types.Account_emails_unread in
  let fitting = read [ ("claude_code", "c@x.io"); ("kimi", "kimi@example.com"); ("codex", "codex@example.com") ] in
  let text = String.concat "\n" (List.map plain fitting.lines) in
  List.iter (fun fact -> check bool ("email identity retains " ^ fact) true
    (contains ~affix:fact text)) [ "Claude Max"; "id-claud"; "c@x.io"; "kimi@example.com" ];
  check bool "an account with no usage report keeps its email" true
    (contains ~affix:"codex@example.com" text);
  let wide = read [ ("claude_code", "claude.with.long.address@example.com") ] in
  let meters (section : Providers.section) = List.filter (contains ~affix:meter_open) (List.map plain section.lines) in
  check (list string) "email metadata does not narrow window meters"
    (meters without) (meters wide);
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
    {|{"days":14,"generated_at":1780000000.0,"sampling":"latest_provider_report_per_utc_day","unreadable_reports":0,"reported_no_windows":[],"points":[{"scope_id":"abc12345","kind":"five_hour","limit_id":null,"unit":"fraction","value":0.4,"observed_at":1779999900.0,"source":"codex.account_rate_limits_read","resets_at":null}]}|}
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
            | Masc.Tui_decode_usage.Utilization_percent _
            | Masc.Tui_decode_usage.Utilization_usd _ -> fail "unit changed")
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
      puh_reported_no_windows = [];
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
    ; ("s1", "0" ^ none ^ "\xe2\x96\x88", 2)
    ]
    (List.map
       (fun (row : Masc_tui_usage_trend.row) ->
         (row.scope_id, row.marks, row.reported_days))
       trend.rows);
  let row = List.find (fun (row:Masc_tui_usage_trend.row) -> row.scope_id = "s1") trend.rows in
  let plot = Masc_tui_usage_trend.plot ~width:60 trend row in
  check bool "daily chart has its fixed full-limit axis" true
    (List.exists (contains ~affix:"100%") plot);
  check bool "zero and missing report have distinct baseline marks" true
    (List.exists (contains ~affix:("0   " ^ none)) plot);
  check bool "a report retains its own timestamp, not response time" true
    (match Masc_tui_usage_trend.latest row with
     | Some sample -> Float.equal sample.observed_at generated_at
     | None -> false);
  List.iter (fun width -> List.iter (fun line ->
    check bool "chart respects terminal cells" true
      (Masc_tui_message_layout.display_width line <= width))
    (Masc_tui_usage_trend.plot ~width trend row)) [1; 20; 60]

let test_plan_history_preserves_out_of_range_reports () =
  let open Masc.Tui_decode_usage in
  let point observed_at value : provider_usage_history_point =
    { puhp_scope_id = "out-of-range"; puhp_kind = "five_hour"; puhp_limit_id = None;
      puhp_unit = value; puhp_observed_at = observed_at } in
  let history : provider_usage_history =
    { puh_days = 3; puh_generated_at = now; puh_unreadable_reports = 0;
      puh_reported_no_windows = [];
      puh_points = [point (now -. 172800.) (Utilization_fraction (-0.2));
        point (now -. 86400.) (Utilization_percent 140);
        point now (Utilization_fraction 0.)] } in
  let trend = Masc_tui_usage_trend.of_history ~share:Providers.share_of_full history in
  let row = List.hd trend.rows in
  check string "Plan keeps below-zero and above-limit history distinct" "↓↑0" row.marks;
  check bool "compact Trend shares the Plan markers" true
    (contains ~affix:row.marks (String.concat "" (Masc_tui_usage_trend.plot ~width:10 trend row)))

let test_empty_history_report_reaches_trend () =
  let module Decode = Masc.Tui_decode_usage in
  let now = 1780000000. in
  let payload = `Assoc ["days", `Int 7; "generated_at", `Float now;
    "sampling", `String "latest_provider_report_per_utc_day"; "unreadable_reports", `Int 0;
    "points", `List [`Assoc ["scope_id", `String "prior"; "kind", `String "five_hour";
      "limit_id", `Null; "unit", `String "fraction"; "value", `Float 0.;
      "observed_at", `Float (now -. 86400.)]];
    "reported_no_windows", `List (List.map (fun scope -> `Assoc ["scope_id", `String scope;
      "observed_at", `Float now]) ["prior"; "empty-only"])] in
  let history = match Decode.decode_provider_usage_history payload with
    | Ok history -> history | Error detail -> fail detail in
  let trend = Masc_tui_usage_trend.of_history ~share:Providers.share_of_full history in
  let find scope = List.find (fun (row : Masc_tui_usage_trend.row) -> row.scope_id=scope) trend.rows in
  let none = Masc_tui_usage_trend.no_report_mark and empty = Masc_tui_usage_trend.empty_report_mark in
  check string "no-window day differs from measured zero and missing report"
    (String.concat "" (List.init 5 (fun _ -> none)) ^ "0" ^ empty) (find "prior").marks;
  check int "empty day counts as reported alongside measured day" 2 (find "prior").reported_days;
  check string "empty-only scope has a visible row"
    (String.concat "" (List.init 6 (fun _ -> none)) ^ empty) (find "empty-only").marks;
  check int "empty-only successful report counted" 1 (find "empty-only").reported_days;
  check bool "latest empty report retains its typed state" true
    (match Masc_tui_usage_trend.latest (find "empty-only") with
     | Some { report = Masc_tui_usage_trend.Reported_no_windows; observed_at } -> observed_at = now
     | Some { report = Masc_tui_usage_trend.Measured _; _ } | None -> false);
  let uncapped = { history with puh_points = [{ puhp_scope_id = "uncapped";
    puhp_kind = "credit usage"; puhp_limit_id = None;
    puhp_unit = Decode.Utilization_usd {used = 12.3456; limit = None}; puhp_observed_at = now }];
    puh_reported_no_windows = [] } in
  let uncapped_trend = Masc_tui_usage_trend.of_history ~share:Providers.share_of_full uncapped in
  let uncapped_row = List.hd uncapped_trend.rows in
  check bool "uncapped USD has its own plot mark" true
    (List.exists (contains ~affix:"$") (Masc_tui_usage_trend.plot ~width:80 uncapped_trend uncapped_row));
  check bool "uncapped sample retains amount without denominator" true
    (match Masc_tui_usage_trend.latest uncapped_row with
     | Some {report = Masc_tui_usage_trend.Measured (Decode.Utilization_usd {used; limit=None}, None); _} -> used = 12.3456
     | Some _ | None -> false);
  let fields = match payload with `Assoc fields -> fields | _ -> assert false in
  List.iter (fun fields -> check bool "missing or malformed daily empty state is a failed read" true
    (Result.is_error (Decode.decode_provider_usage_history (`Assoc fields))))
    [List.remove_assoc "reported_no_windows" fields;
     ("reported_no_windows", `List [`Assoc ["scope_id", `String "bad"]]) :: List.remove_assoc "reported_no_windows" fields]

(* The id the section names a scope by is the server's, carried on the row,
   so the trend's points and the current windows cannot disagree. *)
let test_scope_id_is_the_servers () =
  match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
  | Error err -> failf "fixture should decode: %s" err
  | Ok windows ->
      check (list string) "ids as the server sent them"
        [ "id-codex"; "id-kimi"; "id-claude_code"; "id-ollama_cloud" ]
        (List.map Providers.scope_id windows.puws_accounts)

let test_unread_catalogue_is_not_zero_blocked () =
  let windows = match Masc.Tui_decode_usage.decode_provider_usage_windows (resolved "reported") with
    | Ok windows -> windows | Error reason -> fail reason in
  let section = match Providers.section
    ~providers:(Types.Providers_read windows) ~runtimes:Types.Quota_unread
    ~account_emails:Types.Account_emails_unread ~now ~width:80 ~show_unusable:true with
    | Some section -> section | None -> fail "expected plan rows" in
  let text = String.concat "\n" (List.map plain section.lines) in
  check bool "catalogue absence is not reported as no blocked accounts" true
    (contains ~affix:"Blocked (observed) unknown" text)

let test_plan_preserves_unknown_reports () =
  let open Masc.Tui_decode_usage in
  let windows = match decode_provider_usage_windows (resolved "reported") with
    | Ok value -> value | Error detail -> fail detail in
  let draw windows =
    match Providers.section
      ~providers:(Types.Providers_read windows) ~runtimes:Types.Quota_unread
      ~account_emails:Types.Account_emails_unread ~now ~width:100 ~show_unusable:true with
    | Some section -> String.concat "\n" (List.map plain section.lines)
    | None -> fail "expected plan summary" in
  let silent = { windows with puws_accounts = List.map (fun account ->
    { account with pua_state = Account_not_reported_since_start }) windows.puws_accounts } in
  let text = draw silent in
  List.iter (fun expected -> check bool expected true (contains ~affix:expected text))
    [ "Accounts 4"; "Reporting 0" ];
  let limit role share = { windows with puws_accounts = List.filter_map (fun account ->
    match account.pua_state with
    | Account_not_reported_since_start | Account_reported_no_windows _ -> None
    | Account_reported (first, _) -> Some { account with
        pua_state = Account_reported ({ first with puw_role = role;
          puw_utilization = Utilization_fraction share }, []) }) windows.puws_accounts } in
  check bool "full unclassified limits count" true
    (contains ~affix:"At limit (reported) 2" (draw (limit Role_unclassified_limit 1.0)));
  check bool "other-use counters do not count" true
    (contains ~affix:"At limit (reported) 0" (draw (limit Role_counts_other_use 1.0)));
  List.iter (fun share ->
    check bool "invalid values do not advertise remaining cells" false
      (contains ~affix:"░" (String.concat "\n"
        (String.split_on_char '\n' (draw (limit Role_gates_model_calls share))
         |> List.filter (fun line -> contains ~affix:meter_open line)))))
    [ -0.5; Float.nan; Float.neg_infinity; Float.infinity ];
  List.iter (fun share ->
    check string "nonfinite reports do not draw a used meter" "    "
      (Providers.meter ~cells:4 share);
    check bool "nonfinite reports do not count as at limit" true
      (contains ~affix:"At limit (reported) 0" (draw (limit Role_gates_model_calls share))))
    [Float.nan; Float.neg_infinity; Float.infinity]

let test_usd_rows_do_not_invent_a_percentage () =
  let json = Yojson.Safe.from_string
    {|{"provider_usage_windows_since":1,"provider_usage_windows":[
      {"scope":"usd","scope_id":"usd","providers":[{"id":"openrouter","display_name":"OpenRouter"}],
       "state":"reported","windows":[
        {"limit_id":null,"window":{"kind":"provider_label","label":"API key credit limit"},"role":"gates_model_calls",
         "utilization":{"unit":"usd","value":5.5,"limit":20},"resets_at":null,"observed_at":2},
        {"limit_id":null,"window":{"kind":"provider_label","label":"API key usage (all time)"},"role":"counts_other_use",
         "utilization":{"unit":"usd","value":12.3456,"limit":null},"resets_at":null,"observed_at":2}]}]}|}
  in
  let reading = match Masc.Tui_decode_usage.decode_provider_usage_windows json with
    | Ok reading -> reading | Error detail -> fail detail in
  List.iter (fun width ->
    let section = match Providers.section ~providers:(Types.Providers_read reading)
        ~runtimes:Types.Quota_unread ~account_emails:Types.Account_emails_unread ~now ~width ~show_unusable:true with
      | Some section -> section | None -> fail "USD accounts disappeared" in
    let lines = List.map plain section.lines in
    let text = String.concat " " lines in
    List.iter (fun value -> check bool ("retains " ^ value) true (contains ~affix:value text))
      [ "$5.50/$20"; "27%"; "$12.35" ];
    check bool "the uncapped amount draws no percentage" false
      (List.exists (fun line -> contains ~affix:"spent" line && contains ~affix:"%" line) lines);
    check int "only the capped amount has a meter" 1
      (List.length (List.filter (contains ~affix:meter_open) lines));
    List.iter (fun line -> check bool "USD rows fit the terminal" true
      (Masc_tui_message_layout.display_width line <= width)) lines)
    [44; 80; 132];
  check (option (float 0.0001)) "an uncapped amount has no fabricated percentage" None
    (Providers.share_of_full (Masc.Tui_decode_usage.Utilization_usd { used = 12.3456; limit = None }))

(* ---- plan: sections and order, asserted on typed data ------------------ *)

(* The sketch the operator approved: a priced key at its limit with no
   reset, an account whose weekly window is at its limit, accounts with room,
   and one that has not reported. Antigravity has windows in two sections. *)
let test_plan_splits_accounts_by_window_state () =
  check shape_t "sections and order"
    [ ( Providers.Unusable_now
      , [ ("openrouter", [ "credit" ])
        ; ("antigravity", [ "gemini-7d" ]) ] )
    ; ( Providers.Usable
      , [ ("kimi", [ "usage"; "5h" ])
        ; ("ollama", [ "7d" ])
        ; ("antigravity", [ "3p-5h" ])
        ; ("openrouter", [ "key-usage" ]) ] )
    ; (Providers.No_report, [ ("codex", []) ])
    ]
    (plan_shape
       [ account_json ~name:"antigravity"
           [ percent_window ~id:"3p-5h" ~resets:(now +. 5.0 *. hour) 0
           ; percent_window ~id:"gemini-7d" ~resets:(now +. 22.0 *. hour) 100 ]
       ; account_json ~name:"ollama" [ percent_window ~id:"7d" 43 ]
       ; account_json ~name:"kimi"
           [ percent_window ~id:"5h" ~resets:(now +. 0.5 *. hour) 56
           ; percent_window ~id:"usage" ~resets:(now +. 150.0 *. hour) 83 ]
       ; account_json ~name:"openrouter"
           [ usd_window ~id:"credit" ~used:100.0 (Some 100.0)
           ; usd_window ~role:"counts_other_use" ~id:"key-usage" ~used:12.3456 None ]
       ; silent_json "codex"
       ])

(* An unusable account with the longest wait is first; a window with no
   reset time waits longest; a reset that has passed waits least. *)
let test_unusable_order_is_longest_wait_first () =
  check shape_t "no reset, then longest, then shortest, then passed"
    [ ( Providers.Unusable_now
      , [ ("none", [ "a" ])
        ; ("long", [ "a" ])
        ; ("short", [ "a" ])
        ; ("passed", [ "a" ]) ] ) ]
    (plan_shape
       [ account_json ~name:"passed" [ percent_window ~id:"a" ~resets:(now -. 60.0) 100 ]
       ; account_json ~name:"short" [ percent_window ~id:"a" ~resets:(now +. hour) 100 ]
       ; account_json ~name:"long" [ percent_window ~id:"a" ~resets:(now +. 30.0 *. hour) 100 ]
       ; account_json ~name:"none" [ percent_window ~id:"a" 100 ]
       ]);
  check shape_t "an account waits as long as its longest unusable window"
    [ ( Providers.Unusable_now
      , [ ("two", [ "week"; "day" ]); ("one", [ "day" ]) ] ) ]
    (plan_shape
       [ account_json ~name:"one" [ percent_window ~id:"day" ~resets:(now +. 5.0 *. hour) 100 ]
       ; account_json ~name:"two"
           [ percent_window ~id:"day" ~resets:(now +. hour) 100
           ; percent_window ~id:"week" ~resets:(now +. 100.0 *. hour) 100 ]
       ])

let test_ties_go_by_account_name () =
  check shape_t "equal waits, equal use and silent accounts are by name"
    [ ( Providers.Unusable_now, [ ("alpha", [ "a" ]); ("beta", [ "a" ]) ] )
    ; ( Providers.Usable, [ ("cedar", [ "a" ]); ("delta", [ "a" ]) ] )
    ; (Providers.No_report, [ ("echo", []); ("fig", []) ]) ]
    (plan_shape
       [ silent_json "fig"
       ; account_json ~name:"delta" [ percent_window ~id:"a" 50 ]
       ; account_json ~name:"beta" [ percent_window ~id:"a" ~resets:(now +. hour) 100 ]
       ; silent_json "echo"
       ; account_json ~name:"cedar" [ percent_window ~id:"a" 50 ]
       ; account_json ~name:"alpha" [ percent_window ~id:"a" ~resets:(now +. hour) 100 ]
       ])

(* Usable is the least left first. A window that gates nothing, an amount
   with no cap and a value that is not a number press on nothing. *)
let test_usable_order_is_most_used_first () =
  check shape_t "most used first, unmeasured last"
    [ ( Providers.Usable
      , [ ("high", [ "mid"; "low" ])
        ; ("mid", [ "a" ])
        ; ("low", [ "a" ])
        ; ("other-use", [ "a" ])
        ; ("uncapped", [ "a" ]) ] ) ]
    (plan_shape
       [ account_json ~name:"uncapped" [ usd_window ~id:"a" ~used:9.0 None ]
       ; account_json ~name:"other-use"
           [ percent_window ~role:"counts_other_use" ~id:"a" 100 ]
       ; account_json ~name:"low" [ percent_window ~id:"a" 10 ]
       ; account_json ~name:"high"
           [ percent_window ~id:"low" 5; percent_window ~id:"mid" 99 ]
       ; account_json ~name:"mid" [ percent_window ~id:"a" 60 ]
       ])

let test_a_full_window_that_gates_nothing_is_usable () =
  check shape_t "other use at 100 percent is not unusable"
    [ (Providers.Usable, [ ("zai", [ "tokens"; "time" ]) ]) ]
    (plan_shape
       [ account_json ~name:"zai"
           [ percent_window ~role:"counts_other_use" ~id:"time" 100
           ; percent_window ~id:"tokens" 30 ]
       ]);
  check shape_t "an unclassified limit at 100 percent is unusable"
    [ (Providers.Unusable_now, [ ("zai", [ "mystery" ]) ]) ]
    (plan_shape
       [ account_json ~name:"zai" [ percent_window ~role:"unclassified_limit" ~id:"mystery" 100 ] ])

(* The catalogue observed the account exhausted: every window that gates
   model calls is unusable whatever it reports; a silent account is too; an
   account with only other-use windows keeps an entry in both sections. *)
let test_observed_exhaustion_blocks_gating_windows () =
  let runtimes =
    Types.Quota_read
      [ exhausted_scope ~resets:(now +. 2.0 *. hour) "kimi"
      ; exhausted_scope "codex"
      ; exhausted_scope "zai"
      ; runtime ~scope:"scope:ollama" ~exhausted:false "ollama.model"
      ]
  in
  check shape_t "observed accounts move to the unusable section"
    [ ( Providers.Unusable_now
      , [ ("codex", []); ("zai", []); ("kimi", [ "usage"; "5h" ]) ] )
    ; (Providers.Usable, [ ("ollama", [ "7d" ]); ("zai", [ "time" ]) ])
    ; (Providers.No_report, [ ("echo", []) ]) ]
    (plan_shape ~runtimes
       [ account_json ~name:"kimi"
           [ percent_window ~id:"5h" ~resets:(now +. 0.5 *. hour) 56
           ; percent_window ~id:"usage" ~resets:(now +. 3.0 *. hour) 83 ]
       ; silent_json "codex"
       ; silent_json "echo"
       ; account_json ~name:"zai" [ percent_window ~role:"counts_other_use" ~id:"time" 100 ]
       ; account_json ~name:"ollama" [ percent_window ~id:"7d" 43 ]
       ]);
  check shape_t "an unread catalogue observes nothing"
    [ (Providers.Usable, [ ("kimi", [ "usage"; "5h" ]) ]) ]
    (plan_shape ~runtimes:Types.Quota_unread
       [ account_json ~name:"kimi"
           [ percent_window ~id:"5h" 56; percent_window ~id:"usage" 83 ] ]);
  check shape_t "a failed catalogue observes nothing"
    [ (Providers.No_report, [ ("codex", []) ]) ]
    (plan_shape ~runtimes:(Types.Quota_failed "HTTP 500") [ silent_json "codex" ])

(* An account that reported no windows has nothing to measure. *)
let test_an_empty_report_is_no_report () =
  check shape_t "reported with no windows"
    [ (Providers.No_report, [ ("empty", []) ]) ]
    (plan_shape [ empty_report_json "empty" ])

(* The header's "At limit (reported)" and the Unusable section are one
   decision. *)
let test_at_limit_is_the_header_decision () =
  let decoded =
    decode_accounts
      [ account_json ~name:"a"
          [ percent_window ~id:"full" 100
          ; percent_window ~id:"other" ~role:"counts_other_use" 100
          ; percent_window ~id:"open" 99
          ; usd_window ~id:"usd" ~used:5.0 (Some 5.0)
          ; usd_window ~id:"uncapped" ~used:500.0 None ]
      ]
  in
  let windows =
    match (List.hd decoded.puws_accounts).pua_state with
    | Masc.Tui_decode_usage.Account_reported (first, rest) -> first :: rest
    | Masc.Tui_decode_usage.Account_not_reported_since_start
    | Masc.Tui_decode_usage.Account_reported_no_windows _ -> fail "fixture reports windows"
  in
  check (list (pair string bool)) "which windows are at their limit"
    [ ("full", true); ("other", false); ("open", false); ("usd", true); ("uncapped", false) ]
    (List.map
       (fun (window : Masc.Tui_decode_usage.provider_usage_window) ->
         (Option.value ~default:"-" window.puw_limit_id, Providers.window_at_limit window))
       windows);
  check int "the account is counted once" 1
    (Providers.counts ~runtimes:Types.Quota_unread decoded.puws_accounts).at_limit;
  check shape_t "and its at-limit windows are the unusable ones"
    [ (Providers.Unusable_now, [ ("a", [ "full"; "usd" ]) ])
    ; (Providers.Usable, [ ("a", [ "open"; "other"; "uncapped" ]) ]) ]
    (shape (Providers.plan ~now ~runtimes:Types.Quota_unread decoded.puws_accounts))

(* ---- more ordering decisions, on typed data ---------------------------- *)

(* A priced window past its cap is at its limit, like one exactly at it. *)
let test_an_amount_past_its_cap_is_unusable () =
  check shape_t "used above the limit is unusable; below it is not"
    [ (Providers.Unusable_now, [ ("over", [ "credit" ]) ])
    ; (Providers.Usable, [ ("under", [ "credit" ]) ]) ]
    (plan_shape
       [ account_json ~name:"under" [ usd_window ~id:"credit" ~used:99.0 (Some 100.0) ]
       ; account_json ~name:"over" [ usd_window ~id:"credit" ~used:120.0 (Some 100.0) ]
       ])

(* A window at its limit whose reset time has passed is still unusable: the
   server keeps the last report until a newer one arrives. It waits least,
   so it comes after every window that waits for a future reset. *)
let test_a_passed_reset_is_still_unusable_and_last () =
  check shape_t "passed reset is last among unusable accounts"
    [ ( Providers.Unusable_now
      , [ ("future", [ "a" ]); ("passed", [ "a" ]) ] ) ]
    (plan_shape
       [ account_json ~name:"passed" [ percent_window ~id:"a" ~resets:(now -. 60.0) 100 ]
       ; account_json ~name:"future" [ percent_window ~id:"a" ~resets:(now +. hour) 100 ]
       ]);
  check shape_t "beside a window with no reset, the passed one comes after it"
    [ ( Providers.Unusable_now
      , [ ("mixed", [ "no-reset"; "passed" ]); ("other", [ "day" ]) ] ) ]
    (plan_shape
       [ account_json ~name:"other" [ percent_window ~id:"day" ~resets:(now +. 30.0 *. hour) 100 ]
       ; account_json ~name:"mixed"
           [ percent_window ~id:"passed" ~resets:(now -. 60.0) 100
           ; percent_window ~id:"no-reset" 100 ]
       ])

(* The catalogue's reopen time is not a window's reset. An account with a
   window to show waits by its windows; the catalogue's time orders only an
   account with no window. *)
let test_catalogue_time_does_not_replace_a_windows_reset () =
  let runtimes =
    Types.Quota_read
      [ exhausted_scope ~resets:(now +. hour) "stated"
      ; exhausted_scope ~resets:(now +. 5.0 *. hour) "other"
      ]
  in
  check shape_t "a window with no reset waits longest whatever the catalogue says"
    [ ( Providers.Unusable_now
      , [ ("stated", [ "w" ]); ("other", [ "w" ]) ] ) ]
    (plan_shape ~runtimes
       [ account_json ~name:"other" [ percent_window ~id:"w" ~resets:(now +. 5.0 *. hour) 50 ]
       ; account_json ~name:"stated" [ percent_window ~id:"w" 50 ]
       ])

(* An account with no window to show is ordered by the catalogue's reopen
   time: none stated first, then the latest, then the earliest. *)
let test_catalogue_time_orders_accounts_with_no_window () =
  let runtimes =
    Types.Quota_read
      [ exhausted_scope ~resets:(now +. hour) "soon"
      ; exhausted_scope ~resets:(now +. 30.0 *. hour) "late"
      ; exhausted_scope "unstated"
      ]
  in
  check shape_t "no time, latest, earliest"
    [ ( Providers.Unusable_now
      , [ ("unstated", []); ("late", []); ("soon", []) ] ) ]
    (plan_shape ~runtimes [ silent_json "soon"; silent_json "late"; silent_json "unstated" ])

(* Several exhausted runtimes in one scope: the latest reopen time wins, and
   a runtime that states none does not erase one that does. *)
let test_the_latest_catalogue_reopen_time_wins () =
  let observed runtimes = Providers.observed_exhaustion ~runtimes:(Types.Quota_read runtimes) "scope:x" in
  check observed_t "latest of two"
    (Providers.Observed_exhausted (Some (now +. 30.0 *. hour)))
    (observed
       [ exhausted_scope ~resets:(now +. hour) "x"
       ; exhausted_scope ~resets:(now +. 30.0 *. hour) "x" ]);
  check observed_t "the same, in the other order"
    (Providers.Observed_exhausted (Some (now +. 30.0 *. hour)))
    (observed
       [ exhausted_scope ~resets:(now +. 30.0 *. hour) "x"
       ; exhausted_scope ~resets:(now +. hour) "x" ]);
  check observed_t "a runtime with no time keeps the one that has it"
    (Providers.Observed_exhausted (Some (now +. hour)))
    (observed [ exhausted_scope "x"; exhausted_scope ~resets:(now +. hour) "x" ]);
  check observed_t "none states a time"
    (Providers.Observed_exhausted None)
    (observed [ exhausted_scope "x"; exhausted_scope "x" ]);
  check observed_t "an exhausted runtime of another scope is not this scope's"
    Providers.Not_observed_exhausted
    (observed [ exhausted_scope "y" ])

(* An account that reported no windows and is observed exhausted is unusable,
   like a silent one. *)
let test_an_empty_report_can_be_observed_exhausted () =
  check shape_t "reported with no windows, observed exhausted"
    [ (Providers.Unusable_now, [ ("empty", []) ]) ]
    (plan_shape ~runtimes:(Types.Quota_read [ exhausted_scope "empty" ])
       [ empty_report_json "empty" ])

(* The catalogue's observation is drawn once per account, in the Unusable
   section, even when the account's other windows sit in another section. *)
let test_the_observation_is_drawn_once_for_a_split_account () =
  let runtimes = Types.Quota_read [ exhausted_scope "zai" ] in
  let groups =
    Providers.plan ~now ~runtimes
      (decode_accounts
         [ account_json ~name:"zai"
             [ percent_window ~id:"tokens" 30
             ; percent_window ~role:"counts_other_use" ~id:"time" 100 ]
         ]).puws_accounts
  in
  check shape_t "the account is in both sections"
    [ (Providers.Unusable_now, [ ("zai", [ "tokens" ]) ])
    ; (Providers.Usable, [ ("zai", [ "time" ]) ]) ]
    (shape groups);
  let drawn =
    List.concat_map
      (fun { Providers.pg_section; pg_entries } ->
        List.map
          (fun (entry : Providers.plan_entry) ->
            Providers.drawn_observation pg_section entry.pe_observed)
          pg_entries)
      groups
  in
  check (list observed_t) "the Unusable entry draws it and the Usable one does not"
    [ Providers.Observed_exhausted None; Providers.Not_observed_exhausted ]
    drawn;
  List.iter
    (fun section ->
      check observed_t "no other section draws an observation"
        Providers.Not_observed_exhausted
        (Providers.drawn_observation section (Providers.Observed_exhausted None)))
    [ Providers.Usable; Providers.No_report ];
  check observed_t "the Unusable section draws it"
    (Providers.Observed_exhausted None)
    (Providers.drawn_observation Providers.Unusable_now (Providers.Observed_exhausted None))

let test_the_header_counts_are_typed () =
  let accounts =
    [ account_json ~name:"full" [ percent_window ~id:"a" 100 ]
    ; account_json ~name:"room" [ percent_window ~id:"a" 10 ]
    ; empty_report_json "empty"
    ; silent_json "silent" ]
  in
  check counts_t "an unread catalogue leaves blocked unknown, not zero"
    ((4, 3), (1, None)) (counts_of accounts);
  check counts_t "a failed catalogue leaves blocked unknown"
    ((4, 3), (1, None)) (counts_of ~runtimes:(Types.Quota_failed "HTTP 500") accounts);
  check counts_t "a read catalogue counts the accounts it observes exhausted"
    ((4, 3), (1, Some 2))
    (counts_of ~runtimes:(Types.Quota_read [ exhausted_scope "room"; exhausted_scope "silent" ])
       accounts)

(* ---- the rendered rows -------------------------------------------------- *)

(* The shape of the operator's screenshot, drawn by the real renderer. *)
let screenshot_accounts =
  [ account_json ~name:"antigravity"
      [ percent_window ~id:"3p" ~resets:(now +. 5.0 *. hour) 0
      ; percent_window ~id:"gemini-weekly" ~kind:"seven_day" ~resets:(now +. 22.8 *. hour) 100 ]
  ; account_json ~name:"ollama" [ percent_window ~id:"weekly" ~kind:"seven_day" 43 ]
  ; account_json ~name:"kimi"
      [ percent_window ~id:"5h" ~resets:(now +. 0.5 *. hour) 56
      ; percent_window ~id:"usage" ~kind:"seven_day" ~resets:(now +. 150.0 *. hour) 83 ]
  ; account_json ~name:"openrouter"
      [ usd_window ~id:"credit" ~used:100.0 (Some 100.0)
      ; usd_window ~role:"counts_other_use" ~id:"key-usage" ~used:12.3456 None ]
  ; silent_json "codex"
  ]

let screenshot_section ?(account_emails = Types.Account_emails_unread) ~width () =
  section_lines ~account_emails ~width screenshot_accounts

(* Edge values every row of every width must still fit. *)
let edge_accounts =
  screenshot_accounts
  @ [ account_json ~name:"over" [ usd_window ~id:"credit" ~used:120.0 (Some 100.0) ]
    ; account_json ~name:"passed" [ percent_window ~id:"a" ~resets:(now -. 60.0) 100 ]
    ; account_json ~name:"long-name-account-with-many-characters"
        [ percent_window ~id:"a-very-long-limit-identifier-from-a-provider" 50 ]
    ]

let test_every_line_fits_the_width () =
  List.iter
    (fun width ->
      List.iter
        (fun line ->
          let cells = Masc_tui_message_layout.display_width line in
          if cells > width then failf "%d cells in a %d-cell screen: %S" cells width (plain line))
        (section_lines ~width edge_accounts))
    [ 20; 24; 44; 60; 76; 80; 100; 120; 132 ]

(* Lines from the first blank line on: the plan's rows, without the header. *)
let plan_rows lines =
  let rec after_blank = function
    | [] -> []
    | "" :: rest -> rest
    | _ :: rest -> after_blank rest
  in
  after_blank (List.map plain lines)

(* One window is one line down to the width of an 80-column terminal's
   section (cols - 4): the screenshot fixture takes as many lines there as on
   a wide screen. *)
let test_one_window_is_one_line_down_to_76_columns () =
  let wide = List.length (plan_rows (screenshot_section ~width:160 ())) in
  List.iter
    (fun width ->
      check int
        (Printf.sprintf "the plan takes the same lines at %d columns" width)
        wide
        (List.length (plan_rows (screenshot_section ~width ()))))
    [ 100; 80; 76 ];
  check int "one bar per window that has a cap" 6
    (List.length (bar_rows (screenshot_section ~width:76 ())))

let test_rows_follow_the_plan () =
  let raw = screenshot_section ~width:120 () in
  let lines = List.map plain raw in
  check int "each window with a cap is one row with one bar" 6
    (List.length (bar_rows lines));
  check int "an account's name is drawn once for its consecutive windows" 1
    (List.length (List.filter (contains ~affix:"kimi") lines));
  check bool "the tone is drawn with a code" true (not (String.equal (bad_tone ()) ""));
  (* The sections are drawn in plan order: the two windows at their limit
     are the first two bars. *)
  let bars = bar_rows raw in
  let at_limit_first = List.filteri (fun index _ -> index < 2) bars in
  List.iter
    (fun line -> check bool "an at-limit row comes first and says 100%" true
      (contains ~affix:"100%" (plain line)))
    at_limit_first;
  check int "no other bar says 100%" 2
    (List.length (List.filter (fun line -> contains ~affix:"100%" (plain line)) bars))

(* Tone on a row whose name cell is blank, so the row's own tone shows. *)
let test_the_at_limit_tone_is_the_reports_not_the_sections () =
  let second_bar ?runtimes accounts =
    match bar_rows (section_lines ?runtimes ~width:160 accounts) with
    | _ :: second :: _ -> second
    | _ -> fail "expected two bars"
  in
  check bool "a second window at its limit uses the bad tone" true
    (contains ~affix:(bad_tone ())
       (second_bar
          [ account_json ~name:"a"
              [ percent_window ~id:"long" ~resets:(now +. 9.0 *. hour) 100
              ; percent_window ~id:"short" ~resets:(now +. hour) 100 ] ]));
  (* Observed exhaustion puts both windows in Unusable now, but neither
     report is at its limit: the tag says the rest. *)
  check bool "a window unusable only by observation does not take the bad tone" false
    (contains ~affix:(bad_tone ())
       (second_bar
          ~runtimes:(Types.Quota_read [ exhausted_scope "a" ])
          [ account_json ~name:"a"
              [ percent_window ~id:"high" ~resets:(now +. 9.0 *. hour) 83
              ; percent_window ~id:"low" ~resets:(now +. hour) 56 ] ]))

let test_an_account_email_is_drawn_once () =
  let lines =
    screenshot_section
      ~account_emails:
        (Types.Account_emails_read
           { emails = [ ("antigravity", "ag@example.com") ]; unreadable_rows = 0 })
      ~width:120 ()
  in
  check int "split across two sections, the account names its email once" 1
    (List.length (List.filter (contains ~affix:"ag@example.com") (List.map plain lines)))

(* #44071 review P3: hiding the Unusable block keeps its heading, count and
   the way back, and nothing else of it. The header still counts every
   account, and the shown sections are untouched. *)
let test_hidden_unusable_collapses_to_its_heading () =
  let accounts =
    decode_accounts
      [ account_json ~name:"full"
          [ percent_window ~id:"week" ~resets:(now +. (5. *. 24. *. hour)) 100 ]
      ; account_json ~name:"open"
          [ percent_window ~id:"short" ~resets:(now +. hour) 70 ]
      ]
  in
  let lines_of show_unusable =
    match
      Providers.section ~providers:(Types.Providers_read accounts)
        ~runtimes:Types.Quota_unread
        ~account_emails:Types.Account_emails_unread ~now ~width:100
        ~show_unusable
    with
    | Some section -> List.map plain section.lines
    | None -> fail "a read draws a section"
  in
  let hidden = lines_of false and shown = lines_of true in
  let hidden_text = String.concat "\n" hidden in
  check bool "the collapsed row keeps its heading, count and way back" true
    (contains ~affix:"Unusable now (1) · hidden · x:show" hidden_text);
  check bool "the hidden account's rows are gone" false
    (contains ~affix:"full" hidden_text);
  check bool "the hidden account's full value is gone" false
    (contains ~affix:"100%" hidden_text);
  check bool "the header still counts the hidden account" true
    (contains ~affix:"At limit (reported) 1" hidden_text);
  check bool "showing restores the account and its value" true
    (let text = String.concat "\n" shown in
     contains ~affix:"full" text && contains ~affix:"100%" text);
  check bool "hidden draws fewer lines" true
    (List.length hidden < List.length shown)

(* #44071 review P3: the Trend line joins consecutive reported days and
   never crosses a gap; an above-limit day keeps its mark in the top row. *)
let test_trend_line_breaks_at_gaps_and_keeps_marks () =
  let point ~observed_at unit
      : Masc.Tui_decode_usage.provider_usage_history_point =
    { puhp_scope_id = "s1"
    ; puhp_kind = "five_hour"
    ; puhp_limit_id = None
    ; puhp_unit = unit
    ; puhp_observed_at = observed_at
    }
  in
  let generated_at = 1780000000.0 in
  let day = 86400.0 in
  let history : Masc.Tui_decode_usage.provider_usage_history =
    { puh_days = 5
    ; puh_generated_at = generated_at
    ; puh_unreadable_reports = 0
    ; puh_reported_no_windows = []
    ; puh_points =
        [ point ~observed_at:(generated_at -. (4. *. day))
            (Masc.Tui_decode_usage.Utilization_fraction 0.2)
        ; point ~observed_at:(generated_at -. (3. *. day))
            (Masc.Tui_decode_usage.Utilization_fraction 0.8)
        ; point ~observed_at:(generated_at -. day)
            (Masc.Tui_decode_usage.Utilization_fraction 0.0)
        ; point ~observed_at:generated_at
            (Masc.Tui_decode_usage.Utilization_percent 140)
        ]
    }
  in
  let trend =
    Masc_tui_usage_trend.of_history ~share:Providers.share_of_full history
  in
  let row = List.hd trend.rows in
  let width = 60 in
  let plot = Masc_tui_usage_trend.plot ~width trend row in
  check int "five bands, a baseline and dates" 7 (List.length plot);
  List.iter
    (fun line ->
      check bool "chart respects terminal cells" true
        (Masc_tui_message_layout.display_width line <= width))
    plot;
  let text = String.concat "\n" plot in
  check bool "the fixed full-limit axis is drawn" true
    (contains ~affix:"100%" text);
  check bool "the above-limit day keeps its mark" true
    (contains ~affix:"↑" text);
  (* A band row is an axis plus one 3-byte braille cell per day-slot column;
     the gap day's columns must carry no ink in any band. *)
  let blank = "\xe2\xa0\x80" in
  let cells_of_band row =
    match Astring.String.find_sub ~sub:"│ " row with
    | None -> failf "band row without an axis: %S" row
    | Some i ->
        let start = i + String.length "│ " in
        let cells = String.sub row start (String.length row - start) in
        if String.length cells mod 3 <> 0 then
          failf "band row is not whole cells: %S" row;
        List.init (String.length cells / 3) (fun cell ->
            String.sub cells (cell * 3) 3)
  in
  let bands = List.filter (contains ~affix:"│") plot in
  check int "five band rows" 5 (List.length bands);
  let days = List.length row.samples in
  let step = min 4 ((width - 7) / days) in
  let gap =
    let rec nth index = function
      | [] -> fail "fixture needs a gap day"
      | None :: _ -> index
      | Some _ :: rest -> nth (index + 1) rest
    in
    nth 0 row.samples
  in
  List.iter
    (fun band ->
      let cells = Array.of_list (cells_of_band band) in
      for k = 0 to step - 1 do
        check bool "a gap column carries no ink" true
          (String.equal cells.(gap * step + k) blank)
      done)
    bands;
  check bool "the line is drawn somewhere" true
    (List.exists
       (fun band ->
         List.exists
           (fun cell ->
             (not (String.equal cell blank)) && not (String.equal cell "↑"))
           (cells_of_band band))
       bands)

let () =
  run "tui_overview_providers"
    [ ( "providers"
      , [ test_case "out-of-range Plan history" `Quick test_plan_history_preserves_out_of_range_reports;
          test_case "unknown report evidence" `Quick test_plan_preserves_unknown_reports;
          test_case "an unread catalogue is not zero blocked" `Quick test_unread_catalogue_is_not_zero_blocked;
          test_case "one line per window and the account summary" `Quick test_section_draws_one_line_per_window
        ; test_case "unknown state is rejected" `Quick test_unknown_state_is_rejected
        ; test_case "history uses reported points" `Quick
            test_history_preserves_reported_days_and_units
        ; test_case "empty reports remain observed in the trend" `Quick test_empty_history_report_reaches_trend
        ; test_case "trend is built from the answer" `Quick
            test_trend_is_built_from_the_answer
        ; test_case "scope id is the server's" `Quick test_scope_id_is_the_servers
        ; test_case "USD rows preserve amounts without a fabricated meter" `Quick test_usd_rows_do_not_invent_a_percentage
        ; test_case "a silent account draws only its exhaustion" `Quick
            test_silent_account_draws_only_its_exhaustion
        ; test_case "meter width is bounded" `Quick test_meter_width_is_bounded
        ; test_case "reset clock follows local dates" `Quick
            test_reset_clock_follows_local_dates
        ; test_case "only a window heard at another time says so" `Quick
            test_only_a_window_heard_at_another_time_says_so
        ; test_case "a window that gates nothing is not an alarm" `Quick
            test_window_that_gates_nothing_is_not_an_alarm
        ; test_case "unknown role is rejected" `Quick test_unknown_role_is_rejected
        ; test_case "account emails name their accounts" `Quick
            test_account_emails_name_their_accounts
        ; test_case "plan splits accounts by window state" `Quick
            test_plan_splits_accounts_by_window_state
        ; test_case "unusable order is longest wait first" `Quick
            test_unusable_order_is_longest_wait_first
        ; test_case "ties go by account name" `Quick test_ties_go_by_account_name
        ; test_case "usable order is most used first" `Quick
            test_usable_order_is_most_used_first
        ; test_case "a full window that gates nothing is usable" `Quick
            test_a_full_window_that_gates_nothing_is_usable
        ; test_case "observed exhaustion blocks gating windows" `Quick
            test_observed_exhaustion_blocks_gating_windows
        ; test_case "an empty report is no report" `Quick test_an_empty_report_is_no_report
        ; test_case "every line fits the width" `Quick test_every_line_fits_the_width
        ; test_case "rows follow the plan" `Quick test_rows_follow_the_plan
        ; test_case "an account email is drawn once" `Quick test_an_account_email_is_drawn_once
        ; test_case "heard time is the account's, not the section's" `Quick
            test_heard_time_is_the_accounts_not_the_sections
        ; test_case "an amount past its cap is unusable" `Quick
            test_an_amount_past_its_cap_is_unusable
        ; test_case "a passed reset is unusable and last" `Quick
            test_a_passed_reset_is_still_unusable_and_last
        ; test_case "catalogue time does not replace a window's reset" `Quick
            test_catalogue_time_does_not_replace_a_windows_reset
        ; test_case "catalogue time orders accounts with no window" `Quick
            test_catalogue_time_orders_accounts_with_no_window
        ; test_case "the latest catalogue reopen time wins" `Quick
            test_the_latest_catalogue_reopen_time_wins
        ; test_case "an empty report can be observed exhausted" `Quick
            test_an_empty_report_can_be_observed_exhausted
        ; test_case "the observation is drawn once for a split account" `Quick
            test_the_observation_is_drawn_once_for_a_split_account
        ; test_case "the header counts are typed" `Quick test_the_header_counts_are_typed
        ; test_case "one window is one line down to 76 columns" `Quick
            test_one_window_is_one_line_down_to_76_columns
        ; test_case "the at-limit tone is the report's" `Quick
            test_the_at_limit_tone_is_the_reports_not_the_sections
        ; test_case "at limit is the header decision" `Quick
            test_at_limit_is_the_header_decision
        ; test_case "hidden unusable collapses to its heading" `Quick
            test_hidden_unusable_collapses_to_its_heading
        ; test_case "trend line breaks at gaps and keeps marks" `Quick
            test_trend_line_breaks_at_gaps_and_keeps_marks
        ] )
    ]
