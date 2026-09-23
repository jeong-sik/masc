(* The NEXT REQUEST band draws the server's forecast in tokens at the tab's
   scale: the carried range from the pair's front, the marks it is judged
   against, what the provider last counted, and the parts in the order the
   request carries them. The band is rendered here through its own entry
   point with plain folding, so the assertions are about the sentences, not
   the pane. *)

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
        ; assembly = None
        ; place = { walks_at = 0; declared_at = Some 0; rest = Inspector.Rest_serving }
        }
      ]
  ; walk =
      Ok
        { lane_id = "ollama_cloud.deepseek-v4-1-flash"
        ; declared = [ "ollama_cloud.deepseek-v4-1-flash" ]
        }
  }

(* lane-smith at turn 3660: six history atoms ride between the fixed parts
   and the pinned blocks. *)
let assembled : Inspector.forecast_slot list =
  [ Inspector.Slot_system_prompt { bytes = 10_832 }
  ; Inspector.Slot_tools { bytes = 71_578 }
  ; Inspector.Slot_history { atoms = 6; of_atoms = 4318; bytes = 56_909 }
  ; Inspector.Slot_wake_line { bytes = 191 }
  ; Inspector.Slot_system_context
      { bytes = 157_541
      ; blocks =
          [ "skill_compositions", 321
          ; "memory_os_recall", 139_966
          ; "dynamic_context", 17_218
          ; "temporal_summary", 36
          ]
      }
  ]

let with_candidate f (forecast : Inspector.forecast) : Inspector.forecast =
  { forecast with candidates = List.map f forecast.candidates }

let test_the_band_names_the_marks_and_the_range () =
  let rows = lines (Ok measured) in
  Alcotest.(check bool) "the marks are named in tokens" true
    (says "ollama_cloud.deepseek-v4-1-flash  \xc2\xb7  marks 120.0k / 80.0k tok" rows);
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
  (* 131 / 3.39 = 38.6: the wake line is named in the same estimated tokens as
     every other figure of the band, never in bytes beside them. *)
  Alcotest.(check bool) "the footer counts the checkpoint and the wake line in tokens" true
    (says ("6012 messages in the checkpoint; the wake line adds " ^ approx ^ "39 tok as the newest atom") rows)

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

let test_the_assembly_is_drawn_in_travel_order () =
  let forecast =
    with_candidate (fun candidate -> { candidate with assembly = Some assembled }) measured
  in
  let rows = lines (Ok forecast) in
  let position needle =
    let rec go index = function
      | [] -> None
      | row :: rest -> if contains needle (strip row) then Some index else go (index + 1) rest
    in
    go 0 rows
  in
  (* 10,832 / 3.39 = 3,195; 71,578 / 3.39 = 21,114; 56,909 / 3.39 = 16,787;
     191 / 3.39 = 56; 157,541 / 3.39 = 46,472. The label column is sixteen
     cells and the figure is right-aligned in eight bytes. *)
  Alcotest.(check bool) "each slot is numbered with its share in tokens" true
    (says ("1  system prompt     " ^ approx ^ "3.2k tok") rows
     && says ("2  tools            " ^ approx ^ "21.1k tok") rows
     && says ("3  history          " ^ approx ^ "16.8k tok") rows
     && says "6 of 4318 atoms, oldest first" rows
     && says ("4  wake line           " ^ approx ^ "56 tok") rows
     && says ("5  [system context] " ^ approx ^ "46.5k tok") rows);
  (* 321 / 3.39 = 95; 139,966 / 3.39 = 41,288; 17,218 / 3.39 = 5,079; 36 / 3.39 = 11. *)
  Alcotest.(check bool) "the context names its blocks in assembly order" true
    (says
       ("skill_compositions " ^ approx ^ "95  \xc2\xb7  memory_os_recall " ^ approx
      ^ "41.3k  \xc2\xb7  dynamic_context " ^ approx ^ "5.1k  \xc2\xb7  temporal_summary " ^ approx
      ^ "11")
       rows);
  Alcotest.(check bool) "and the rows stand in that order on the screen" true
    (match position "1  system prompt", position "5  [system context]" with
     | Some first, Some last -> first < last
     | _ -> false)

let test_a_preamble_slot_is_named_when_the_range_prepended_one () =
  let forecast =
    with_candidate
      (fun candidate ->
        { candidate with
          assembly =
            Some
              (Inspector.Slot_system_prompt { bytes = 10_832 }
               :: Inspector.Slot_tools { bytes = 71_578 }
               :: Inspector.Slot_preamble { bytes = 260 }
               :: List.filteri (fun index _ -> index >= 2) assembled)
        })
      measured
  in
  (* 260 / 3.39 = 77. *)
  Alcotest.(check bool) "the preamble takes the third row" true
    (says ("3  [context window]    " ^ approx ^ "77 tok  \xc2\xb7  says older turns are omitted")
       (lines (Ok forecast)))

let test_no_assembly_draws_no_order () =
  Alcotest.(check bool) "without a layout there is no order to draw" false
    (says "In the order the request carries them" (lines (Ok measured)))

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

let test_the_turn_start_and_refusal_fronts_say_why () =
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
  let turn_start = with_origin (Inspector.Carried_turn_start { end_atom = 3577 }) in
  Alcotest.(check bool) "the turn start names the boundary" true
    (says "no front to start from: this turn's own atoms; the last completed turn ended at atom 3577"
       turn_start);
  Alcotest.(check bool) "an unknown turn start" true
    (says "no front, and where this turn began could not be read: the newest atom alone (boundary read failed: fixture)"
       (with_origin (Inspector.Carried_turn_start_unknown { reason = "boundary read failed: fixture" })));
  Alcotest.(check bool) "and the range's own first atom stays on the fact line" true
    (says "from atom 3100" turn_start);
  Alcotest.(check bool) "a halved front" true
    (says "front halved after a refusal (retry 2)"
       (with_origin (Inspector.Carried_halved_after_refusal { retry = 2 })));
  Alcotest.(check bool) "an evicted front" true
    (says "front evicted after a refusal (retry 3)"
       (with_origin (Inspector.Carried_evicted_after_refusal { retry = 3 })));
  Alcotest.(check bool) "a refused seed range" true
    (says "the seed range was refused: front moved to where this turn began"
       (with_origin Inspector.Carried_turn_start_after_seed_refusal))

let test_a_refused_seed_origin_decodes () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"not measured"},"history_atoms":4,
           "carried":{"first_atom":2,"kept_atoms":2,"transmitted_bytes":300,"preamble_bytes":null,
                      "origin":{"kind":"turn_start_after_seed_refusal"},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok
      { candidates =
          [ { carried = Some { origin = Inspector.Carried_turn_start_after_seed_refusal; _ }
            ; _
            }
          ]
      ; _
      } -> ()
  | Ok _ -> Alcotest.fail "the refused seed origin decoded as another origin"
  | Error detail -> Alcotest.fail ("the refused seed origin decodes: " ^ detail)

let test_an_evicted_refusal_origin_decodes () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"not measured"},"history_atoms":4,
           "carried":{"first_atom":2,"kept_atoms":2,"transmitted_bytes":300,"preamble_bytes":null,
                      "origin":{"kind":"evicted_after_refusal","retry":3},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok
      { candidates =
          [ { carried = Some { origin = Inspector.Carried_evicted_after_refusal { retry = 3 }; _ }
            ; _
            }
          ]
      ; _
      } -> ()
  | Ok _ -> Alcotest.fail "the eviction origin lost its retry"
  | Error detail -> Alcotest.fail ("the eviction origin decodes: " ^ detail)

let test_a_turn_start_origin_decodes () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"not measured"},"history_atoms":4,
           "carried":{"first_atom":2,"kept_atoms":2,"transmitted_bytes":300,"preamble_bytes":null,
                      "origin":{"kind":"turn_start","end_atom":2},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  (match Inspector.decode_forecast json with
   | Ok
       { candidates =
           [ { carried = Some { origin = Inspector.Carried_turn_start { end_atom = 2 }; _ }
             ; _
             }
           ]
       ; _
       } -> ()
   | Ok _ -> Alcotest.fail "the turn start origin lost its atom"
   | Error detail -> Alcotest.fail ("the turn start origin decodes: " ^ detail));
  let unknown =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"not measured"},"history_atoms":4,
           "carried":{"first_atom":3,"kept_atoms":1,"transmitted_bytes":300,"preamble_bytes":null,
                      "origin":{"kind":"turn_start_unknown","reason":"boundary read failed: fixture"},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  (match Inspector.decode_forecast unknown with
   | Ok
       { candidates =
           [ { carried = Some { origin = Inspector.Carried_turn_start_unknown { reason }; _ }; _ } ]
       ; _
       }
     when String.equal reason "boundary read failed: fixture" -> ()
   | Ok _ -> Alcotest.fail "the unknown turn start origin lost its reason"
   | Error detail -> Alcotest.fail ("the unknown turn start origin decodes: " ^ detail));
  let without_atom =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"not measured"},"history_atoms":4,
           "carried":{"first_atom":2,"kept_atoms":2,"transmitted_bytes":300,"preamble_bytes":null,
                      "origin":{"kind":"whole_history"},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  Alcotest.(check bool) "the removed kind is not a known origin" true
    (Result.is_error (Inspector.decode_forecast without_atom))

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
         "schema":"masc.keeper.next-request-forecast.v5","keeper":"lane-smith",
         "trace_id":"trace-1","checkpoint_messages":6012,"wake_line_bytes":131,
         "walk":{"lane_id":"ollama_cloud.deepseek-v4-1-flash","declared":["ollama_cloud.deepseek-v4-1-flash"]},
         "candidates":[{"runtime_id":"ollama_cloud.deepseek-v4-1-flash",
           "lane":{"agent_core":true},
           "marks":{"high_water_tokens":120000,"low_water_tokens":80000},
           "parts":{"reserved_measured_on_turn":3581,"reserved_bytes":87000,
                    "instructions_bytes":10832,"schemas_bytes":76168,
                    "pinned_measured_on_turn":3579,"pinned_measured_on_runtime":"ollama_cloud.deepseek-v4-1-flash",
                    "pinned_bytes":237000,"pinned_blocks":[{"block":"memory_os_recall","bytes":237000}]},
           "history_atoms":3395,
           "carried":{"first_atom":3100,"kept_atoms":295,"transmitted_bytes":170000,"preamble_bytes":null,
                      "origin":{"kind":"ledger"},"counted_tokens":91000},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("the server's shape decodes: " ^ detail)
  | Ok forecast ->
    Alcotest.(check bool) "every field lands where the band reads it" true
      (forecast = measured)

let test_null_marks_count_a_record_origin_and_a_layout_decode () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":131,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"no completed turn on this runtime carried a composition in the newest 200 records"},
           "history_atoms":1,
           "carried":{"first_atom":0,"kept_atoms":1,"transmitted_bytes":300,"preamble_bytes":260,
                      "origin":{"kind":"turn_record","turn":41},"counted_tokens":null},
           "assembly":[{"slot":"system_prompt","bytes":10832},{"slot":"tools","bytes":71578},
                       {"slot":"preamble","bytes":260},
                       {"slot":"history","atoms":0,"of_atoms":0,"bytes":0},{"slot":"wake_line","bytes":191},
                       {"slot":"system_context","bytes":157541,"blocks":[{"block":"memory_os_recall","bytes":139966}]}],
           "place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
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
            ; assembly = Some slots
            ; _
            }
          ]
      ; _
      } ->
    Alcotest.(check bool) "the layout decodes slot by slot" true
      (slots
       = [ Inspector.Slot_system_prompt { bytes = 10_832 }
         ; Inspector.Slot_tools { bytes = 71_578 }
         ; Inspector.Slot_preamble { bytes = 260 }
         ; Inspector.Slot_history { atoms = 0; of_atoms = 0; bytes = 0 }
         ; Inspector.Slot_wake_line { bytes = 191 }
         ; Inspector.Slot_system_context
             { bytes = 157_541; blocks = [ "memory_os_recall", 139_966 ] }
         ])
  | Ok _ -> Alcotest.fail "null marks read as none, the origin as the record's turn, the layout as slots"

let test_a_not_applicable_lane_decodes_as_such () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":131,
         "walk":{"lane_id":"glm-coding.glm-5.3-flash","declared":["glm-coding.glm-5.3-flash","claude_code.claude-sonnet-5"]},
         "candidates":[{"runtime_id":"claude_code.claude-sonnet-5",
           "lane":{"not_applicable":"claude_code.claude-sonnet-5 is an official-client runtime"},
           "marks":null,
           "parts":{"reserved_measured_on_turn":4700,"reserved_bytes":194651,"pinned_measured_on_turn":4700,"pinned_measured_on_runtime":"claude_code.claude-sonnet-5","pinned_bytes":182167},
           "history_atoms":4429,"carried":null,"assembly":null,
           "place":{"walks_at":1,"declared_at":1,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Ok { candidates = [ { lane = Inspector.Lane_not_applicable reason; carried = None; assembly = None; parts = Ok parts; _ } ]; _ }
    ->
    Alcotest.(check string) "the reason is the server's"
      "claude_code.claude-sonnet-5 is an official-client runtime" reason;
    Alcotest.(check int) "and the parts still decode" 182_167 parts.Inspector.pinned_bytes
  | Ok _ -> Alcotest.fail "a not_applicable lane reads as such, with nothing derived from it"
  | Error detail -> Alcotest.fail ("the not_applicable shape decodes: " ^ detail)

let test_a_malformed_forecast_fails_the_reading () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":131,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"x"},"history_atoms":1,
           "carried":{"first_atom":0,"kept_atoms":1,"transmitted_bytes":300,"origin":{"kind":"sideways"},"counted_tokens":null},
           "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown origin kind is refused, not read as absent"

let test_an_unknown_slot_fails_the_reading () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":131,
         "walk":{"lane_id":"r","declared":["r"]},
         "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
           "parts":{"error":"x"},"history_atoms":1,"carried":null,
           "assembly":[{"slot":"sideways","bytes":1}],"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "an unknown slot is refused, not read as absent"

let test_the_old_schema_is_refused () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v4","checkpoint_messages":1,"wake_line_bytes":131,"candidates":[]}|}
  in
  match Inspector.decode_forecast json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a server on the previous shape is named, not half-read"

(* analyst on the glm-coding lane while its head rests on a 429: the walk
   moves the head behind its siblings and names its release; the others keep
   their declared order. *)
let walked : Inspector.forecast =
  let candidate runtime_id place : Inspector.forecast_candidate =
    { runtime_id
    ; lane = Inspector.Lane_agent_core
    ; marks = None
    ; parts = Error "no composition"
    ; history_atoms = 6362
    ; carried = None
    ; assembly = None
    ; place
    }
  in
  { checkpoint_messages = 6358
  ; wake_line_bytes = 131
  ; walk =
      Ok
        { lane_id = "glm-coding.glm-5.3-flash"
        ; declared =
            [ "glm-coding.glm-5.3-flash"
            ; "ollama_cloud.ollama-cloud-deepseek-v4-1-flash"
            ; "kimi_coding.kimi-k3"
            ; "claude_code.claude-sonnet-5"
            ]
        }
  ; candidates =
      [ candidate "ollama_cloud.ollama-cloud-deepseek-v4-1-flash"
          { walks_at = 0; declared_at = Some 1; rest = Inspector.Rest_serving }
      ; candidate "kimi_coding.kimi-k3"
          { walks_at = 1; declared_at = Some 2; rest = Inspector.Rest_serving }
      ; candidate "claude_code.claude-sonnet-5"
          { walks_at = 2; declared_at = Some 3; rest = Inspector.Rest_serving }
      ; candidate "glm-coding.glm-5.3-flash"
          { walks_at = 3
          ; declared_at = Some 0
          ; rest = Inspector.Rest_resting { release_at = 60_000.; walk_promotes_at_release = true }
          }
      ]
  }

let test_every_candidate_says_where_it_walks_and_why () =
  let rows = lines (Ok walked) in
  Alcotest.(check bool) "the second declared candidate walks first while the head rests" true
    (says "Walks first: declared second on lane glm-coding.glm-5.3-flash." rows);
  Alcotest.(check bool) "the others keep their declared order" true
    (says "Walks second: declared third on lane glm-coding.glm-5.3-flash." rows
     && says "Walks third: declared 4th on lane glm-coding.glm-5.3-flash." rows);
  Alcotest.(check bool) "the resting head walks last and names its release" true
    (says
       "Walks 4th: the declared head; resting until 16:40:00Z, when the walk promotes it."
       rows);
  Alcotest.(check bool) "the footer names the lane and the count" true
    (says "Lane glm-coding.glm-5.3-flash: 4 candidates in the order the next cycle walks them"
       rows);
  Alcotest.(check bool) "and no longer claims only the bound runtime is forecast" false
    (says "Only the bound runtime" rows)

let test_the_assembly_is_drawn_for_the_first_walker_alone () =
  let second : Inspector.forecast_candidate =
    match measured.candidates with
    | [ first ] ->
      { first with
        runtime_id = "kimi_coding.kimi-k3"
      ; place = { walks_at = 1; declared_at = Some 1; rest = Inspector.Rest_serving }
      }
    | _ -> Alcotest.fail "one measured candidate"
  in
  let forecast =
    { (with_candidate (fun candidate -> { candidate with assembly = Some assembled }) measured) with
      candidates =
        List.map
          (fun (candidate : Inspector.forecast_candidate) ->
             { candidate with assembly = Some assembled })
          (measured.candidates @ [ second ])
    }
  in
  let rows = lines (Ok forecast) in
  let count needle = List.length (List.filter (fun row -> contains needle (strip row)) rows) in
  Alcotest.(check int) "one layout on the screen" 1 (count "In the order the request carries them");
  Alcotest.(check int) "both candidates are named" 2 (count "Walks ")

let test_the_walk_and_the_place_decode () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":131,
         "walk":{"lane_id":"l","declared":["a","b"]},
         "candidates":[{"runtime_id":"b","lane":{"agent_core":true},"marks":null,"parts":{"error":"x"},
           "history_atoms":1,"carried":null,"assembly":null,
           "place":{"walks_at":0,"declared_at":1,"rest":{"kind":"resting","release_at":60000,"walk_promotes_at_release":false}}},
          {"runtime_id":"z","lane":{"agent_core":true},"marks":null,"parts":{"error":"x"},
           "history_atoms":1,"carried":null,"assembly":null,
           "place":{"walks_at":1,"declared_at":null,"rest":{"kind":"serving"}}}]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("the walk decodes: " ^ detail)
  | Ok { walk = Ok walk; candidates = [ first; second ]; _ } ->
    Alcotest.(check bool) "the lane and its declaration" true
      (walk.lane_id = "l" && walk.declared = [ "a"; "b" ]);
    Alcotest.(check bool) "a resting place with its release" true
      (first.place
       = { walks_at = 0
         ; declared_at = Some 1
         ; rest = Inspector.Rest_resting { release_at = 60_000.; walk_promotes_at_release = false }
         });
    Alcotest.(check bool) "an undeclared id has no declared place" true
      (second.place = { walks_at = 1; declared_at = None; rest = Inspector.Rest_serving })
  | Ok _ -> Alcotest.fail "two candidates decode"

(* An assignment the driver would refuse: the server says why, the band
   names it in place of any candidate. *)
let test_a_refused_walk_is_named_not_walked () =
  let json =
    Yojson.Safe.from_string
      {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":7,"wake_line_bytes":131,
         "walk":{"refusal":"the assignment names no configured lane or runtime"},"candidates":[]}|}
  in
  match Inspector.decode_forecast json with
  | Error detail -> Alcotest.fail ("a refused walk decodes: " ^ detail)
  | Ok ({ walk = Error refusal; candidates = []; _ } as forecast) ->
    Alcotest.(check string) "the reason is the server's"
      "the assignment names no configured lane or runtime" refusal;
    let rows = lines (Ok forecast) in
    Alcotest.(check bool) "the band names it" true
      (says "Next request not walked: the assignment names no configured lane or runtime" rows);
    Alcotest.(check bool) "and walks nothing" false (says "Walks " rows || says "Lane " rows)
  | Ok _ -> Alcotest.fail "a refused walk reads as a refusal with no candidates"

let () =
  Alcotest.run "tui_next_request_band"
    [ ( "render"
      , [ Alcotest.test_case "the band names the marks and the range" `Quick
            test_the_band_names_the_marks_and_the_range
        ; Alcotest.test_case "a pinned figure from another lane names it" `Quick
            test_a_pinned_figure_from_another_lane_names_it
        ; Alcotest.test_case "the assembly is drawn in travel order" `Quick
            test_the_assembly_is_drawn_in_travel_order
        ; Alcotest.test_case "a preamble slot is named when the range prepended one" `Quick
            test_a_preamble_slot_is_named_when_the_range_prepended_one
        ; Alcotest.test_case "no assembly draws no order" `Quick test_no_assembly_draws_no_order
        ; Alcotest.test_case "no marks says only a refusal moves the front" `Quick
            test_no_marks_says_only_a_refusal_moves_the_front
        ; Alcotest.test_case "a cold front names its record and nothing counted" `Quick
            test_a_cold_front_names_its_record_and_nothing_counted
        ; Alcotest.test_case "the turn start and refusal fronts say why" `Quick
            test_the_turn_start_and_refusal_fronts_say_why
        ; Alcotest.test_case "a turn start origin decodes with its atom" `Quick
            test_a_turn_start_origin_decodes
        ; Alcotest.test_case "no range without the fixed parts is said" `Quick
            test_no_range_without_the_fixed_parts_is_said
        ; Alcotest.test_case "an official-client runtime carries no range and says why" `Quick
            test_an_official_client_runtime_carries_no_range_and_says_why
        ; Alcotest.test_case "a missing forecast is named, not hidden" `Quick
            test_a_missing_forecast_is_named_not_hidden
        ; Alcotest.test_case "every candidate says where it walks and why" `Quick
            test_every_candidate_says_where_it_walks_and_why
        ; Alcotest.test_case "the assembly is drawn for the first walker alone" `Quick
            test_the_assembly_is_drawn_for_the_first_walker_alone
        ] )
    ; ( "decode"
      , [ Alcotest.test_case "the forecast decodes the server's shape" `Quick
            test_the_forecast_decodes_the_servers_shape
        ; Alcotest.test_case "null marks, count, a record origin and a layout decode" `Quick
            test_null_marks_count_a_record_origin_and_a_layout_decode
        ; Alcotest.test_case "an evicted refusal origin decodes" `Quick
            test_an_evicted_refusal_origin_decodes
        ; Alcotest.test_case "a refused seed origin decodes" `Quick
            test_a_refused_seed_origin_decodes
        ; Alcotest.test_case "a not-applicable lane decodes as such" `Quick
            test_a_not_applicable_lane_decodes_as_such
        ; Alcotest.test_case "a malformed forecast fails the reading" `Quick
            test_a_malformed_forecast_fails_the_reading
        ; Alcotest.test_case "an unknown slot fails the reading" `Quick
            test_an_unknown_slot_fails_the_reading
        ; Alcotest.test_case "the old schema is refused" `Quick test_the_old_schema_is_refused
        ; Alcotest.test_case "the walk and the place decode" `Quick
            test_the_walk_and_the_place_decode
        ; Alcotest.test_case "a refused walk is named, not walked" `Quick
            test_a_refused_walk_is_named_not_walked
        ] )
    ]
