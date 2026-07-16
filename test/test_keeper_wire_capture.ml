(** Tests for [Keeper_wire_capture] (Phase O observability).

    Covers: env-flag parsing, disabled = no filesystem writes, and enabled =
    one redacted dated jsonl with the expected fields. *)

module Wire = Masc.Keeper_wire_capture
module Keeper_metrics = Keeper_metrics
module Metrics = Masc.Otel_metric_store
module Secret_projection = Masc.Keeper_secret_projection

let flag = "MASC_KEEPER_WIRE_CAPTURE"

external unsetenv : string -> unit = "masc_test_unsetenv"

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv key v
      | None -> unsetenv key)
    f

let with_flag value f = with_env flag value f

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      i + nl <= hl && (String.equal (String.sub haystack i nl) needle || loop (i + 1))
    in
    loop 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let ensure_dir path =
  if Sys.file_exists path then ()
  else Unix.mkdir path 0o755

(* Recursively collect every *.jsonl under [dir]. *)
let rec find_jsonl dir =
  if not (Sys.file_exists dir) then []
  else if Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.concat_map (fun e -> find_jsonl (Filename.concat dir e))
  else if Filename.check_suffix dir ".jsonl" then [ dir ]
  else []

let parse_single_jsonl content =
  let lines =
    String.split_on_char '\n' content
    |> List.filter (fun line -> not (String.equal "" (String.trim line)))
  in
  match lines with
  | [ line ] -> Yojson.Safe.from_string line
  | _ -> Alcotest.failf "expected exactly one JSONL record, got %d" (List.length lines)
;;

let read_single_json_record base =
  let files = find_jsonl base in
  Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
  read_file (List.hd files) |> parse_single_jsonl
;;

let json_member key json = Yojson.Safe.Util.member key json

let json_string key json =
  match json_member key json with
  | `String value -> value
  | other ->
    Alcotest.failf "field %s must be string, got %s" key (Yojson.Safe.to_string other)
;;

let check_json_string label key expected json =
  Alcotest.(check string) label expected (json_string key json)
;;

let check_json_int label key expected json =
  match json_member key json with
  | `Int actual -> Alcotest.(check int) label expected actual
  | other ->
    Alcotest.failf "field %s must be int, got %s" key (Yojson.Safe.to_string other)
;;

let check_json_bool label key expected json =
  match json_member key json with
  | `Bool actual -> Alcotest.(check bool) label expected actual
  | other ->
    Alcotest.failf "field %s must be bool, got %s" key (Yojson.Safe.to_string other)
;;

let check_json_null label key json =
  match json_member key json with
  | `Null -> ()
  | other ->
    Alcotest.failf "%s: field %s must be null, got %s" label key
      (Yojson.Safe.to_string other)
;;

let json_list key json =
  match json_member key json with
  | `List items -> items
  | other ->
    Alcotest.failf "field %s must be list, got %s" key (Yojson.Safe.to_string other)
;;

let check_json_list_length label key expected json =
  Alcotest.(check int) label expected (List.length (json_list key json))
;;

let metric_value name ~labels =
  Metrics.metric_value_or_zero name ~labels ()
;;

let check_metric_delta label name ~labels f =
  let before = metric_value name ~labels in
  f ();
  let after = metric_value name ~labels in
  Alcotest.(check (float 0.0001)) label (before +. 1.0) after
;;

let write_failures_metric = Keeper_metrics.(to_string WireCaptureWriteFailures)
let record_skipped_metric = Keeper_metrics.(to_string WireCaptureRecordSkipped)

(* Regression guard: verify in [Keeper_agent_run.run_turn] that the response
   capture happens after normalization and uses the normalized identifier.

   Dune test actions run in a sandbox, so we locate the source tree via
   [DUNE_SOURCEROOT] (set by Dune for all actions). *)
let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None ->
    Alcotest.fail "DUNE_SOURCEROOT is not set; cannot locate source file"

let first_line_of path needle =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
       let rec loop line_num =
         match input_line ic with
         | line ->
           if contains ~needle line then Some line_num else loop (line_num + 1)
         | exception End_of_file -> None
       in
       loop 1)
;;

let last_line_of path needle =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
       let rec loop line_num last_seen =
         match input_line ic with
         | line ->
           let last_seen =
             if contains ~needle line then Some line_num else last_seen
           in
           loop (line_num + 1) last_seen
         | exception End_of_file -> last_seen
       in
       loop 1 None)
;;

let projected_secret = "wire-capture-projected-secret-value"

let install_projected_secret ~base_path ~keeper_name =
  match
    Secret_projection.set_env_entry
      ~base_path
      ~keeper_name
      ~scope:Secret_projection.Keeper_secret
      ~name:"WIRE_CAPTURE_TEST_SECRET"
      ~value:projected_secret
  with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "failed to install projected secret: %s" detail

let check_enabled_value label value expected =
  with_flag value (fun () -> Alcotest.(check bool) label expected (Wire.enabled ()))

let enabled_parsing () =
  check_enabled_value "1 enables" "1" true;
  check_enabled_value "true enables" "true" true;
  check_enabled_value "YES (case-insensitive) enables" "YES" true;
  check_enabled_value "on enables" "on" true;
  check_enabled_value "empty disables" "" false;
  check_enabled_value "0 disables" "0" false;
  check_enabled_value "unknown value disables" "nope" false

let env_is_restored () =
  unsetenv flag;
  Alcotest.(check (option string)) "starts unset" None (Sys.getenv_opt flag);
  with_flag "1" (fun () ->
    Alcotest.(check bool) "enabled inside scope" true (Wire.enabled ()));
  Alcotest.(check (option string)) "restored unset" None (Sys.getenv_opt flag)

let disabled_is_noop () =
  with_flag "" (fun () ->
    let base = Filename.temp_dir "wirecap_off" "" in
    Wire.capture_request ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:1
      ~sdk_turn:1 ~system_prompt:"sys" ~extra_system_context:None
      ~user_message:"u" ~history_messages:[] ();
    Alcotest.(check (list string))
      "no jsonl written when disabled" [] (find_jsonl base))

let enabled_writes_redacted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_on" "" in
    install_projected_secret ~base_path:base ~keeper_name:"sangsu";
    let history =
      [
        Agent_sdk.Types.assistant_msg "좋아, 연구 시작한다";
        Agent_sdk.Types.user_msg "continue";
      ]
    in
    Wire.capture_request ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:7
      ~sdk_turn:3
      ~system_prompt:("token " ^ projected_secret ^ " end")
      ~extra_system_context:(Some "dynamic context")
      ~user_message:"hello world" ~history_messages:history ();
    let files = find_jsonl base in
    Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
    let content = read_file (List.hd files) in
    let json = parse_single_jsonl content in
    Alcotest.(check bool) "projected secret is redacted" false
      (contains ~needle:projected_secret content);
    Alcotest.(check bool) "redaction marker present" true
      (contains ~needle:"[REDACTED]" (json_string "system_prompt" json));
    check_json_string "request kind recorded" "kind" "request" json;
    check_json_string "keeper name recorded" "keeper" "sangsu" json;
    check_json_int "turn_id recorded" "turn_id" 7 json;
    check_json_int "sdk_turn recorded" "sdk_turn" 3 json;
    check_json_null "missing trace_id is null" "trace_id" json;
    check_json_string "extra context recorded" "extra_system_context"
      "dynamic context" json;
    check_json_bool "extra context presence recorded"
      "extra_system_context_present" true json;
    check_json_string "user message recorded" "user_message" "hello world" json;
    check_json_int "history_message_count recorded" "history_message_count" 2
      json;
    check_json_list_length "history length" "history" 2 json;
    let history_json = json_list "history" json in
    (match history_json with
     | [ assistant; user ] ->
       check_json_string "assistant role recorded" "role" "assistant" assistant;
       check_json_string "assistant text recorded" "text"
         "좋아, 연구 시작한다" assistant;
       check_json_string "user role recorded" "role" "user" user;
       check_json_string "user text recorded" "text" "continue" user
     | _ -> Alcotest.fail "history shape should have been checked above"))

let request_trace_id_emitted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_req_trace" "" in
    let trace_id = Keeper_id.For_testing.unsafe_trace_id_of_string "trace-req-abc" in
    Wire.capture_request ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:1
      ~trace_id ~sdk_turn:1 ~system_prompt:"sys" ~extra_system_context:None
      ~user_message:"hello" ~history_messages:[] ();
    let json = read_single_json_record base in
    check_json_string "request trace_id string recorded" "trace_id"
      "trace-req-abc" json)

let request_capture_failure_is_best_effort () =
  with_flag "1" (fun () ->
    let keeper_name = "wirecap_request_failure_metric" in
    let turn_id = 31 in
    let root_file = Filename.temp_file "wirecap_root_file" "" in
    let labels =
      [ ("keeper", keeper_name)
      ; ("turn_id", string_of_int turn_id)
      ; ("site", "request")
      ]
    in
    check_metric_delta "request write failure metric increments"
      write_failures_metric ~labels (fun () ->
        Wire.capture_request ~base_path:root_file ~masc_root:root_file ~keeper_name
          ~turn_id
          ~sdk_turn:1 ~system_prompt:"sys" ~extra_system_context:None
          ~user_message:"hello" ~history_messages:[] ()))

let response_disabled_is_noop () =
  with_flag "" (fun () ->
    let base = Filename.temp_dir "wirecap_resp_off" "" in
    Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:1
      ~sdk_turn:2 ~response_text:"anything" ();
    Alcotest.(check (list string))
      "no jsonl written when disabled" [] (find_jsonl base))

let response_capture_writes_redacted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_resp_on" "" in
    install_projected_secret ~base_path:base ~keeper_name:"sangsu";
    Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:9
      ~sdk_turn:4 ~response_text:("out " ^ projected_secret ^ " done") ();
    let files = find_jsonl base in
    Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
    let content = read_file (List.hd files) in
    let json = parse_single_jsonl content in
    check_json_string "response kind recorded" "kind" "response" json;
    Alcotest.(check bool) "projected secret is redacted" false
      (contains ~needle:projected_secret content);
    Alcotest.(check bool) "redaction marker present" true
      (contains ~needle:"[REDACTED]" (json_string "response_text" json));
    check_json_string "keeper name recorded" "keeper" "sangsu" json;
    check_json_int "turn_id recorded" "turn_id" 9 json;
    check_json_int "sdk_turn recorded" "sdk_turn" 4 json;
    check_json_null "missing trace_id is null" "trace_id" json)

let response_capture_failure_is_best_effort () =
  with_flag "1" (fun () ->
    let keeper_name = "wirecap_response_failure_metric" in
    let turn_id = 32 in
    let root_file = Filename.temp_file "wirecap_response_root_file" "" in
    let labels =
      [ ("keeper", keeper_name)
      ; ("turn_id", string_of_int turn_id)
      ; ("site", "response")
      ]
    in
    check_metric_delta "response write failure metric increments"
      write_failures_metric ~labels (fun () ->
        Wire.capture_response ~base_path:root_file ~masc_root:root_file ~keeper_name
          ~turn_id
          ~sdk_turn:1 ~response_text:"ok" ()))

let response_trace_id_emitted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_resp_trace" "" in
    let trace_id = Keeper_id.For_testing.unsafe_trace_id_of_string "trace-resp-xyz" in
    Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
      ~turn_id:2
      ~sdk_turn:1 ~trace_id ~response_text:"ok" ();
    let json = read_single_json_record base in
    check_json_string "response trace_id string recorded" "trace_id"
      "trace-resp-xyz" json)

let capture_prunes_old_files () =
  with_flag "1" (fun () ->
    with_env "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" "1" (fun () ->
      with_env "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" "4096" (fun () ->
        let base = Filename.temp_dir "wirecap_prune" "" in
        let capture_dir = Filename.concat base "wire-capture" in
        let old_month = Filename.concat capture_dir "2000-01" in
        ensure_dir capture_dir;
        ensure_dir old_month;
        let old_file = Filename.concat old_month "01.jsonl" in
        write_file old_file (String.make 1024 'x');
        Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
          ~turn_id:10
          ~sdk_turn:1 ~response_text:"bounded" ();
        Alcotest.(check bool) "old capture file pruned" false
          (Sys.file_exists old_file);
        Alcotest.(check int) "only current capture remains" 1
          (List.length (find_jsonl base)))))

let capture_cache_reloads_when_retention_changes () =
  with_flag "1" (fun () ->
    with_env "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" "4096" (fun () ->
      let base = Filename.temp_dir "wirecap_cache_retention" "" in
      let capture_dir = Filename.concat base "wire-capture" in
      let old_ts = Unix.gettimeofday () -. (2. *. 24. *. 60. *. 60.) in
      let old_tm = Unix.gmtime old_ts in
      let old_month_name =
        Printf.sprintf "%04d-%02d"
          (old_tm.Unix.tm_year + 1900)
          (old_tm.Unix.tm_mon + 1)
      in
      let old_day_name = Printf.sprintf "%02d.jsonl" old_tm.Unix.tm_mday in
      let old_month = Filename.concat capture_dir old_month_name in
      ensure_dir capture_dir;
      ensure_dir old_month;
      let old_file = Filename.concat old_month old_day_name in
      write_file old_file (String.make 1024 'x');
      with_env "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" "30" (fun () ->
        Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
          ~turn_id:20
          ~sdk_turn:1 ~response_text:"cache warmup" ());
      Alcotest.(check bool) "old capture retained by warm cache" true
        (Sys.file_exists old_file);
      with_env "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" "1" (fun () ->
        Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name:"sangsu"
          ~turn_id:21
          ~sdk_turn:1 ~response_text:"cache reload" ());
      Alcotest.(check bool) "old capture pruned after retention change" false
        (Sys.file_exists old_file)))

let capture_skips_when_current_file_cap_would_be_exceeded () =
  with_flag "1" (fun () ->
    with_env "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" "512" (fun () ->
      let base = Filename.temp_dir "wirecap_cap" "" in
      let keeper_name = "wirecap_cap_metric" in
      Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name ~turn_id:11
        ~sdk_turn:1 ~response_text:"small" ();
      let files = find_jsonl base in
      Alcotest.(check int) "small record written" 1 (List.length files);
      let before = read_file (List.hd files) in
      let labels =
        [ ("keeper", keeper_name)
        ; ("turn_id", "12")
        ; ("reason", "current_file_byte_cap")
        ]
      in
      let legacy_labels =
        [ ("keeper", keeper_name); ("turn_id", "12"); ("reason", "cap") ]
      in
      let legacy_before = metric_value record_skipped_metric ~labels:legacy_labels in
      check_metric_delta "current-file cap skip metric increments"
        record_skipped_metric ~labels (fun () ->
          Wire.capture_response ~base_path:base ~masc_root:base ~keeper_name
            ~turn_id:12
            ~sdk_turn:1 ~response_text:(String.make 4096 'x') ());
      let after = read_file (List.hd files) in
      Alcotest.(check string)
        "oversized record skipped without mutating current day file"
        before
        after;
      Alcotest.(check (float 0.0001))
        "legacy cap reason label is not incremented"
        legacy_before
        (metric_value record_skipped_metric ~labels:legacy_labels)))

let response_capture_matches_replayed_history_text () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_history_match" "" in
    let raw_response = "   " in
    let tool_names = [ "keeper_web_fetch"; "keeper_file_read" ] in
    let history_text =
      match
        Keeper_tool_response.normalize_response_text
          ~text:raw_response
          ~tool_names
          ()
      with
      | Ok t -> t
      | Error _ ->
        Alcotest.fail "normalization should synthesize text when tools are present"
    in
    Wire.capture_response
      ~base_path:base
      ~masc_root:base
      ~keeper_name:"history_keeper"
      ~turn_id:5
      ~sdk_turn:2
      ~response_text:history_text
      ();
    let files = find_jsonl base in
    Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
    let content = read_file (List.hd files) in
    Alcotest.(check bool)
      "synthetic replayed history text is captured"
      true
      (contains ~needle:history_text content);
    Alcotest.(check bool)
      "raw whitespace response is not captured as the replayed text"
      false
      (contains ~needle:raw_response content))

let capture_response_uses_finalized_replay_text () =
  let run_path = Filename.concat (repo_root ()) "lib/keeper/keeper_agent_run.ml" in
  let capture_line =
    match first_line_of run_path "Keeper_wire_capture.capture_response" with
    | Some n -> n
    | None -> Alcotest.fail "Keeper_wire_capture.capture_response call not found"
  in
  let normalize_line =
    match first_line_of run_path "normalize_response_text_for_finalization" with
    | Some n -> n
    | None ->
      Alcotest.fail "normalize_response_text_for_finalization call not found"
  in
  Alcotest.(check bool)
    "capture_response occurs after normalize_response_text_for_finalization"
    true
    (capture_line > normalize_line);
  let finalizer_line =
    match first_line_of run_path "Keeper_agent_run_finalize_response.finalize" with
    | Some n -> n
    | None -> Alcotest.fail "Keeper_agent_run_finalize_response.finalize call not found"
  in
  Alcotest.(check bool)
    "capture_response is delegated through finalize callback"
    true
    (capture_line > finalizer_line);
  let finalize_path =
    Filename.concat (repo_root ())
      "lib/keeper/keeper_agent_run_finalize_response.ml"
  in
  let replay_decision_line =
    match last_line_of finalize_path "replay_response_text_for_capture" with
    | Some n -> n
    | None -> Alcotest.fail "replay_response_text_for_capture use not found"
  in
  let capture_callback_line =
    match last_line_of finalize_path "capture_replay_response ~response_text" with
    | Some n -> n
    | None -> Alcotest.fail "capture_replay_response invocation not found"
  in
  Alcotest.(check bool)
    "capture callback runs after replay-visible response decision"
    true
    (capture_callback_line > replay_decision_line)

let () =
  Alcotest.run "keeper_wire_capture"
    [
      ( "enabled",
        [
          Alcotest.test_case "env flag parsing" `Quick enabled_parsing;
          Alcotest.test_case "env scope restores unset" `Quick env_is_restored;
        ] );
      ( "capture_request",
        [
          Alcotest.test_case "disabled is a no-op" `Quick disabled_is_noop;
          Alcotest.test_case "enabled writes redacted jsonl" `Quick
            enabled_writes_redacted;
          Alcotest.test_case "write failure is best effort" `Quick
            request_capture_failure_is_best_effort;
          Alcotest.test_case "trace_id is emitted when provided" `Quick
            request_trace_id_emitted;
        ] );
      ( "capture_response",
        [
          Alcotest.test_case "disabled is a no-op" `Quick
            response_disabled_is_noop;
          Alcotest.test_case "enabled writes redacted jsonl" `Quick
            response_capture_writes_redacted;
          Alcotest.test_case "write failure is best effort" `Quick
            response_capture_failure_is_best_effort;
          Alcotest.test_case "capture store prunes old files" `Quick
            capture_prunes_old_files;
          Alcotest.test_case "capture store reloads on retention change" `Quick
            capture_cache_reloads_when_retention_changes;
          Alcotest.test_case "current file cap skips oversized record" `Quick
            capture_skips_when_current_file_cap_would_be_exceeded;
          Alcotest.test_case "trace_id is emitted when provided" `Quick
            response_trace_id_emitted;
          Alcotest.test_case "captured response matches replayed history text"
            `Quick response_capture_matches_replayed_history_text;
        ] );
      ( "run_turn_ordering",
        [
          Alcotest.test_case "capture_response uses normalized response text"
            `Quick capture_response_uses_finalized_replay_text;
        ] );
    ]
