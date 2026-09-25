open Alcotest
open Masc

let usage_event =
  Runtime_muse.Usage_reported
    { session_id = "sess-1"
    ; usage =
        { Runtime_muse.input_tokens = 10
        ; output_tokens = 3
        ; reasoning_tokens = 1
        ; cached_tokens = 2
        }
    }
;;

let test_usage_event_reports_turn_total () =
  let reports = ref [] in
  Keeper_muse_runtime.For_testing.report_stream_usage
    ~turn_count:4
    ~position:Keeper_usage_resolution.Fresh
    ~report:(fun report -> reports := report :: !reports)
    usage_event;
  match !reports with
  | [ report ] ->
    check int "turn" 4 report.Keeper_client_usage_report.official_turn;
    check string "response" "sess-1:ordinal:4" report.Keeper_client_usage_report.response_id;
    check string "conversation" "sess-1" report.Keeper_client_usage_report.conversation_id;
    check bool "scope is turn total"
      true
      (report.Keeper_client_usage_report.usage_scope = Runtime_usage_scope.Turn_total);
    check (option int) "no vendor total" None
      report.Keeper_client_usage_report.vendor_total_tokens;
    (match report.Keeper_client_usage_report.count with
     | Keeper_client_usage_report.Running_count usage ->
       check int "input" 10 usage.Agent_core.Types.input_tokens;
       check int "output" 3 usage.Agent_core.Types.output_tokens;
       check int "cache read" 2 usage.Agent_core.Types.cache_read_input_tokens
     | Keeper_client_usage_report.Count_replaced ->
       fail "a running turn must not replace the count")
  | _ -> fail "one usage event reports exactly once"
;;

let test_non_usage_events_report_nothing () =
  let reports = ref [] in
  let report event =
    Keeper_muse_runtime.For_testing.report_stream_usage
      ~turn_count:1
      ~position:Keeper_usage_resolution.Resumed
      ~report:(fun report -> reports := report :: !reports)
      event
  in
  report (Runtime_muse.Turn_started { session_id = "s"; turn_id = None });
  report (Runtime_muse.Text_delta "hi");
  report (Runtime_muse.Turn_finished { text = "hi" });
  check int "no reports" 0 (List.length !reports)
;;

let test_start_prompt_bytes_pins_framing () =
  match Keeper_muse_runtime.For_testing.start_prompt_bytes ~system_prompt:"sys" ~goal:"g" [] with
  | Error detail -> fail ("framing failed: " ^ detail)
  | Ok bytes ->
    (* "System instructions:\nsys" + "\n\n" + "Current goal:\ng" *)
    check int "framing" 41 bytes
;;

let png_block =
  Agent_core.Types.Image
    { media_type = "image/png"; data = "aGk="; source_type = Agent_core.Types.Base64 }
;;

let test_goal_images_become_files () =
  match
    Keeper_muse_runtime.For_testing.muse_images_of_goal_blocks
      [ Agent_core.Types.Text "hi"; png_block ]
  with
  | Error error -> fail ("images refused: " ^ Agent_core.Error.to_string error)
  | Ok images ->
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (image : Runtime_muse.image_input) -> Sys.remove image.Runtime_muse.path)
          images)
      (fun () ->
        (match images with
         | [ image ] ->
           check bool "png suffix" true
             (Filename.check_suffix image.Runtime_muse.path ".png");
           let channel = open_in_bin image.Runtime_muse.path in
           let contents = really_input_string channel (in_channel_length channel) in
           close_in channel;
           check string "decoded bytes" "hi" contents
         | _ -> fail "one image block writes one file"))
;;

let test_unknown_media_type_is_refused () =
  let block =
    Agent_core.Types.Image
      { media_type = "image/tiff"; data = "aGk="; source_type = Agent_core.Types.Base64 }
  in
  match Keeper_muse_runtime.For_testing.muse_images_of_goal_blocks [ block ] with
  | Ok _ -> fail "an uncarriable media type must be refused"
  | Error _ -> ()
;;

let test_non_base64_image_is_refused () =
  let block =
    Agent_core.Types.Image
      { media_type = "image/png"
      ; data = "!!! not base64 !!!"
      ; source_type = Agent_core.Types.Base64
      }
  in
  match Keeper_muse_runtime.For_testing.muse_images_of_goal_blocks [ block ] with
  | Ok _ -> fail "undecodable bytes must be refused"
  | Error _ -> ()
;;

let () =
  run
    "keeper_muse_runtime"
    [ ( "stream projection"
      , [ test_case "usage event reports turn total" `Quick test_usage_event_reports_turn_total
        ; test_case "non-usage events report nothing" `Quick test_non_usage_events_report_nothing
        ]
      )
    ; ("prompt framing", [ test_case "start bytes pinned" `Quick test_start_prompt_bytes_pins_framing ])
    ; ( "goal images"
      , [ test_case "goal images become files" `Quick test_goal_images_become_files
        ; test_case "unknown media type refused" `Quick test_unknown_media_type_is_refused
        ; test_case "non-base64 refused" `Quick test_non_base64_image_is_refused
        ]
      )
    ]
;;
