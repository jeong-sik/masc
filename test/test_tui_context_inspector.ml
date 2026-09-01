open Alcotest

module Inspector = Masc_tui_context_inspector
open Turn_record

let turn_ref trace turn =
  match Ids.Turn_ref.of_yojson (`String (Printf.sprintf "%s#%d" trace turn)) with
  | Ok value -> value
  | Error detail -> fail detail

let record ?(blocks = []) ?input_components ~trace ~turn () : Turn_record.t =
  { execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks
  ; input_components
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason = Some "stop"
  ; context_window = Some 200_000
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some { transmitted_atoms = 3; total_atoms = 4; measurement = Wire_shape }
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; thinking_budget = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = Runtime_usage_scope.Per_request
      }
  ; ts = 1_787_600_000.
  }

let envelope records =
  `Assoc
    [ ( "entries"
      , `List
          (List.map
             (fun record ->
               `Assoc
                 [ "record", Turn_record.to_json record
                 ; "diff_vs_prev", `Null
                 ])
             records) )
    ]

let test_newest_exact_composition_wins () =
  let observed =
    record ~trace:"trace-a" ~turn:1
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Dynamic_context
          ; bytes = 120
          }
        ; { component = Tool_schemas; bytes = 80 }
        ]
      ()
  in
  let unobserved = record ~trace:"trace-a" ~turn:2 () in
  match Inspector.decode_turn_records (envelope [ observed; unobserved ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is the newest one, attributed or not" 2
        decoded.Inspector.latest.absolute_turn;
      (match decoded.Inspector.attributed with
       | None -> fail "an attributed row was on the page and must be reported"
       | Some attributed ->
           check int "attribution comes from the newest attributed row" 1
             attributed.Inspector.record.absolute_turn;
           check int "and the reading says how far back that row is" 1
             attributed.Inspector.turns_behind_latest;
           check int "attributed bytes" 200
             (List.fold_left
                (fun total (component : Turn_record.input_component) ->
                  total + component.bytes)
                0 attributed.Inspector.components))

(* On 2026-09-01 every row of rondo's and taskmaster's 50-turn page was
   unattributed, and the reading failed outright -- discarding the token,
   usage, wire and window readings the newest row did carry. *)
let test_page_without_attribution_still_reads () =
  let older = record ~trace:"trace-a" ~turn:7 () in
  let newer = record ~trace:"trace-a" ~turn:8 () in
  match Inspector.decode_turn_records (envelope [ older; newer ]) with
  | Error detail -> fail detail
  | Ok decoded ->
      check int "the latest row is still reported" 8
        decoded.Inspector.latest.absolute_turn;
      check bool "with no attribution to show" true
        (Option.is_none decoded.Inspector.attributed)

let test_empty_page_is_an_error () =
  check bool "an empty page has no latest row to report" true
    (Result.is_error (Inspector.decode_turn_records (envelope [])))

let test_malformed_row_is_not_dropped () =
  let good = record ~trace:"trace-a" ~turn:1 ~input_components:[] () in
  let json =
    match envelope [ good ] with
    | `Assoc [ ("entries", `List rows) ] ->
        `Assoc
          [ ( "entries"
            , `List
                (`Assoc [ "diff_vs_prev", `Null ] :: rows) ) ]
    | _ -> fail "fixture shape changed"
  in
  check bool "malformed row fails the whole reading" true
    (Result.is_error (Inspector.decode_turn_records json))

let prompt_response keeper =
  let capture : Masc.Keeper_prompt_capture.capture =
    { captured_at = 1_787_600_000.
    ; trace_id = "trace-a"
    ; absolute_turn = 7
    ; blocks =
        [ { id = Prompt_block_id.Memory_os_recall
          ; text = "Remember the exact fact."
          }
        ]
    ; assembled = Some "Remember the exact fact."
    }
  in
  match Masc.Keeper_prompt_capture.to_json capture with
  | `Assoc fields -> `Assoc (("keeper", `String keeper) :: fields)
  | _ -> fail "capture encoder did not return an object"

let test_prompt_capture_binds_keeper () =
  check bool "wrong Keeper is rejected" true
    (Result.is_error
       (Inspector.decode_prompt_capture ~expected_keeper:"omega"
          (prompt_response "other")));
  match
    Inspector.decode_prompt_capture ~expected_keeper:"omega"
      (prompt_response "omega")
  with
  | Error detail -> fail detail
  | Ok capture ->
      check int "one exact prompt block" 1 (List.length capture.blocks);
      check string "memory label" "Memory recall"
        (Inspector.prompt_block_label (List.hd capture.blocks).id)

let digest text = Digestif.SHA256.(digest_string text |> to_hex)

let test_input_map_joins_only_verified_prompt_text () =
  let text = "remember the operator preference" in
  let prompt_block : Turn_record.prompt_block =
    { block = Prompt_block_id.Memory_os_recall
    ; bytes = String.length text
    ; digest = digest text
    }
  in
  let observed =
    record ~trace:"trace-map" ~turn:9 ~blocks:[ prompt_block ]
      ~input_components:
        [ { component = Prompt_block Prompt_block_id.Memory_os_recall
          ; bytes = String.length text
          }
        ; { component = Tool_schemas; bytes = 2048 }
        ]
      ()
  in
  let capture : Masc.Keeper_prompt_capture.capture =
    { captured_at = 1_787_600_000.
    ; trace_id = "trace-map"
    ; absolute_turn = 9
    ; blocks = [ { id = Prompt_block_id.Memory_os_recall; text } ]
    ; assembled = Some text
    }
  in
  let rows =
    Inspector.input_map_rows observed (Some capture)
      ~tool_surface:Inspector.Surface_not_recorded
  in
  let memory = List.nth rows 0 in
  let tools = List.nth rows 1 in
  check (option string) "matching capture exposes exact text" (Some text)
    memory.exact_text;
  check string "matching capture is verified" "verified exact text"
    memory.retention;
  check (option string) "an unrecorded surface stays byte-only" None
    tools.exact_text;
  check string "an unrecorded surface keeps its default retention"
    "schema bytes only" tools.retention;
  check string "tool source is explicit" "effective tool surface"
    tools.included_by;
  let stale = { capture with absolute_turn = 8 } in
  let stale_memory =
    List.hd
      (Inspector.input_map_rows observed (Some stale)
         ~tool_surface:Inspector.Surface_not_recorded)
  in
  check (option string) "another turn is not joined" None stale_memory.exact_text;
  let changed =
    { capture with
      blocks =
        [ { id = Prompt_block_id.Memory_os_recall
          ; text = "different text with same authority"
          }
        ]
    }
  in
  let changed_memory =
    List.hd
      (Inspector.input_map_rows observed (Some changed)
         ~tool_surface:Inspector.Surface_not_recorded)
  in
  check (option string) "digest mismatch is not joined" None
    changed_memory.exact_text

(* Three surfaces spell a byte count through this: the Context inspector, the
   attachment note beside a chat message, and the skill-delivery row. The
   delivery row used to divide by 1024 itself and so had no rung above KB.

   A column has to hold the widest reading, and the widest is not the largest
   number: [1023.9 KB] is nine cells while [999.9 MB] is eight. The delivery
   column is sized nine, so that is what this pins. *)
let test_a_size_never_outgrows_the_column_it_is_drawn_in () =
  List.iter
    (fun bytes ->
      let text = Masc_tui_context_inspector.format_bytes bytes in
      check bool
        (Printf.sprintf "%d bytes reads as %s, within nine cells" bytes text)
        true
        (String.length text <= 9))
    [ 0; 1; 999; 1023; 1024; 1_048_575; 1_048_576; 999_999_999;
      1_073_741_824 ]

let test_a_size_climbs_past_kilobytes () =
  List.iter
    (fun (bytes, expected) ->
      check string (Printf.sprintf "%d bytes" bytes) expected
        (Masc_tui_context_inspector.format_bytes bytes))
    [ (512, "512 B")
    ; (1024, "1.0 KB")
    ; (1_048_576, "1.0 MB")
    ; (3_145_728, "3.0 MB")
    ]

(* The listing answers one question -- which tools cost the request its
   schema bytes -- so it is ordered by what it costs, not by config order. *)
let test_the_listing_is_ordered_by_what_it_costs () =
  let surface =
    Inspector.Surface_resolved
      [ { name = "masc_run_list"; schema_bytes = 379 }
      ; { name = "masc_schedule_create"; schema_bytes = 4093 }
      ; { name = "masc_board_hearths"; schema_bytes = 158 }
      ]
  in
  let observed =
    record ~trace:"trace-surface" ~turn:11
      ~input_components:[ { component = Tool_schemas; bytes = 4630 } ]
      ()
  in
  let row = List.hd (Inspector.input_map_rows observed None ~tool_surface:surface) in
  match row.exact_text with
  | None -> fail "a resolved surface must open"
  | Some text ->
      let lines = String.split_on_char '\n' text in
      let named =
        List.filter
          (fun line -> String.length line > 0 && String.contains line ' ')
          (List.filteri (fun index _ -> index >= 3) lines)
      in
      check (list string) "largest schema first"
        [ "4.0 KB  masc_schedule_create"
        ; "379 B  masc_run_list"
        ; "158 B  masc_board_hearths"
        ]
        named;
      check string "a resolved surface reads as verified" "verified exact text"
        row.retention

(* A reference that would not read and a turn that recorded none are different
   facts. Collapsing them would report a failed fetch as "this request carried
   no tools", which is the one reading an operator must not be handed. *)
let test_an_unreadable_listing_says_so_on_its_row () =
  let observed =
    record ~trace:"trace-surface" ~turn:12
      ~input_components:[ { component = Tool_schemas; bytes = 4630 } ]
      ()
  in
  let row =
    List.hd
      (Inspector.input_map_rows observed None
         ~tool_surface:(Inspector.Surface_unresolved { detail = "returned 404" }))
  in
  check (option string) "an unreadable listing does not open" None row.exact_text;
  check string "the row carries the reason"
    "listing unreadable: returned 404" row.retention

let artifact_envelope content =
  `Assoc
    [ "sha256", `String (String.make 64 'a')
    ; "bytes", `Int (String.length content)
    ; "mime", `String "text/plain"
    ; "content", `String content
    ]

let test_one_malformed_entry_fails_the_whole_listing () =
  check bool "a good listing decodes" true
    (Result.is_ok
       (Inspector.decode_tool_surface
          (artifact_envelope
             {|[{"name":"masc_gc","schema_bytes":12}]|})));
  (* Dropping the bad entry would understate the surface that was sent, which
     is exactly the number this row exists to report. *)
  check bool "a nameless entry fails the listing" true
    (Result.is_error
       (Inspector.decode_tool_surface
          (artifact_envelope
             {|[{"name":"masc_gc","schema_bytes":12},{"schema_bytes":9}]|})));
  check bool "a non-array payload fails" true
    (Result.is_error (Inspector.decode_tool_surface (artifact_envelope "{}")));
  (* The endpoint's own refusal names the sha256 it would not serve; a generic
     message here would throw that away. *)
  match
    Inspector.decode_tool_surface
      (`Assoc [ "error", `String "not found"; "sha256", `String "abc" ])
  with
  | Ok _ -> fail "an error envelope is not a listing"
  | Error detail -> check string "the endpoint keeps its words" "not found" detail

let test_a_reference_is_read_not_restated () =
  let stored =
    Tool_output.Stored
      (match
         Tool_output.make_artifact_ref ~sha256:(String.make 64 'b') ~bytes:120
           ~preview:"[{\"name\"" ~mime:"application/json"
       with
       | Ok reference -> reference
       | Error error -> fail (Tool_output.make_error_to_string error))
  in
  let marked =
    record ~trace:"trace-surface" ~turn:13 ()
    |> fun row ->
    { row with tool_surface_ref = Some (Tool_output.encode_for_agent_core stored) }
  in
  check (option (result string string)) "a marker yields its content address"
    (Some (Ok (String.make 64 'b')))
    (Inspector.tool_surface_sha256 marked);
  check bool "a record without a reference asks for nothing" true
    (Option.is_none
       (Inspector.tool_surface_sha256 (record ~trace:"trace-surface" ~turn:14 ())));
  check bool "a reference that is not a marker is reported, not fetched" true
    (match
       Inspector.tool_surface_sha256
         { (record ~trace:"trace-surface" ~turn:15 ()) with
           tool_surface_ref = Some "not a marker"
         }
     with
     | Some (Error _) -> true
     | Some (Ok _) | None -> false)

let () =
  run "tui_context_inspector"
    [ ( "decode"
      , [ test_case "selects newest exact composition" `Quick
            test_newest_exact_composition_wins
        ; test_case "an unattributed page still reads" `Quick
            test_page_without_attribution_still_reads
        ; test_case "an empty page is an error" `Quick
            test_empty_page_is_an_error
        ; test_case "rejects malformed rows" `Quick
            test_malformed_row_is_not_dropped
        ; test_case "binds exact prompt to Keeper" `Quick
            test_prompt_capture_binds_keeper
        ; test_case "joins only verified prompt text" `Quick
            test_input_map_joins_only_verified_prompt_text
        ; test_case "a size never outgrows its column" `Quick
            test_a_size_never_outgrows_the_column_it_is_drawn_in
        ; test_case "a size climbs past kilobytes" `Quick
            test_a_size_climbs_past_kilobytes
        ] )
    ; ( "tool surface"
      , [ test_case "the listing is ordered by what it costs" `Quick
            test_the_listing_is_ordered_by_what_it_costs
        ; test_case "an unreadable listing says so on its row" `Quick
            test_an_unreadable_listing_says_so_on_its_row
        ; test_case "one malformed entry fails the whole listing" `Quick
            test_one_malformed_entry_fails_the_whole_listing
        ; test_case "a reference is read, not restated" `Quick
            test_a_reference_is_read_not_restated
        ] )
    ]
