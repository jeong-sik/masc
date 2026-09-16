(* The NEXT REQUEST band draws the server's forecast in tokens at the tab's
   scale: the carried range from the pair's front, the marks it is judged
   against, and what the provider last counted. The band is rendered here
   through its own entry point with plain folding, so the assertions are
   about the sentences, not the pane. *)

module Inspector = Masc_tui_context_inspector
module Band = Masc_tui_next_request_band

let approx = "\xe2\x89\x88"

(* Terminal control sequences out, so a needle can cross a colour change. *)
let strip line =
  let buffer = Buffer.create (String.length line) in
  let rec go i =
    if i >= String.length line then ()
    else if line.[i] = '\027' then skip (i + 1)
    else (
      Buffer.add_char buffer line.[i];
      go (i + 1))
  and skip i =
    if i >= String.length line then ()
    else if line.[i] = 'm' then go (i + 1)
    else skip (i + 1)
  in
  go 0;
  Buffer.contents buffer

let contains needle line =
  let n = String.length needle and l = String.length line in
  let rec at i = i + n <= l && (String.sub line i n = needle || at (i + 1)) in
  at 0

let text rows = String.concat " " (List.map strip rows)
let says needle rows = contains needle (text rows)

let lines ?(scale = Masc_tui_token_scale.fleet) forecast =
  Band.lines
    ~prose:(fun sentence -> [ "  " ^ sentence ])
    ~fact:(fun row -> [ "  " ^ row ])
    ~safe:Fun.id
    ~scale
    forecast

(* lane-smith on a deepseek binding with marks 120k/80k: the ledger's front
   sits at atom 3,100 of 3,395, the last count was 91k tokens. *)
let measured : Inspector.forecast =
  { checkpoint_messages = 6012
  ; wake_line_bytes = 131
  ; candidates =
      [ { runtime_id = "ollama_cloud.deepseek-v4-1-flash"
        ; lane = Inspector.Lane_agent_core
        ; marks = Some { high_water_tokens = 120_000; low_water_tokens = 80_000 }
        ; request_cap_bytes = Some 524_288
        ; parts =
            Ok
              { reserved_measured_on_turn = 3581
              ; reserved_bytes = 87_000
              ; pinned_measured_on_turn = 3579
              ; pinned_measured_on_runtime = "ollama_cloud.deepseek-v4-1-flash"
              ; pinned_bytes = 237_000
              }
        ; history_atoms = 3395
        ; carried =
            Some
              { first_atom = 3100
              ; kept_atoms = 295
              ; transmitted_bytes = 170_000
              ; origin = Inspector.Carried_from_ledger
              ; counted_tokens = Some 91_000
              }
        }
      ]
  }

let with_candidate f (forecast : Inspector.forecast) : Inspector.forecast =
  { forecast with candidates = List.map f forecast.candidates }

let test_the_band_names_the_marks_and_the_range () =
  let rows = lines (Ok measured) in
  Alcotest.(check bool) "the marks are named in tokens" true
    (says "ollama_cloud.deepseek-v4-1-flash  \xc2\xb7  marks 120.0k / 80.0k tok" rows);
  (* 524,288 / 3.39 = 154,657: the fleet scale. *)
  Alcotest.(check bool) "the provider's body cap reads at the tab's scale" true
    (says ("provider accepts up to " ^ approx ^ "154.7k tok") rows);
  (* 87,000 / 3.39 = 25,664; 237,000 / 3.39 = 69,912. *)
  Alcotest.(check bool) "the fixed parts and the pinned blocks each carry the turn they were read from"
    true
    (says
       ("fixed parts " ^ approx ^ "25.7k tok (turn #3581) + pinned " ^ approx
      ^ "69.9k tok (turn #3579)")
       rows);
  (* 170,000 / 3.39 = 50,147. *)
  Alcotest.(check bool) "the range says how many atoms go, from where, and where the front came from"
    true
    (says ("295 of 3395 atoms would go, from atom 3100 (" ^ approx ^ "50.1k tok)") rows
     && says "front from this runtime's ledger" rows);
  Alcotest.(check bool) "the last count is read against the marks" true
    (says "last counted 91.0k tok against marks 120.0k / 80.0k" rows);
  Alcotest.(check bool) "the footer counts the checkpoint and the wake line" true
    (says "6012 messages in the checkpoint; the wake line adds 131 bytes as the newest atom" rows)

let test_a_pinned_figure_from_another_lane_names_it () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          parts =
            Ok
              { reserved_measured_on_turn = 4032
              ; reserved_bytes = 82_410
              ; pinned_measured_on_turn = 4033
              ; pinned_measured_on_runtime = "claude_code.claude-sonnet-5"
              ; pinned_bytes = 140_706
              }
        })
      measured
  in
  Alcotest.(check bool) "the lane rides beside the turn" true
    (says "(turn #4033 on claude_code.claude-sonnet-5)" (lines (Ok forecast)))

let test_no_marks_says_only_a_refusal_moves_the_front () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          marks = None
        ; carried =
            Option.map
              (fun (c : Inspector.forecast_carried) -> { c with counted_tokens = Some 91_000 })
              candidate.carried
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the head says so" true
    (says "no marks declared: only a refusal moves the front" rows);
  Alcotest.(check bool) "the count stands alone" true
    (says "last counted 91.0k tok" rows && not (says "against marks" rows))

let test_a_cold_front_names_its_record_and_nothing_counted () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          carried =
            Some
              { first_atom = 3000
              ; kept_atoms = 395
              ; transmitted_bytes = 200_000
              ; origin = Inspector.Carried_from_turn_record { turn = 3581 }
              ; counted_tokens = None
              }
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the record's turn is named" true
    (says "front from turn #3581's record; nothing counted since the server started" rows);
  Alcotest.(check bool) "no count line" false (says "last counted" rows)

let test_a_cap_fit_and_the_whole_history_say_why () =
  let with_origin origin =
    lines
      (Ok
         (with_candidate
            (fun candidate ->
              { candidate with
                carried =
                  Option.map
                    (fun (c : Inspector.forecast_carried) -> { c with origin; counted_tokens = None })
                    candidate.carried
              })
            measured))
  in
  Alcotest.(check bool) "the cap fit" true
    (says "the newest suffix the request cap admits" (with_origin Inspector.Carried_fit_to_request_cap));
  Alcotest.(check bool) "the whole history" true
    (says "no front to start from and no cap: the whole history" (with_origin Inspector.Carried_whole_history));
  Alcotest.(check bool) "a halved front" true
    (says "front halved after a refusal (retry 2)"
       (with_origin (Inspector.Carried_halved_after_refusal { retry = 2 })))

let test_no_range_without_the_fixed_parts_is_said () =
  let reason = "no completed turn on this runtime carried a composition in the newest 200 records" in
  let forecast =
    with_candidate
      (fun candidate -> { candidate with parts = Error reason; carried = None })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the parts refusal carries the server's reason" true
    (says ("Fixed parts unknown: " ^ reason) rows);
  Alcotest.(check bool) "and the missing range says why" true
    (says "no range was computed" rows)

let test_an_official_client_runtime_carries_no_range_and_says_why () =
  let reason =
    "claude_code.claude-sonnet-5 is an official-client runtime: the spawned client owns its context and masc carries no range for it"
  in
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          runtime_id = "claude_code.claude-sonnet-5"
        ; lane = Inspector.Lane_not_applicable reason
        ; marks = None
        ; request_cap_bytes = None
        ; carried = None
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the reason is drawn" true (says reason rows);
  Alcotest.(check bool) "no range line" false (says "atoms would go" rows || says "no range was computed" rows)

let test_a_missing_forecast_is_named_not_hidden () =
  Alcotest.(check bool) "the band says why it is empty" true
    (says "Next request not forecast: next-request request failed: 404"
       (lines (Error "next-request request failed: 404")))

let test_the_forecast_decodes_the_servers_shape () =
  let json =
    Yojson.Safe.from_string
      {|{"dashboard_surface":"/api/v1/keepers/:name/next-request",
         "schema":"masc.keeper.next-request-forecast.v2","keeper":"lane-smith",
         "trace_id":"trace-1","checkpoint_messages":6012,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"ollama_cloud.deepseek-v4-1-flash",
           "lane":{"agent_core":true},
           "marks":{"high_water_tokens":120000,"low_water_tokens":80000},
           "request_cap_bytes":524288,
           "parts":{"reserved_measured_on_turn":3581,"reserved_bytes":87000,
                    "pinned_measured_on_turn":3579,"pinned_measured_on_runtime":"ollama_cloud.deepseek-v4-1-flash",
                    "pinned_bytes":237000},
           "history_atoms":3395,
           "carried":{"first_atom":3100,"kept_atoms":295,"transmitted_bytes":170000,
                      "origin":{"kind":"ledger"},"counted_tokens":91000}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("the server's shape decodes: " ^ detail)
  | Ok forecast ->
    Alcotest.(check bool) "every field lands where the band reads it" true
      (forecast = measured)

let test_null_marks_count_and_a_record_origin_decode () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v2","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,"request_cap_bytes":null,
           "parts":{"error":"no completed turn on this runtime carried a composition in the newest 200 records"},
           "history_atoms":1,
           "carried":{"first_atom":0,"kept_atoms":1,"transmitted_bytes":300,
                      "origin":{"kind":"turn_record","turn":41},"counted_tokens":null}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("null marks decode: " ^ detail)
  | Ok
      { candidates =
          [ { marks = None
            ; carried =
                Some
                  { origin = Inspector.Carried_from_turn_record { turn = 41 }
                  ; counted_tokens = None
                  ; kept_atoms = 1
                  ; _
                  }
            ; parts = Error "no completed turn on this runtime carried a composition in the newest 200 records"
            ; request_cap_bytes = None
            ; _
            }
          ]
      ; _
      } -> ()
  | Ok _ -> Alcotest.fail "null marks read as none, the origin as the record's turn"

let test_a_not_applicable_lane_decodes_as_such () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v2","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"claude_code.claude-sonnet-5",
           "lane":{"not_applicable":"claude_code.claude-sonnet-5 is an official-client runtime"},
           "marks":null,"request_cap_bytes":null,
           "parts":{"reserved_measured_on_turn":4700,"reserved_bytes":194651,"pinned_measured_on_turn":4700,"pinned_measured_on_runtime":"claude_code.claude-sonnet-5","pinned_bytes":182167},
           "history_atoms":4429,"carried":null}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok { candidates = [ { lane = Inspector.Lane_not_applicable reason; carried = None; parts = Ok parts; _ } ]; _ }
    ->
    Alcotest.(check string) "the reason is the server's"
      "claude_code.claude-sonnet-5 is an official-client runtime" reason;
    Alcotest.(check int) "and the parts still decode" 182_167 parts.Inspector.pinned_bytes
  | Ok _ -> Alcotest.fail "a not_applicable lane reads as such, with nothing derived from it"
  | Error detail -> Alcotest.fail ("the not_applicable shape decodes: " ^ detail)

let test_a_malformed_forecast_fails_the_reading () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v2","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,"request_cap_bytes":null,
           "parts":{"error":"x"},"history_atoms":1,
           "carried":{"first_atom":0,"kept_atoms":1,"transmitted_bytes":300,"origin":{"kind":"sideways"},"counted_tokens":null}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown origin kind is refused, not read as absent"

let test_the_old_schema_is_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v1","checkpoint_messages":1,"wake_line_bytes":131,"candidates":[]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a server on the previous shape is named, not half-read"

let () =
  Alcotest.run "tui_next_request_band"
    [ ( "render"
      , [ Alcotest.test_case "the band names the marks and the range" `Quick
            test_the_band_names_the_marks_and_the_range
        ; Alcotest.test_case "a pinned figure from another lane names it" `Quick
            test_a_pinned_figure_from_another_lane_names_it
        ; Alcotest.test_case "no marks says only a refusal moves the front" `Quick
            test_no_marks_says_only_a_refusal_moves_the_front
        ; Alcotest.test_case "a cold front names its record and nothing counted" `Quick
            test_a_cold_front_names_its_record_and_nothing_counted
        ; Alcotest.test_case "a cap fit and the whole history say why" `Quick
            test_a_cap_fit_and_the_whole_history_say_why
        ; Alcotest.test_case "no range without the fixed parts is said" `Quick
            test_no_range_without_the_fixed_parts_is_said
        ; Alcotest.test_case "an official-client runtime carries no range and says why" `Quick
            test_an_official_client_runtime_carries_no_range_and_says_why
        ; Alcotest.test_case "a missing forecast is named, not hidden" `Quick
            test_a_missing_forecast_is_named_not_hidden
        ] )
    ; ( "decode"
      , [ Alcotest.test_case "the forecast decodes the server's shape" `Quick
            test_the_forecast_decodes_the_servers_shape
        ; Alcotest.test_case "null marks, count and a record origin decode" `Quick
            test_null_marks_count_and_a_record_origin_decode
        ; Alcotest.test_case "a not-applicable lane decodes as such" `Quick
            test_a_not_applicable_lane_decodes_as_such
        ; Alcotest.test_case "a malformed forecast fails the reading" `Quick
            test_a_malformed_forecast_fails_the_reading
        ; Alcotest.test_case "the old schema is refused" `Quick test_the_old_schema_is_refused
        ] )
    ]
