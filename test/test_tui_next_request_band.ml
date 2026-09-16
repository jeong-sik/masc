(* The NEXT REQUEST band draws the server's forecast in tokens. A candidate
   with a measured density reads at that density, the exact ratio for its
   runtime, so the capacity of an 85k-token window reads back as 85k tokens;
   one without reads at the tab's scale. The band is rendered here through
   its own entry point with plain folding, so the assertions are about the
   sentences, not the pane. *)

module Inspector = Masc_tui_context_inspector
module Band = Masc_tui_next_request_band

let approx = "\xe2\x89\x88"
let minus = "\xe2\x88\x92"

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

(* lane-smith on 2026-09-15 at an 85k-token window: 3.30 bytes per token,
   280,500 bytes of capacity, 87,000 reserved and 237,000 pinned, so the
   history room is 43,500 bytes short and only the newest atom travels. *)
let measured : Inspector.forecast =
  { checkpoint_messages = 6012
  ; wake_line_bytes = 131
  ; candidates =
      [ { runtime_id = "ollama_cloud.deepseek-v4-1-flash"
        ; window = Inspector.Window_declared { window_tokens = 85_000; source = "declared" }
        ; capacity =
            Some
              (Inspector.Capacity_measured
                 { capacity_bytes = 280_500
                 ; density = { input_tokens = 100_000; measured_bytes = 330_000 }
                 })
        ; request_cap_bytes = Some 524_288
        ; parts =
            Ok
              { reserved_measured_on_turn = 3581
              ; reserved_bytes = 87_000
              ; pinned_measured_on_turn = 3579
              ; pinned_bytes = 237_000
              }
        ; history_atoms = 3395
        ; cut =
            Some
              (Inspector.Forecast_cut
                 { kept_atoms = 1
                 ; transmitted_bytes = 12_000
                 ; fit =
                     Inspector.Overrun
                       { by_bytes = 43_500; cause = Inspector.Fixed_parts_exceed_target }
                 })
        }
      ]
  }

let with_candidate f (forecast : Inspector.forecast) : Inspector.forecast =
  { forecast with candidates = List.map f forecast.candidates }

let test_the_band_reads_at_the_runtimes_density () =
  let rows = lines (Ok measured) in
  Alcotest.(check bool) "the window is named in tokens with its source" true
    (says "ollama_cloud.deepseek-v4-1-flash  \xc2\xb7  window 85.0k tok declared" rows);
  (* 280,500 bytes at 3.30 bytes per token is 85,000 tokens: the window. *)
  Alcotest.(check bool) "the capacity reads at the runtime's own density" true
    (says ("capacity " ^ approx ^ "85.0k tok at this runtime's 3.30 bytes per token") rows);
  (* 524,288 / 3.3 = 158,875. *)
  Alcotest.(check bool) "the provider's body cap reads at the same density" true
    (says ("provider accepts up to " ^ approx ^ "158.9k tok") rows);
  (* 87,000 / 3.3 = 26,364; 237,000 / 3.3 = 71,818. *)
  Alcotest.(check bool) "the fixed parts and the pinned blocks each carry the turn they were read from"
    true
    (says
       ("fixed parts " ^ approx ^ "26.4k tok (turn #3581) + pinned " ^ approx
      ^ "71.8k tok (turn #3579)")
       rows);
  (* (280,500 - 87,000 - 237,000) / 3.3 = -13,182. *)
  Alcotest.(check bool) "a negative room is drawn with a minus sign" true
    (says ("history room " ^ approx ^ minus ^ "13.2k tok") rows);
  (* 12,000 / 3.3 = 3,636; 43,500 / 3.3 = 13,182. *)
  Alcotest.(check bool) "the cut says how many atoms would go, at what size, and why it overruns"
    true
    (says ("1 of 3395 kept atoms would go (" ^ approx ^ "3.6k tok)") rows
     && says ("over the window by " ^ approx ^ "13.2k tok: the fixed parts alone exceed it") rows);
  Alcotest.(check bool) "the footer counts the checkpoint and the wake line" true
    (says "6012 messages in the checkpoint; the wake line adds 131 bytes as the newest atom" rows)

let test_the_newest_atom_overrun_is_named_as_such () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          cut =
            Some
              (Inspector.Forecast_cut
                 { kept_atoms = 1
                 ; transmitted_bytes = 300_000
                 ; fit =
                     Inspector.Overrun
                       { by_bytes = 19_500; cause = Inspector.Newest_atom_exceeds_target }
                 })
        })
      measured
  in
  Alcotest.(check bool) "the other overrun cause has its own sentence" true
    (says "the newest atom alone exceeds it" (lines (Ok forecast)))

let test_a_fitting_cut_says_so () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          parts =
            Ok
              { reserved_measured_on_turn = 3581
              ; reserved_bytes = 87_000
              ; pinned_measured_on_turn = 3579
              ; pinned_bytes = 20_000
              }
        ; cut =
            Some
              (Inspector.Forecast_cut
                 { kept_atoms = 120; transmitted_bytes = 170_000; fit = Inspector.Within_target })
        })
      measured
  in
  let rows = lines (Ok forecast) in
  (* (280,500 - 87,000 - 20,000) / 3.3 = 52,576. *)
  Alcotest.(check bool) "a positive room has no sign" true
    (says ("history room " ^ approx ^ "52.6k tok") rows);
  Alcotest.(check bool) "and the cut is within the window" true
    (says ("120 of 3395 kept atoms would go (" ^ approx ^ "51.5k tok)  \xc2\xb7  within the window") rows)

let test_an_unmeasured_runtime_reads_at_the_tabs_scale () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          capacity = Some Inspector.Capacity_unmeasured
        ; cut = Some (Inspector.Forecast_newest_atom_only { transmitted_bytes = 12_000 })
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "no density is said plainly" true
    (says "No response on this runtime since the server started, so no density" rows);
  Alcotest.(check bool) "the fixed parts still carry their turn, with no room to compute" true
    (says (approx ^ "25.7k tok (turn #3581) + pinned " ^ approx ^ "69.9k tok (turn #3579)") rows
     && not (says "history room" rows));
  (* 12,000 / 3.39 = 3,540: the fleet scale, not the runtime's. *)
  Alcotest.(check bool) "the cut is the newest atom, read at the fleet scale" true
    (says ("1 of 3395 kept atoms would go (" ^ approx ^ "3.5k tok)") rows)

let test_a_refused_window_is_drawn_with_its_reason () =
  let reason =
    "turn.context_window_tokens 85000 exceeds the 32000-token max-context of ollama.local"
  in
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          runtime_id = "ollama.local"
        ; window = Inspector.Window_refused reason
        ; capacity = None
        ; request_cap_bytes = None
        ; cut = None
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the runtime and the driver's refusal head the candidate" true
    (says ("ollama.local  \xc2\xb7  " ^ reason) rows);
  Alcotest.(check bool) "no capacity or cut is invented" false
    (says "capacity" rows || says "would go" rows)

let test_an_official_client_runtime_is_not_cut_and_says_why () =
  let reason =
    "claude_code.claude-sonnet-5 is an official-client runtime: the spawned client owns its \
     context window and masc applies no Agent Core cut"
  in
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          runtime_id = "claude_code.claude-sonnet-5"
        ; window = Inspector.Window_not_applicable reason
        ; capacity = None
        ; request_cap_bytes = None
        ; cut = None
        })
      measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the runtime heads the candidate and the reason follows in prose" true
    (says "claude_code.claude-sonnet-5" rows && says reason rows);
  Alcotest.(check bool) "the parts still read, with no room and no cut" true
    (says ("fixed parts " ^ approx ^ "25.7k tok (turn #3581)") rows
     && not (says "history room" rows) && not (says "would go" rows))

let test_a_refused_parts_reading_carries_the_servers_reason () =
  let reason =
    "the newest 200 turn records on this runtime carry only post-tool compositions \
     (newest turn #3648); the pinned blocks ride the first round only"
  in
  let forecast =
    with_candidate (fun candidate -> { candidate with parts = Error reason; cut = None }) measured
  in
  let rows = lines (Ok forecast) in
  Alcotest.(check bool) "the reason is the server's, and no cut is invented" true
    (says ("Fixed parts unknown, so no cut was computed: " ^ reason) rows
     && not (says "would go" rows))

let test_a_missing_forecast_is_named_not_hidden () =
  Alcotest.(check bool) "the band says why it is empty" true
    (says "Next request not forecast: next-request request failed: 404"
       (lines (Error "next-request request failed: 404")))

let test_the_forecast_decodes_the_servers_shape () =
  let json =
    Yojson.Safe.from_string
      {|{"dashboard_surface":"/api/v1/keepers/:name/next-request",
         "schema":"masc.keeper.next-request-forecast.v1","keeper":"lane-smith",
         "trace_id":"trace-1","checkpoint_messages":6012,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"ollama_cloud.deepseek-v4-1-flash",
           "window":{"window_tokens":85000,"declared_tokens":85000,"source":"declared"},
           "capacity":{"window_tokens":85000,"capacity_bytes":280500,
                       "density_input_tokens":100000,"density_measured_bytes":330000},
           "request_cap_bytes":524288,
           "parts":{"reserved_measured_on_turn":3581,"reserved_bytes":87000,
                    "pinned_measured_on_turn":3579,"pinned_bytes":237000},
           "history_atoms":3395,
           "cut":{"kind":"cut","kept_atoms":1,"transmitted_bytes":12000,
                  "fit":{"kind":"overrun","by_bytes":43500,"cause":"fixed_parts_exceed_target"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("the server's shape decodes: " ^ detail)
  | Ok forecast ->
    Alcotest.(check bool) "every field lands where the band reads it" true
      (forecast = measured)

let test_an_unmeasured_capacity_decodes_from_a_null_byte_count () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v1","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"r","window":{"window_tokens":85000,"declared_tokens":85000,"source":"declared"},
           "capacity":{"window_tokens":85000,"capacity_bytes":null},"request_cap_bytes":null,
           "parts":{"error":"no turn record on this runtime carried a composition in the newest 200 records"},
           "history_atoms":1,"cut":{"kind":"newest_atom_only","kept_atoms":1,"transmitted_bytes":300}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("a null capacity decodes: " ^ detail)
  | Ok
      { candidates =
          [ { capacity = Some Inspector.Capacity_unmeasured
            ; cut = Some (Inspector.Forecast_newest_atom_only { transmitted_bytes = 300 })
            ; parts = Error "no turn record on this runtime carried a composition in the newest 200 records"
            ; request_cap_bytes = None
            ; _
            }
          ]
      ; _
      } -> ()
  | Ok _ ->
    Alcotest.fail "a null capacity_bytes reads as unmeasured and the cut as the newest atom"

let test_a_refused_window_decodes_from_the_error_shape () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v1","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"r","window":{"error":"runtime r resolves no context window"},
           "capacity":null,"request_cap_bytes":null,"parts":{"error":"no turn record on this runtime carried a composition in the newest 200 records"},"history_atoms":1,"cut":null}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok { candidates = [ { window = Inspector.Window_refused reason; capacity = None; cut = None; _ } ]; _ }
    ->
    Alcotest.(check string) "the reason is the server's" "runtime r resolves no context window" reason
  | Ok _ -> Alcotest.fail "an error window reads as refused with nothing derived from it"
  | Error detail -> Alcotest.fail ("the error shape decodes: " ^ detail)

let test_a_not_applicable_window_decodes_as_such () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v1","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"claude_code.claude-sonnet-5",
           "window":{"not_applicable":"claude_code.claude-sonnet-5 is an official-client runtime"},
           "capacity":null,"request_cap_bytes":null,
           "parts":{"reserved_measured_on_turn":4700,"reserved_bytes":194651,"pinned_measured_on_turn":4700,"pinned_bytes":182167},
           "history_atoms":4429,"cut":null}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok { candidates = [ { window = Inspector.Window_not_applicable reason; capacity = None; cut = None; parts = Ok parts; _ } ]; _ }
    ->
    Alcotest.(check string) "the reason is the server's"
      "claude_code.claude-sonnet-5 is an official-client runtime" reason;
    Alcotest.(check int) "and the parts still decode" 182_167 parts.Inspector.pinned_bytes
  | Ok _ -> Alcotest.fail "a not_applicable window reads as such, with nothing derived from it"
  | Error detail -> Alcotest.fail ("the not_applicable shape decodes: " ^ detail)

let test_a_malformed_forecast_fails_the_reading () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v1","checkpoint_messages":1,"wake_line_bytes":131,
         "candidates":[{"runtime_id":"r","window":{"window_tokens":85000,"declared_tokens":85000,"source":"declared"},
           "capacity":null,"request_cap_bytes":null,"parts":{"error":"x"},"history_atoms":1,
           "cut":{"kind":"sideways","kept_atoms":1,"transmitted_bytes":300}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown cut kind is refused, not read as absent"

let () =
  Alcotest.run "tui_next_request_band"
    [ ( "render"
      , [ Alcotest.test_case "the band reads at the runtime's density" `Quick
            test_the_band_reads_at_the_runtimes_density
        ; Alcotest.test_case "the newest-atom overrun is named as such" `Quick
            test_the_newest_atom_overrun_is_named_as_such
        ; Alcotest.test_case "a fitting cut says so" `Quick test_a_fitting_cut_says_so
        ; Alcotest.test_case "an unmeasured runtime reads at the tab's scale" `Quick
            test_an_unmeasured_runtime_reads_at_the_tabs_scale
        ; Alcotest.test_case "a refused window is drawn with its reason" `Quick
            test_a_refused_window_is_drawn_with_its_reason
        ; Alcotest.test_case "an official-client runtime is not cut and says why" `Quick
            test_an_official_client_runtime_is_not_cut_and_says_why
        ; Alcotest.test_case "a refused parts reading carries the server's reason" `Quick
            test_a_refused_parts_reading_carries_the_servers_reason
        ; Alcotest.test_case "a missing forecast is named, not hidden" `Quick
            test_a_missing_forecast_is_named_not_hidden
        ] )
    ; ( "decode"
      , [ Alcotest.test_case "the forecast decodes the server's shape" `Quick
            test_the_forecast_decodes_the_servers_shape
        ; Alcotest.test_case "an unmeasured capacity decodes from a null byte count" `Quick
            test_an_unmeasured_capacity_decodes_from_a_null_byte_count
        ; Alcotest.test_case "a refused window decodes from the error shape" `Quick
            test_a_refused_window_decodes_from_the_error_shape
        ; Alcotest.test_case "a not-applicable window decodes as such" `Quick
            test_a_not_applicable_window_decodes_as_such
        ; Alcotest.test_case "a malformed forecast fails the reading" `Quick
            test_a_malformed_forecast_fails_the_reading
        ] )
    ]
