(* slack-lane reader tool (task-1430) — handler-level unit tests.

   No Slack, no REST: the handler reads the in-memory lane buffer, so the
   tests seed {!Slack_lane} directly and pin the three contracts — the
   summary, the newest-first channel read, and the explicit-empty answer
   that keeps "nothing buffered" from reading as "the channel is quiet". *)

open Alcotest
module Lane = Slack_lane

let handle assoc =
  Tool_misc_slack_lane.handle_read
    ~tool_name:"masc_slack_read"
    ~start_time:0.0
    (`Assoc assoc)
;;

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let contains_sub needle haystack =
  let len = String.length needle in
  let hay_len = String.length haystack in
  let rec loop i =
    if i + len > hay_len then false
    else if String.sub haystack i len = needle then true
    else loop (i + 1)
  in
  loop 0
;;

let seeded () =
  Lane.clear ();
  Lane.push_many
    ~channel_id:"C1"
    [ { Lane.channel_id = "C1"; ts = "1.000000"; user_id = "U1"
      ; text = "first"; received_unix = 0.0 }
    ; { Lane.channel_id = "C1"; ts = "2.000000"; user_id = "U2"
      ; text = "second"; received_unix = 0.0 }
    ]
    ~capacity:10;
  Lane.push_many
    ~channel_id:"C2"
    [ { Lane.channel_id = "C2"; ts = "3.000000"; user_id = "U1"
      ; text = "other channel"; received_unix = 0.0 }
    ]
    ~capacity:10
;;

let ts_list json =
  match member "messages" json with
  | Some (`List items) ->
    List.filter_map
      (fun item -> match member "ts" item with Some (`String ts) -> Some ts | _ -> None)
      items
  | _ -> []
;;

let test_summary_empty () =
  Lane.clear ();
  let r = handle [] in
  check bool "empty lane succeeds" (Tool_result.failure_class r = None) true;
  (match member "channels" (Tool_result.data r) with
   | Some (`List []) -> ()
   | other -> failwith ("expected empty channel list, got " ^ Yojson.Safe.to_string (Option.value other ~default:`Null))
  );
  check bool "empty note present"
    (match member "note" (Tool_result.data r) with
     | Some (`String note) -> String.length note > 0
     | _ -> false)
    true
;;

let test_summary_seeded () =
  seeded ();
  let r = handle [] in
  check bool "summary succeeds" (Tool_result.failure_class r = None) true;
  (match member "channels" (Tool_result.data r) with
   | Some (`List channels) ->
     check int "two channels" 2 (List.length channels);
     (* counts survive the summary: C1 buffered two, C2 one. *)
     let rendered = Yojson.Safe.to_string (`List channels) in
     let has pair = String.length pair > 0 && contains_sub pair rendered in
     check bool "C1 count" (has "\"buffered\":2") true;
     check bool "C2 count" (has "\"buffered\":1") true
   | other ->
     failwith ("expected channel list, got " ^ Yojson.Safe.to_string (Option.value other ~default:`Null)))
;;

let test_channel_read_newest_first () =
  seeded ();
  let r = handle [ ("channel_id", `String "C1") ] in
  check bool "read succeeds" (Tool_result.failure_class r = None) true;
  check bool "newest first"
    (ts_list (Tool_result.data r) = [ "2.000000"; "1.000000" ])
    true
;;

let test_channel_read_limit () =
  seeded ();
  let r = handle [ ("channel_id", `String "C1"); ("limit", `Int 1) ] in
  check bool "limit read succeeds" (Tool_result.failure_class r = None) true;
  check bool "only the newest" (ts_list (Tool_result.data r) = [ "2.000000" ]) true
;;

let test_channel_read_empty_is_explicit () =
  seeded ();
  (* C3 exists in Slack terms but has nothing buffered: the tool says so
     instead of returning a bare empty list. *)
  let r = handle [ ("channel_id", `String "C3") ] in
  check bool "empty read succeeds" (Tool_result.failure_class r = None) true;
  check bool "messages empty" (ts_list (Tool_result.data r) = []) true;
  check bool "note explains the empty"
    (match member "note" (Tool_result.data r) with
     | Some (`String note) -> String.length note > 0
     | _ -> false)
    true
;;

let test_bad_action_is_a_workflow_error () =
  let r = handle [ ("action", `String "thread") ] in
  check bool "failed"
    (Tool_result.failure_class r = Some Tool_result.Workflow_rejection) true;
  check bool "message names the constraint"
    (let m = Tool_result.message r in contains_sub "action must be" m)
    true
;;

let () =
  run "slack_read_tool"
    [ ( "summary"
      , [ test_case "empty lane" `Quick test_summary_empty
        ; test_case "seeded lane" `Quick test_summary_seeded ] )
    ; ( "read"
      , [ test_case "newest first" `Quick test_channel_read_newest_first
        ; test_case "limit" `Quick test_channel_read_limit
        ; test_case "empty is explicit" `Quick test_channel_read_empty_is_explicit ] )
    ; ( "validation"
      , [ test_case "bad action" `Quick test_bad_action_is_a_workflow_error ] )
    ]
;;
