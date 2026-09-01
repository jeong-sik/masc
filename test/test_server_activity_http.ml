(** Unit tests for [Server_activity_http.slice_default_events_to_limit].

    RFC-0201 Step 1 follow-up (issue #19313).  Guards the default-query
    path that serves [Dashboard_snapshot.current ()].activity_events_default. *)

open Alcotest

let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

let mk_event ~seq kind =
  `Assoc [ ("seq", `Int seq); ("kind", `String kind) ]

let mk_input ?(after_seq = 0) ?next_after_seq ?(limit = 200) events =
  let base =
    [ ("events", `List events)
    ; ("count", `Int (List.length events))
    ; ("limit", `Int limit)
    ; ("after_seq", `Int after_seq)
    ]
  in
  match next_after_seq with
  | Some n -> `Assoc (("next_after_seq", `Int n) :: base)
  | None -> `Assoc base

let get_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let get_int_field key json =
  match get_field key json with
  | Some (`Int n) -> Some n
  | _ -> None

let get_list_field key json =
  match get_field key json with
  | Some (`List xs) -> Some xs
  | _ -> None

let test_len_lt_limit () =
  (* Case 1: fewer events than limit — events preserved, limit refreshed. *)
  let events = [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b" ] in
  let input = mk_input events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check (option int) "limit updated" (Some 10) (get_int_field "limit" got);
  check (option int) "count preserved" (Some 2) (get_int_field "count" got);
  check (option int) "after_seq preserved" (Some 0)
    (get_int_field "after_seq" got);
  check (list yojson) "events preserved" events
    (Option.value (get_list_field "events" got) ~default:[])

let test_len_eq_limit () =
  (* Case 2: exactly at limit — events preserved, limit refreshed. *)
  let events = [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b" ] in
  let input = mk_input events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:2 in
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got);
  check (list yojson) "events preserved" events
    (Option.value (get_list_field "events" got) ~default:[])

let test_len_gt_limit () =
  (* Case 3: more events than limit — drop oldest, keep tail. *)
  let events =
    [ mk_event ~seq:1 "a"
    ; mk_event ~seq:2 "b"
    ; mk_event ~seq:3 "c"
    ; mk_event ~seq:4 "d"
    ]
  in
  let input = mk_input ~next_after_seq:0 events in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:2 in
  let expected_events = [ mk_event ~seq:3 "c"; mk_event ~seq:4 "d" ] in
  check (list yojson) "tail 2 kept" expected_events
    (Option.value (get_list_field "events" got) ~default:[]);
  check (option int) "count updated" (Some 2) (get_int_field "count" got);
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got);
  (* next_after_seq comes from the last kept event's seq *)
  check (option int) "next_after_seq from last seq" (Some 4)
    (get_int_field "next_after_seq" got)

let test_empty_events () =
  (* Case 4: empty list — next_after_seq falls back to after_seq. *)
  let input = mk_input ~after_seq:42 ~next_after_seq:0 [] in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check (list yojson) "events empty" []
    (Option.value (get_list_field "events" got) ~default:[]);
  check (option int) "next_after_seq falls back to after_seq" (Some 42)
    (get_int_field "next_after_seq" got)

let test_missing_seq () =
  (* Case 5: last event lacks seq — next_after_seq falls back to
     input's next_after_seq field. *)
  let event_no_seq = `Assoc [ ("kind", `String "x") ] in
  let input = mk_input ~next_after_seq:99 [ event_no_seq ] in
  let got =
    Server_activity_http.slice_default_events_to_limit input ~limit:10
  in
  check (option int) "next_after_seq falls back to field" (Some 99)
    (get_int_field "next_after_seq" got)

let test_non_assoc_passthrough () =
  (* Case 6: non-Assoc input — passthrough unchanged. *)
  let input = `String "not an object" in
  let got = Server_activity_http.slice_default_events_to_limit input ~limit:10 in
  check yojson "passthrough" input got

let test_count_and_limit_updated () =
  (* When slicing occurs, count and limit fields are refreshed. *)
  let events =
    [ mk_event ~seq:1 "a"; mk_event ~seq:2 "b"; mk_event ~seq:3 "c" ]
  in
  let input = mk_input events in
  let got =
    Server_activity_http.slice_default_events_to_limit input ~limit:2
  in
  check (option int) "count updated" (Some 2) (get_int_field "count" got);
  check (option int) "limit updated" (Some 2) (get_int_field "limit" got)

let prompt_request_error expected body =
  match Server_prompt_override_request.decode body with
  | Error error ->
    check
      string
      expected
      expected
      (Server_prompt_override_request.error_message error)
  | Ok _ -> fail ("accepted invalid prompt override request: " ^ body)
;;

let test_prompt_override_request_decodes_once () =
  (match
     Server_prompt_override_request.decode
       {|{"action":"set","key":"keeper","value":"custom"}|}
   with
   | Ok (Server_prompt_override_request.Set { key; value }) ->
     check string "set key" "keeper" key;
     check string "set value" "custom" value
   | Ok (Server_prompt_override_request.Clear _) -> fail "decoded set as clear"
   | Error error -> fail (Server_prompt_override_request.error_message error));
  (match
     Server_prompt_override_request.decode
       {|{"action":"clear","key":"keeper"}|}
   with
   | Ok (Server_prompt_override_request.Clear { key }) ->
     check string "clear key" "keeper" key
   | Ok (Server_prompt_override_request.Set _) -> fail "decoded clear as set"
   | Error error -> fail (Server_prompt_override_request.error_message error));
  match
    Server_prompt_override_request.decode
      {|{"action":"set","key":"keeper","value":""}|}
  with
  | Ok (Server_prompt_override_request.Set { value; _ }) ->
    check string "content validation stays in prompt registry" "" value
  | Ok (Server_prompt_override_request.Clear _) -> fail "decoded set as clear"
  | Error error -> fail (Server_prompt_override_request.error_message error)
;;

let test_prompt_override_request_rejects_noncanonical_shapes () =
  (match Server_prompt_override_request.decode "{" with
   | Error _ -> ()
   | Ok _ -> fail "accepted malformed JSON");
  prompt_request_error "request body must be an object" "[]";
  prompt_request_error "key is required" {|{"action":"clear"}|};
  prompt_request_error
    "key must be a string"
    {|{"action":"clear","key":1}|};
  prompt_request_error
    "key is required"
    {|{"action":"clear","key":" "}|};
  prompt_request_error
    "key must not contain surrounding whitespace"
    {|{"action":"clear","key":" keeper"}|};
  prompt_request_error
    "duplicate key field"
    {|{"action":"clear","key":"keeper","key":"keeper"}|};
  prompt_request_error "action is required" {|{"key":"keeper"}|};
  prompt_request_error
    "action must be a string"
    {|{"action":false,"key":"keeper"}|};
  prompt_request_error
    "duplicate action field"
    {|{"action":"clear","action":"clear","key":"keeper"}|};
  prompt_request_error
    "unsupported action: reset"
    {|{"action":"reset","key":"keeper"}|};
  prompt_request_error
    "value is required for set"
    {|{"action":"set","key":"keeper"}|};
  prompt_request_error
    "value must be a string"
    {|{"action":"set","key":"keeper","value":null}|};
  prompt_request_error
    "duplicate value field"
    {|{"action":"set","key":"keeper","value":"a","value":"b"}|}
;;

let test_runtime_prompt_assets_are_read_only_and_missing_visible () =
  let prompts_dir = Filename.temp_file "masc_runtime_prompt_assets" "" in
  Sys.remove prompts_dir;
  Unix.mkdir prompts_dir 0o755;
  let wake_path = Filename.concat prompts_dir "keeper.autonomous.wake.txt" in
  let channel = open_out wake_path in
  output_string channel "wake from runtime";
  close_out channel;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove wake_path;
      Unix.rmdir prompts_dir)
    (fun () ->
       let assets =
         Server_routes_http_routes_activity.runtime_prompt_assets_json
           ~prompts_dir
           ~embedded_files:
             [ "prompts/keeper.autonomous.wake.txt"
             ; "prompts/harness.coding_keeper.txt"
             ; "prompts/keeper.md"
             ; "tools/ignored.txt"
             ]
       in
       check int "only prompt txt assets" 2 (List.length assets);
       let open Yojson.Safe.Util in
       let missing = List.hd assets in
       check string "sorted missing asset path" "harness.coding_keeper.txt"
         (missing |> member "path" |> to_string);
       check bool "missing asset remains visible" false
         (missing |> member "file_exists" |> to_bool);
       let wake = List.nth assets 1 in
       check string "runtime projection content" "wake from runtime"
         (wake |> member "value" |> to_string);
       check bool "present runtime asset" true
         (wake |> member "file_exists" |> to_bool))
;;

let () =
  run "Server_activity_http"
    [ ( "slice_default_events_to_limit"
      , [ test_case "len < limit" `Quick test_len_lt_limit
        ; test_case "len == limit" `Quick test_len_eq_limit
        ; test_case "len > limit" `Quick test_len_gt_limit
        ; test_case "empty events" `Quick test_empty_events
        ; test_case "missing seq fallback" `Quick test_missing_seq
        ; test_case "non-Assoc passthrough" `Quick test_non_assoc_passthrough
        ; test_case "count and limit updated" `Quick test_count_and_limit_updated
        ] )
    ; ( "prompt_override_request"
      , [ test_case "decodes current request once" `Quick
            test_prompt_override_request_decodes_once
        ; test_case "rejects noncanonical request shapes" `Quick
            test_prompt_override_request_rejects_noncanonical_shapes
        ] )
    ; ( "runtime_prompt_assets"
      , [ test_case "lists txt assets without making them overrideable" `Quick
            test_runtime_prompt_assets_are_read_only_and_missing_visible
        ] )
    ]
