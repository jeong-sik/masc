(* The NEXT REQUEST band draws the server's forecast in tokens at the tab's
   scale: the carried range from the pair's front, the retained ledger
   baseline, the separate trim settings, and the parts in the order the request
   carries them. The band is rendered here through its own entry point with
   plain folding, so the assertions are about the sentences, not the pane. *)

module Inspector = Masc_tui_context_inspector
module Band = Masc_tui_next_request_band

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
   sits at atom 3,100 of 3,395, the ledger baseline is 91k tokens. *)
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

let test_a_start_past_the_librarian_point_decodes () =
  let decode origin =
    Inspector.decode_forecast
      (Yojson.Safe.from_string
         (Printf.sprintf
            {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
               "walk":{"lane_id":"r","declared":["r"]},
               "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
                 "parts":{"error":"not measured"},"history_atoms":12,
                 "carried":{"first_atom":8,"kept_atoms":4,"transmitted_bytes":300,"preamble_bytes":null,
                            "origin":%s,"counted_tokens":null},
                 "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
            origin))
  in
  (match
     decode
       {|{"kind":"past_librarian_point","librarian_end_atom":2,"front":{"kind":"turn_record","turn":7}}|}
   with
   | Ok
       { candidates =
           [ { carried =
                 Some
                   { origin =
                       Inspector.Carried_past_librarian_point
                         { librarian_end_atom = 2; front = Inspector.Carried_from_turn_record { turn = 7 } }
                   ; _
                   }
             ; _
             }
           ]
       ; _
       } -> ()
   | Ok _ -> Alcotest.fail "the start past the point decoded as another origin"
   | Error detail -> Alcotest.fail ("the start past the point decodes: " ^ detail));
  Alcotest.(check bool) "a front that is itself a Librarian point is refused" true
    (Result.is_error
       (decode
          {|{"kind":"past_librarian_point","librarian_end_atom":2,"front":{"kind":"librarian_progress","end_atom":2}}|}))

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
  let with_origin origin =
    Yojson.Safe.from_string
      (Printf.sprintf
         {|{"schema":"masc.keeper.next-request-forecast.v5","checkpoint_messages":1,"wake_line_bytes":1,
            "walk":{"lane_id":"r","declared":["r"]},
            "candidates":[{"runtime_id":"r","lane":{"agent_core":true},"marks":null,
              "parts":{"error":"not measured"},"history_atoms":4,
              "carried":{"first_atom":2,"kept_atoms":2,"transmitted_bytes":300,"preamble_bytes":null,
                         "origin":%s,"counted_tokens":null},
              "assembly":null,"place":{"walks_at":0,"declared_at":0,"rest":{"kind":"serving"}}}]}|}
         origin)
  in
  (match
     Inspector.decode_forecast
       (with_origin {|{"kind":"librarian_snapshot","end_atom":2,"boundary_line":7}|})
   with
   | Ok
       { candidates =
           [ { carried =
                 Some
                   { origin =
                       Inspector.Carried_librarian_snapshot { end_atom = 2; boundary_line = 7 }
                   ; _
                   }
             ; _
             }
           ]
       ; _
       } -> ()
   | Ok _ -> Alcotest.fail "the snapshot origin lost its position"
   | Error detail -> Alcotest.fail ("the snapshot origin decodes: " ^ detail));
  (match
     Inspector.decode_forecast (with_origin {|{"kind":"librarian_progress","end_atom":2}|})
   with
   | Ok
       { candidates =
           [ { carried = Some { origin = Inspector.Carried_librarian_progress { end_atom = 2 }; _ }
             ; _
             }
           ]
       ; _
       } -> ()
   | Ok _ -> Alcotest.fail "the read-position origin lost its atom"
   | Error detail -> Alcotest.fail ("the read-position origin decodes: " ^ detail));
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

let test_runtime_configuration_attaches_by_exact_id () =
  let observed = ref [] in
  let rows = Band.lines ~prose:(fun x -> [x]) ~fact:(fun x -> [x]) ~safe:Fun.id
    ~scale:Masc_tui_token_scale.fleet
    ~runtime_details:(fun id -> observed := id :: !observed;
      ["Account codex1 · configured context 500000 tokens"])
    (Ok measured) in
  Alcotest.(check (list string)) "lookup uses the candidate identity"
    ["ollama_cloud.deepseek-v4-1-flash"] !observed;
  Alcotest.(check bool) "account/window is visible" true (says "Account codex1" rows);
  Alcotest.(check bool) "execution order remains explicit" true (says "Walks first" rows)

let () =
  Alcotest.run "tui_next_request_band"
    [ ( "render"
      , [ Alcotest.test_case "current account configuration follows exact runtime" `Quick test_runtime_configuration_attaches_by_exact_id
        ; Alcotest.test_case "a turn start origin decodes with its atom" `Quick
            test_a_turn_start_origin_decodes
        ;] )
    ; ( "decode"
      , [ Alcotest.test_case "the forecast decodes the server's shape" `Quick
            test_the_forecast_decodes_the_servers_shape
        ; Alcotest.test_case "null marks, count, a record origin and a layout decode" `Quick
            test_null_marks_count_a_record_origin_and_a_layout_decode
        ; Alcotest.test_case "an evicted refusal origin decodes" `Quick
            test_an_evicted_refusal_origin_decodes
        ; Alcotest.test_case "a refused seed origin decodes" `Quick
            test_a_refused_seed_origin_decodes
        ; Alcotest.test_case "a start past the Librarian point decodes" `Quick
            test_a_start_past_the_librarian_point_decodes
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
