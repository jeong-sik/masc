(** Tests for [Keeper_wire_capture] (Phase O observability).

    Covers: env-flag parsing, disabled = no filesystem writes, and enabled =
    one redacted dated jsonl with the expected fields. *)

module Wire = Masc.Keeper_wire_capture

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

(* Built at runtime so no literal secret appears in the source (the pre-commit
   secret scanner rejects literal [ghp_...] tokens). Secret_redactor detects the
   [ghp_] prefix regardless. *)
let fake_github_token = "ghp_" ^ String.make 36 '7'

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
    Wire.capture_request ~masc_root:base ~keeper_name:"sangsu" ~turn_id:1
      ~sdk_turn:0 ~system_prompt:"sys" ~extra_system_context:None
      ~user_message:"u" ~history_messages:[];
    Alcotest.(check (list string))
      "no jsonl written when disabled" [] (find_jsonl base))

let enabled_writes_redacted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_on" "" in
    let history =
      [
        Agent_sdk.Types.assistant_msg "좋아, 연구 시작한다";
        Agent_sdk.Types.user_msg "continue";
      ]
    in
    Wire.capture_request ~masc_root:base ~keeper_name:"sangsu" ~turn_id:7
      ~sdk_turn:3
      ~system_prompt:("token " ^ fake_github_token ^ " end")
      ~extra_system_context:(Some "dynamic context")
      ~user_message:"hello world" ~history_messages:history;
    let files = find_jsonl base in
    Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
    let content = read_file (List.hd files) in
    Alcotest.(check bool) "raw github token is redacted" false
      (contains ~needle:fake_github_token content);
    Alcotest.(check bool) "redaction marker present" true
      (contains ~needle:"[REDACTED]" content);
    Alcotest.(check bool) "history_message_count recorded" true
      (contains ~needle:"\"history_message_count\":2" content);
    Alcotest.(check bool) "keeper name recorded" true
      (contains ~needle:"sangsu" content);
    Alcotest.(check bool) "turn_id recorded" true
      (contains ~needle:"\"turn_id\":7" content);
    Alcotest.(check bool) "sdk_turn recorded" true
      (contains ~needle:"\"sdk_turn\":3" content);
    Alcotest.(check bool) "assistant role recorded" true
      (contains ~needle:"\"role\":\"assistant\"" content);
    Alcotest.(check bool) "user role recorded" true
      (contains ~needle:"\"role\":\"user\"" content);
    Alcotest.(check bool) "extra context recorded" true
      (contains ~needle:"dynamic context" content);
    Alcotest.(check bool) "replayed history text recorded" true
      (contains ~needle:"좋아, 연구 시작한다" content);
    Alcotest.(check bool) "request kind recorded" true
      (contains ~needle:"\"kind\":\"request\"" content))

let request_capture_failure_is_best_effort () =
  with_flag "1" (fun () ->
    let root_file = Filename.temp_file "wirecap_root_file" "" in
    Wire.capture_request ~masc_root:root_file ~keeper_name:"sangsu" ~turn_id:1
      ~sdk_turn:0 ~system_prompt:"sys" ~extra_system_context:None
      ~user_message:"hello" ~history_messages:[])

let response_disabled_is_noop () =
  with_flag "" (fun () ->
    let base = Filename.temp_dir "wirecap_resp_off" "" in
    Wire.capture_response ~masc_root:base ~keeper_name:"sangsu" ~turn_id:1
      ~response_text:"anything";
    Alcotest.(check (list string))
      "no jsonl written when disabled" [] (find_jsonl base))

let response_capture_writes_redacted () =
  with_flag "1" (fun () ->
    let base = Filename.temp_dir "wirecap_resp_on" "" in
    Wire.capture_response ~masc_root:base ~keeper_name:"sangsu" ~turn_id:9
      ~response_text:("out " ^ fake_github_token ^ " done");
    let files = find_jsonl base in
    Alcotest.(check int) "exactly one jsonl written" 1 (List.length files);
    let content = read_file (List.hd files) in
    Alcotest.(check bool) "response kind recorded" true
      (contains ~needle:"\"kind\":\"response\"" content);
    Alcotest.(check bool) "raw github token is redacted" false
      (contains ~needle:fake_github_token content);
    Alcotest.(check bool) "turn_id recorded" true
      (contains ~needle:"\"turn_id\":9" content))

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
        Wire.capture_response ~masc_root:base ~keeper_name:"sangsu" ~turn_id:10
          ~response_text:"bounded";
        Alcotest.(check bool) "old capture file pruned" false
          (Sys.file_exists old_file);
        Alcotest.(check int) "only current capture remains" 1
          (List.length (find_jsonl base)))))

let capture_skips_when_current_file_cap_would_be_exceeded () =
  with_flag "1" (fun () ->
    with_env "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" "512" (fun () ->
      let base = Filename.temp_dir "wirecap_cap" "" in
      Wire.capture_response ~masc_root:base ~keeper_name:"sangsu" ~turn_id:11
        ~response_text:"small";
      let files = find_jsonl base in
      Alcotest.(check int) "small record written" 1 (List.length files);
      let before = read_file (List.hd files) in
      Wire.capture_response ~masc_root:base ~keeper_name:"sangsu" ~turn_id:12
        ~response_text:(String.make 4096 'x');
      let after = read_file (List.hd files) in
      Alcotest.(check string)
        "oversized record skipped without mutating current day file"
        before
        after))

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
      ~masc_root:base
      ~keeper_name:"history_keeper"
      ~turn_id:5
      ~response_text:history_text;
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
        ] );
      ( "capture_response",
        [
          Alcotest.test_case "disabled is a no-op" `Quick
            response_disabled_is_noop;
          Alcotest.test_case "enabled writes redacted jsonl" `Quick
            response_capture_writes_redacted;
          Alcotest.test_case "capture store prunes old files" `Quick
            capture_prunes_old_files;
          Alcotest.test_case "current file cap skips oversized record" `Quick
            capture_skips_when_current_file_cap_would_be_exceeded;
          Alcotest.test_case "captured response matches replayed history text"
            `Quick response_capture_matches_replayed_history_text;
        ] );
      ( "run_turn_ordering",
        [
          Alcotest.test_case "capture_response uses normalized response text"
            `Quick capture_response_uses_finalized_replay_text;
        ] );
    ]
