(* The records below have the shape Kimi Code 2.7.3 writes to
   [agents/main/wire.jsonl]: the [metadata] record that opens the file, and the
   three records of one automatic compaction, with the fields they carried on
   2026-11-27. The summary text of [context.apply_compaction] is replaced,
   because the reader reads only [type]. *)

open Alcotest
module Log = Runtime_kimi_session_log

let metadata_record ~version =
  Printf.sprintf
    {|{"type":"metadata","protocol_version":"%s","created_at":1795719946656,"min_protocol_version":"1.5"}|}
    version
;;

let binding_record =
  {|{"type":"environment.set_binding","environmentId":"local","agentId":"main","time":1795719946672}|}
;;

let prompt_record = {|{"type":"turn.prompt","agentId":"main","time":1795719947000}|}

let compaction_records =
  [ {|{"type":"full_compaction.begin","source":"auto","agentId":"main","time":1795711868403}|}
  ; {|{"type":"context.apply_compaction","agentId":"main","summary":"(summary)"}|}
  ; {|{"type":"full_compaction.complete","agentId":"main","time":1795712047889}|}
  ]
;;

(* The [turn.ended] record of a prompt the weekly usage limit refused, with the
   fields Kimi Code 2.7.3 wrote on 2026-11-27 (trace id and time replaced). *)
let weekly_limit_record =
  {|{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","durationMs":1194,"modelSteps":1,"error":{"code":"provider.api_error","message":"You've reached your weekly (7-day) usage limit.","name":"APIProviderQuotaExhaustedError","details":{"requestId":null,"statusCode":429,"traceId":"t"},"retryable":false},"time":1795768797761}|}
;;

let completed_record =
  {|{"type":"turn.ended","agentId":"main","turnId":1,"reason":"completed","durationMs":900,"modelSteps":2,"time":1795768800000}|}
;;

let text_of records = String.concat "" (List.map (fun record -> record ^ "\n") records)

(* ── A sessions directory in a temporary home ────────────────────────────── *)

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path
;;

let with_home f =
  let home = Filename.temp_dir "kimi-session-log-" "" in
  Fun.protect ~finally:(fun () -> remove_tree home) (fun () -> f home)
;;

let rec make_directories path =
  if not (Sys.file_exists path)
  then (
    make_directories (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let record_path home ~workspace ~id =
  List.fold_left
    Filename.concat
    home
    [ "sessions"; workspace; id; "agents"; "main"; "wire.jsonl" ]
;;

let write_file path contents =
  make_directories (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc contents)
;;

let append_file path contents =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o644 path (fun oc ->
    Out_channel.output_string oc contents)
;;

let error_t =
  testable (fun ppf err -> Format.pp_print_string ppf (Log.error_to_string err)) ( = )
;;

let root_of home =
  match Log.root_of_environment [| "KIMI_CODE_HOME=" ^ home |] with
  | Ok root -> root
  | Error err -> failf "no root for %s: %s" home (Log.error_to_string err)
;;

let session_id = "session_1ab767e7-b14a-402b-b453-596fc06b7a68"
let workspace = "wd_masc-acp-iso-keeper-uncle_60671a603fa0"

let mark_of home =
  match Log.mark (root_of home) ~session_id with
  | Ok mark -> mark
  | Error err -> failf "mark failed: %s" (Log.error_to_string err)
;;

let check_compactions name expected mark =
  check
    (result int error_t)
    name
    (Ok expected)
    (Result.map (fun (record, _) -> record.Log.compactions) (Log.read_prompt mark))
;;

let next_of mark =
  match Log.read_prompt mark with
  | Ok (_, next) -> next
  | Error err -> failf "count failed: %s" (Log.error_to_string err)
;;

(* ── Where the record is ─────────────────────────────────────────────────── *)

let test_root_of_environment () =
  let root env = Result.map Log.root_directory (Log.root_of_environment env) in
  let check_root name expected env = check (result string error_t) name expected (root env) in
  check_root "KIMI_CODE_HOME wins" (Ok "/k/sessions") [| "HOME=/h"; "KIMI_CODE_HOME=/k" |];
  check_root "HOME when KIMI_CODE_HOME is unset" (Ok "/h/.kimi-code/sessions") [| "HOME=/h" |];
  check_root
    "an empty KIMI_CODE_HOME is unset"
    (Ok "/h/.kimi-code/sessions")
    [| "HOME=/h"; "KIMI_CODE_HOME=" |];
  check_root
    "a variable with a longer name is not KIMI_CODE_HOME"
    (Ok "/h/.kimi-code/sessions")
    [| "HOME=/h"; "KIMI_CODE_HOME_OLD=/k" |];
  (* The host would read a relative KIMI_CODE_HOME against its own working
     directory, which masc does not resolve. *)
  check_root
    "a relative KIMI_CODE_HOME is not guessed"
    (Error Log.Home_unavailable)
    [| "HOME=/h"; "KIMI_CODE_HOME=kimi" |];
  check_root "a relative HOME is no directory" (Error Log.Home_unavailable) [| "HOME=h" |];
  check_root "an empty environment" (Error Log.Home_unavailable) [||]
;;

let test_locate_errors () =
  with_home (fun home ->
    let root = root_of home in
    let mark id = Result.map (fun _ -> ()) (Log.mark root ~session_id:id) in
    check
      (result unit error_t)
      "a missing sessions directory"
      (Error (Log.Session_record_not_found { searched = Log.root_directory root; session_id }))
      (mark session_id);
    check
      (result unit error_t)
      "an id that names a parent directory"
      (Error (Log.Session_id_invalid ".."))
      (mark "..");
    check
      (result unit error_t)
      "an id with a separator"
      (Error (Log.Session_id_invalid "a/b"))
      (mark "a/b");
    let contents = text_of [ metadata_record ~version:"1.5" ] in
    write_file (record_path home ~workspace ~id:session_id) contents;
    write_file (record_path home ~workspace:"wd_other_0123456789ab" ~id:session_id) contents;
    match mark session_id with
    | Error (Log.Session_record_ambiguous { paths; _ }) ->
      check int "both workspace directories are named" 2 (List.length paths)
    | Ok () -> fail "a session held by two workspace directories was marked"
    | Error err -> failf "expected an ambiguous session, got %s" (Log.error_to_string err))
;;

let test_protocol_version_is_checked () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    let mark () = Result.map (fun _ -> ()) (Log.mark (root_of home) ~session_id) in
    write_file path (text_of [ metadata_record ~version:"1.6"; binding_record ]);
    check
      (result unit error_t)
      "another version"
      (Error (Log.Unsupported_protocol { path; found = Some "1.6"; supported = "1.5" }))
      (mark ());
    write_file path (text_of [ binding_record ]);
    check
      (result unit error_t)
      "no metadata record first"
      (Error (Log.Unsupported_protocol { path; found = None; supported = "1.5" }))
      (mark ());
    write_file path "";
    check
      (result unit error_t)
      "an empty file"
      (Error (Log.Unsupported_protocol { path; found = None; supported = "1.5" }))
      (mark ()))
;;

(* ── What the prompt added ────────────────────────────────────────────────── *)

let test_counts_the_compactions_after_the_mark () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    write_file
      path
      (text_of ((metadata_record ~version:"1.5" :: binding_record :: compaction_records) @ [ prompt_record ]));
    let mark = mark_of home in
    check_compactions "nothing written since the mark" 0 mark;
    append_file path (text_of (prompt_record :: compaction_records));
    check_compactions "one compaction since the mark" 1 mark;
    append_file path (text_of compaction_records);
    check_compactions "two compactions since the mark" 2 mark)
;;

let test_a_record_still_being_written_is_left_out () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    write_file path (text_of [ metadata_record ~version:"1.5"; binding_record ]);
    let mark = mark_of home in
    let apply = List.nth compaction_records 1 in
    append_file path apply;
    check_compactions "a record without its newline" 0 mark;
    append_file path "\n";
    check_compactions "the same record once it ends" 1 mark)
;;

let test_a_record_cut_by_the_mark_is_earlier_activity () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    let apply = List.nth compaction_records 1 in
    let half = String.length apply / 2 in
    write_file path (text_of [ metadata_record ~version:"1.5" ] ^ String.sub apply 0 half);
    let mark = mark_of home in
    append_file path (String.sub apply half (String.length apply - half) ^ "\n");
    check_compactions "the rest of a record begun before the mark" 0 mark;
    append_file path (text_of [ apply ]);
    check_compactions "a whole record after it" 1 mark)
;;

(* Each count returns where the next one starts, so consecutive counts see
   every record once, a record still being written included. *)
let test_the_next_count_starts_where_this_one_stopped () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    write_file path (text_of [ metadata_record ~version:"1.5"; binding_record ]);
    let mark = mark_of home in
    append_file path (text_of compaction_records);
    let apply = List.nth compaction_records 1 in
    append_file path apply;
    let second = next_of mark in
    check_compactions "the first count" 1 mark;
    check_compactions "nothing whole since the first count" 0 second;
    append_file path "\n";
    let third = next_of second in
    check_compactions "the record that ended after the first count" 1 second;
    check_compactions "nothing since the second count" 0 third)
;;

let test_unreadable_slices () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    let start = text_of [ metadata_record ~version:"1.5"; binding_record ] in
    write_file path start;
    let mark = mark_of home in
    append_file path "not json\n";
    (match Log.read_prompt mark with
     | Error (Log.Malformed_record { byte_offset; _ }) ->
       check int "the bad record's offset" (String.length start) byte_offset
     | Ok (record, _) -> failf "a record that is not JSON was read, count %d" record.Log.compactions
     | Error err -> failf "expected a malformed record, got %s" (Log.error_to_string err));
    write_file path start;
    append_file path {|{"agentId":"main"}|};
    append_file path "\n";
    (match Log.read_prompt mark with
     | Error (Log.Malformed_record _) -> ()
     | Ok (record, _) -> failf "a record without a type was read, count %d" record.Log.compactions
     | Error err -> failf "expected a malformed record, got %s" (Log.error_to_string err));
    write_file path (text_of [ metadata_record ~version:"1.5" ]);
    match Log.read_prompt mark with
    | Error (Log.Record_shrank { marked_at; _ }) ->
      check int "the length at the mark" (String.length start) marked_at
    | Ok (record, _) -> failf "a shrunk record was read, count %d" record.Log.compactions
    | Error err -> failf "expected a shrunk record, got %s" (Log.error_to_string err))
;;

let turn_end_name = function
  | None -> "none"
  | Some Log.Turn_completed -> "completed"
  | Some Log.Turn_cancelled -> "cancelled"
  | Some (Log.Turn_failed { code; message; status }) ->
    Printf.sprintf
      "failed %s %s %s"
      code
      (match status with
       | Some n -> string_of_int n
       | None -> "-")
      message
;;

let read_turn_end mark =
  match Log.read_prompt mark with
  | Ok (record, _) -> turn_end_name record.Log.turn_end
  | Error err -> failf "read failed: %s" (Log.error_to_string err)
;;

let test_reads_how_the_prompt_ended () =
  with_home (fun home ->
    let path = record_path home ~workspace ~id:session_id in
    write_file path (text_of [ metadata_record ~version:"1.5"; binding_record ]);
    let first = mark_of home in
    append_file path (text_of [ prompt_record ]);
    check string "a prompt the host has not ended" "none" (read_turn_end first);
    append_file path (text_of [ weekly_limit_record ]);
    check
      string
      "a prompt the weekly limit refused"
      "failed provider.api_error 429 You've reached your weekly (7-day) usage limit."
      (read_turn_end first);
    let second = next_of first in
    append_file path (text_of [ prompt_record; completed_record ]);
    check string "the next prompt reads only its own ending" "completed" (read_turn_end second);
    let third = next_of second in
    append_file
      path
      (text_of
         [ {|{"type":"turn.ended","agentId":"main","turnId":2,"reason":"paused","time":1}|} ]);
    (match Log.read_prompt third with
     | Error (Log.Malformed_record _) -> ()
     | Ok (record, _) ->
       failf "an unknown reason was read as %s" (turn_end_name record.Log.turn_end)
     | Error err -> failf "expected a malformed record, got %s" (Log.error_to_string err));
    write_file path (text_of [ metadata_record ~version:"1.5"; binding_record ]);
    let fresh = mark_of home in
    append_file
      path
      (text_of [ {|{"type":"turn.ended","agentId":"main","turnId":0,"reason":"failed","time":1}|} ]);
    match Log.read_prompt fresh with
    | Error (Log.Malformed_record _) -> ()
    | Ok (record, _) ->
      failf "a failure without its error was read as %s" (turn_end_name record.Log.turn_end)
    | Error err -> failf "expected a malformed record, got %s" (Log.error_to_string err))
;;

(* ── Through the ACP client ───────────────────────────────────────────────── *)

(* A stand-in for [kimi acp]: it creates the session record when the session is
   made, appends to it while a prompt runs, and like Kimi Code 2.7.3 sends one
   [usage_update] per prompt, just before the response. The prompt text says
   whether the prompt compacts, whether it fails or the weekly limit refuses it,
   and what [used] the update carries. *)
let kimi_mock_host_script =
  Printf.sprintf
    {|#!/usr/bin/env python3
import json, os, re, sys

SESSION = %S
WORKSPACE = %S
METADATA = %S
PROMPT_RECORD = %S
COMPACTION = %S
WEEKLY_LIMIT = %S
COMPLETED = %S

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

record = None

# The test removes the record before its last prompt; the host goes on.
def append(text):
    try:
        with open(record, "a", encoding="utf-8") as f:
            f.write(text)
    except FileNotFoundError:
        pass

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    mid = msg.get("id")
    if mid is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": True}
        }})
    elif method == "session/new":
        directory = os.path.join(
            os.environ["KIMI_CODE_HOME"], "sessions", WORKSPACE, SESSION, "agents", "main")
        os.makedirs(directory)
        record = os.path.join(directory, "wire.jsonl")
        append(METADATA)
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": SESSION}})
    elif method == "session/prompt":
        text = json.dumps(msg.get("params"))
        append(PROMPT_RECORD)
        if "compact" in text:
            append(COMPACTION)
        if "fail" in text:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": "mock failure"}})
            continue
        # Like Kimi Code 2.7.3 past the weekly limit: no message, end_turn, and
        # the cause only in the record.
        if "weekly" in text:
            append(WEEKLY_LIMIT)
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
            continue
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "pong"}}
        }})
        used = int(re.search(r"used=([0-9]+)", text).group(1))
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SESSION,
            "update": {"sessionUpdate": "usage_update", "used": used, "size": 1048576}
        }})
        append(COMPLETED)
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    else:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
|}
    session_id
    workspace
    (text_of [ metadata_record ~version:"1.5"; binding_record ])
    (text_of [ prompt_record ])
    (text_of compaction_records)
    (text_of [ weekly_limit_record ])
    (text_of [ completed_record ])
;;

let with_kimi_code_home dir f =
  let previous = Sys.getenv_opt "KIMI_CODE_HOME" in
  Unix.putenv "KIMI_CODE_HOME" dir;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv "KIMI_CODE_HOME" value
      | None -> Unix.unsetenv "KIMI_CODE_HOME")
    f
;;

let compaction_name = function
  | Runtime_acp_client.Not_compacted -> "not compacted"
  | Runtime_acp_client.Compacted -> "compacted"
  | Runtime_acp_client.Compaction_unknown unknown ->
    "unknown: " ^ Runtime_acp_client.compaction_unknown_to_string unknown
;;

let test_a_kimi_prompt_reads_its_compactions_from_the_session_record () =
  with_home (fun home ->
    let mock_script = Filename.concat home "mock_kimi.py" in
    Out_channel.with_open_text mock_script (fun oc -> output_string oc kimi_mock_host_script);
    with_kimi_code_home home (fun () ->
      Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let proc_mgr = Runtime_acp_client.foreground_process_mgr ~clock ~grace_seconds:1.0 () in
        let cfg =
          { (Runtime_acp_client.default_config ~driver:Runtime_acp_client.Kimi_code ~cwd:home) with
            cli_path = "python3"
          ; args = [ mock_script ]
          }
        in
        Eio.Switch.run (fun sw ->
          let client =
            match Runtime_acp_client.start ~sw ~proc_mgr ~clock ~config:cfg () with
            | Ok c -> c
            | Error err -> failf "start failed: %s" (Runtime_acp_client.error_to_string err)
          in
          Fun.protect ~finally:(fun () -> Runtime_acp_client.close client) (fun () ->
            let session =
              match Runtime_acp_client.new_session client ~cwd:home () with
              | Ok s -> s
              | Error err ->
                failf "new_session failed: %s" (Runtime_acp_client.error_to_string err)
            in
            let prompt ~prior text =
              match
                Runtime_acp_client.prompt
                  client
                  ~session_id:session.session_id
                  ~blocks:[ Runtime_acp_client.Text_block text ]
                  ~prior_context_used:prior
                  ()
              with
              | Ok result -> result.Runtime_acp_client.context_compaction
              | Error err -> failf "prompt failed: %s" (Runtime_acp_client.error_to_string err)
            in
            (* The count rose past the previous prompt's: only the record shows
               the compaction. *)
            check
              string
              "a compaction the prompt grew past"
              "compacted"
              (compaction_name (prompt ~prior:50000 "compact used=60000"));
            check
              string
              "a prompt that did not compact"
              "not compacted"
              (compaction_name (prompt ~prior:60000 "carry on used=70000"));
            (match
               Runtime_acp_client.prompt
                 client
                 ~session_id:session.session_id
                 ~blocks:[ Runtime_acp_client.Text_block "compact and fail" ]
                 ~prior_context_used:70000
                 ()
             with
             | Error _ -> ()
             | Ok _ -> fail "the mock host answers this prompt with an error");
            check
              string
              "a compaction during a failed prompt counts at the next one"
              "compacted"
              (compaction_name (prompt ~prior:70000 "carry on used=80000"));
            check
              string
              "a drop in the count still counts"
              "compacted"
              (compaction_name (prompt ~prior:80000 "carry on used=30000"));
            (match
               Runtime_acp_client.prompt
                 client
                 ~session_id:session.session_id
                 ~blocks:[ Runtime_acp_client.Text_block "weekly after a compact" ]
                 ~prior_context_used:30000
                 ()
             with
             | Error
                 (Runtime_acp_client.Host_turn_failed
                    { code
                    ; message
                    ; refusal = Some (Llm_provider.Retry.Signal_rate_limited _)
                    }) ->
               check string "the host's code" "provider.api_error" code;
               check
                 string
                 "the host's message"
                 "You've reached your weekly (7-day) usage limit."
                 message
             | Error err ->
               failf
                 "a prompt the host recorded as failed with status 429 must be a rate-limited \
                  Host_turn_failed, got %s"
                 (Runtime_acp_client.error_to_string err)
             | Ok _ -> fail "a prompt the host recorded as failed was read as an answer");
            check
              string
              "a compaction during a recorded failure counts at the next prompt"
              "compacted"
              (compaction_name (prompt ~prior:30000 "carry on used=31000"));
            check
              string
              "the prompt after that counts only its own records"
              "not compacted"
              (compaction_name (prompt ~prior:31000 "carry on used=32000"));
            remove_tree (Filename.concat home "sessions");
            (match prompt ~prior:32000 "carry on used=40000" with
             | Runtime_acp_client.Compaction_unknown
                 (Runtime_acp_client.Kimi_session_record_unreadable (Log.Read_failed _)) -> ()
             | other ->
               failf
                 "a record gone since the last count must leave the compaction unknown, got %s"
                 (compaction_name other));
            match prompt ~prior:40000 "carry on used=50000" with
            | Runtime_acp_client.Compaction_unknown
                (Runtime_acp_client.Kimi_session_record_unreadable
                   (Log.Session_record_not_found _)) -> ()
            | other ->
              failf
                "a session without a record must leave the compaction unknown, got %s"
                (compaction_name other))))))
;;

let () =
  run
    "runtime_kimi_session_log"
    [ ( "record"
      , [ test_case "home from the host's environment" `Quick test_root_of_environment
        ; test_case "a session that cannot be located" `Quick test_locate_errors
        ; test_case "the format version is checked" `Quick test_protocol_version_is_checked
        ; test_case
            "compactions written after the mark"
            `Quick
            test_counts_the_compactions_after_the_mark
        ; test_case
            "a record still being written"
            `Quick
            test_a_record_still_being_written_is_left_out
        ; test_case
            "a record cut by the mark"
            `Quick
            test_a_record_cut_by_the_mark_is_earlier_activity
        ; test_case
            "the next count starts where this one stopped"
            `Quick
            test_the_next_count_starts_where_this_one_stopped
        ; test_case "slices that cannot be read" `Quick test_unreadable_slices
        ; test_case "how the prompt ended" `Quick test_reads_how_the_prompt_ended
        ] )
    ; ( "acp client"
      , [ test_case
            "a kimi prompt reads its compactions from the session record"
            `Quick
            test_a_kimi_prompt_reads_its_compactions_from_the_session_record
        ] )
    ]
;;
