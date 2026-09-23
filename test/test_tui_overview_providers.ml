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
   ollama_cloud: nothing heard since the server started. *)
let resolved state_word =
  Yojson.Safe.from_string
    (Printf.sprintf
       {|{
  "provider_usage_windows_since": 1790179140.2,
  "provider_usage_windows": [
    { "scope": "provider:codex", "providers": ["codex"],
      "state": "not_reported_since_start", "windows": [] },
    { "scope": "provider:kimi", "providers": ["kimi"], "state": "reported",
      "windows": [
        { "limit_id": null, "window": {"kind": "duration_minutes", "minutes": 300},
          "utilization": {"unit": "percent", "value": 100},
          "resets_at": 1790179580, "observed_at": 1790170000.0,
          "source": "codex.account_rate_limits_updated" } ] },
    { "scope": "provider:claude_code", "providers": ["claude_code"], "state": %S,
      "windows": [
        { "limit_id": null, "window": {"kind": "five_hour"},
          "utilization": {"unit": "fraction", "value": 0.67},
          "resets_at": 1790195300, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" },
        { "limit_id": null, "window": {"kind": "seven_day"},
          "utilization": {"unit": "fraction", "value": 0.44},
          "resets_at": 1790700000, "observed_at": 1790180000.0,
          "source": "claude_code.rate_limit_event" } ] },
    { "scope": "provider:ollama_cloud", "providers": ["ollama_cloud"],
      "state": "not_reported_since_start", "windows": [] }
  ]
}|}
       state_word)

let runtime ~scope ~exhausted id : Tui_decode.runtime_option =
  { ro_id = id
  ; ro_provider = "p"
  ; ro_model = id
  ; ro_effective_max_context = 200_000
  ; ro_max_context_source = Tui_decode.Runtime_context_capability
  ; ro_max_output_tokens = None
  ; ro_declared_reasoning_effort = None
  ; ro_is_local = false
  ; ro_is_default = false
  ; ro_quota_exhausted = exhausted
  ; ro_quota_resets_at = None
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

let width = 120

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
      [ runtime ~scope:"provider:kimi" ~exhausted:true "kimi.k3"
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
  check bool "title says whose numbers and since when" true
    (contains ~affix:"reported by the provider" (plain section.title)
     && contains ~affix:"since server start" (plain section.title));
  match lines with
  | [ five_hour; seven_day; kimi; codex; ollama ] ->
      (* A reported account: meter, value in its own unit, countdown, age. *)
      check bool "claude 5h row" true
        (contains ~affix:"claude_code" five_hour
         && contains ~affix:"5h" five_hour
         && contains ~affix:"0.67" five_hour
         && contains ~affix:"\xe2\x86\xbb " five_hour
         && contains ~affix:" in 4h12m" five_hour
         && contains ~affix:"heard 3m ago" five_hour);
      check bool "claude 7d row: same report, no second age" true
        (contains ~affix:"7d" seven_day
         && contains ~affix:"0.44" seven_day
         && (not (contains ~affix:"heard" seven_day))
         && not (contains ~affix:"claude_code" seven_day));
      let meter, cells = meter_of five_hour in
      check string "the row's meter is the eighth-block meter at 0.67" meter
        (Providers.meter ~cells 0.67);
      (* A passed reset keeps the last value and says so. *)
      check bool "kimi: passed reset, full meter, observed tag" true
        (contains ~affix:"reset time passed \xc2\xb7 no newer report" kimi
         && contains ~affix:"100%" kimi
         && contains ~affix:"5h" kimi
         && contains ~affix:"exhausted (observed)" kimi);
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
             && contains ~affix:"no report since server start" row
             && not (contains ~affix:meter_open row)))
        [ ("codex", codex); ("ollama_cloud", ollama) ]
  | _ -> failf "expected five rows, got %d" (List.length lines)

let test_meter_uses_eighth_blocks () =
  check string "0.67 of 16 cells is 10 whole cells and six eighths"
    "\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x88\xe2\x96\x8a     "
    (Providers.meter ~cells:16 0.67);
  check string "past full draws full, not wider" "\xe2\x96\x88\xe2\x96\x88"
    (Providers.meter ~cells:2 1.4)

let test_failed_read_is_one_line () =
  match
    Providers.section ~providers:(Types.Providers_failed "connection refused")
      ~runtimes:Types.Quota_unread ~now ~width:80
  with
  | Some section ->
      check (list string) "one explicit line"
        [ " providers unavailable: connection refused" ]
        (List.map plain section.lines)
  | None -> fail "a failed read is drawn"

let test_unknown_state_is_rejected () =
  check bool "an unknown state fails the reading" true
    (Result.is_error
       (Tui_decode.decode_provider_usage_windows (resolved "paused")))

let () =
  run "tui_overview_providers"
    [ ( "providers"
      , [ test_case "three line shapes" `Quick test_section_draws_three_line_shapes
        ; test_case "eighth-block meter" `Quick test_meter_uses_eighth_blocks
        ; test_case "failed read is one line" `Quick test_failed_read_is_one_line
        ; test_case "unknown state is rejected" `Quick test_unknown_state_is_rejected
        ] )
    ]
