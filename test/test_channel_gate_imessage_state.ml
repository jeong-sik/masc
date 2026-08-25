open Alcotest

module IMessage_state = Channel_gate_imessage_state
module U = Yojson.Safe.Util

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (* On the current supported 5.4 floor there is no Unix.unsetenv; this test
     only exercises config paths that route through Env_config_core.trim_opt,
     where "" behaves like unset. *)
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "imessage-state-%d-%06d" (Unix.getpid ()) !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path then
          if Sys.is_directory path then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path
          ) else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)

(* Substring search over the composed [error] field, which concatenates every
   independent reason. *)
let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.equal (String.sub haystack i n) needle || at (i + 1)) in
  n = 0 || at 0

let with_binding_paths dir f =
  with_env "MASC_IMESSAGE_BINDING_STORE_PATH"
    (Some (Filename.concat dir "bindings.json"))
    (fun () ->
      with_env "MASC_IMESSAGE_BINDING_AUDIT_PATH"
        (Some (Filename.concat dir "audit.jsonl"))
        f)

(* The sidecar this module replaced published liveness, the cursor and the
   self-chat handle through a status.json that a separate process wrote. All
   of it is now a value this module owns, so these tests set the value the
   gateway would set and read the projection — no file in between. *)

let test_status_redacts_the_self_chat_guid () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    IMessage_state.record_self_chat_guid "iMessage;-;user@example.com";
    let status = IMessage_state.status_json () in
    check string "routing prefix kept, address removed"
      "iMessage;-;[redacted]"
      (status |> U.member "self_chat_guid" |> U.to_string);
    check string "connector json carries the same redaction"
      "iMessage;-;[redacted]"
      (IMessage_state.connector_json () |> U.member "self_chat_guid"
       |> U.to_string))

let test_poll_publishes_liveness_and_cursor () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    IMessage_state.record_poll_ok ~cursor_rowid:1701;
    check bool "a poll that read chat.db is connected" true
      (IMessage_state.connected ());
    let status = IMessage_state.status_json () in
    check int "cursor surfaces" 1701 (status |> U.member "cursor_rowid" |> U.to_int);
    check string "poll state surfaces" "polling"
      (status |> U.member "poll_state" |> U.to_string);
    check bool "connected agrees with the registry export" true
      (status |> U.member "connected" |> U.to_bool);
    (* The connector never reports "stale": there is no heartbeat file to age
       out, which is the point of moving liveness in-process. *)
    check bool "never stale" true
      (not (String.equal (status |> U.member "status" |> U.to_string) "stale")))

let test_failed_poll_disconnects_with_its_reason () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    IMessage_state.record_poll_ok ~cursor_rowid:5;
    IMessage_state.record_poll_error "chat.db read failed: disk I/O error";
    check bool "a failed poll is not connected" false (IMessage_state.connected ());
    let status = IMessage_state.status_json () in
    check string "degraded" "degraded"
      (status |> U.member "poll_state" |> U.to_string);
    check bool "the reason is reported, not swallowed" true
      (contains
         (status |> U.member "error" |> U.to_string)
         "chat.db read failed: disk I/O error");
    (* Put the module back so ordering between tests cannot matter. *)
    IMessage_state.record_poll_ok ~cursor_rowid:5)

let test_reply_mode_rejects_a_typo () =
  check bool "self-chat parses" true
    (IMessage_state.parse_reply_mode "self-chat" = Ok IMessage_state.Self_chat);
  check bool "source-chat parses" true
    (IMessage_state.parse_reply_mode "source-chat" = Ok IMessage_state.Source_chat);
  check bool "case and padding are tolerated" true
    (IMessage_state.parse_reply_mode "  Self-Chat " = Ok IMessage_state.Self_chat);
  (* A typo must not silently route replies somewhere the operator did not
     choose — the only person who would notice is whoever wrongly received
     them. *)
  check bool "a near miss is an error, not a fallback" true
    (Result.is_error (IMessage_state.parse_reply_mode "selfchat"));
  check bool "an empty value is an error too" true
    (Result.is_error (IMessage_state.parse_reply_mode ""))

let test_reply_target_fails_closed () =
  with_env "MASC_IMESSAGE_REPLY_MODE" (Some "self-chat") (fun () ->
    IMessage_state.record_self_chat_guid "";
    check bool "self-chat with nothing resolved refuses to send" true
      (Result.is_error (IMessage_state.reply_target ~chat_guid:(Some "iMessage;-;x")));
    IMessage_state.record_self_chat_guid "iMessage;-;me@example.com";
    check bool "self-chat answers in the note-to-self conversation" true
      (IMessage_state.reply_target ~chat_guid:(Some "iMessage;-;someone-else")
       = Ok "iMessage;-;me@example.com"));
  with_env "MASC_IMESSAGE_REPLY_MODE" (Some "source-chat") (fun () ->
    check bool "source-chat answers where the message came from" true
      (IMessage_state.reply_target ~chat_guid:(Some "iMessage;-;someone-else")
       = Ok "iMessage;-;someone-else");
    check bool "source-chat with no source handle refuses to send" true
      (Result.is_error (IMessage_state.reply_target ~chat_guid:None)))

let test_audit_entries_omit_guild_id () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    match
      IMessage_state.bind ~channel_id:"user@example.com" ~keeper_name:"claude"
        ~actor_name:"tester"
    with
    | Error message -> failf "bind failed: %s" message
    | Ok _ ->
      let audit =
        IMessage_state.status_json () |> U.member "recent_audit" |> U.to_list
      in
      check int "one audit entry" 1 (List.length audit);
      (* iMessage has no guild, so the field is absent rather than empty. *)
      check bool "no guild_id on the entry" true
        (List.for_all (fun entry -> U.member "guild_id" entry = `Null) audit))

let test_binding_resolution_is_exact () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    match
      IMessage_state.bind ~channel_id:"user@example.com" ~keeper_name:"claude"
        ~actor_name:"tester"
    with
    | Error message -> failf "bind failed: %s" message
    | Ok _ ->
      (match
         IMessage_state.resolve_keeper_for_channel_result
           ~channel_id:"user@example.com"
       with
       | Ok (Some resolution) ->
         check string "bound conversation resolves" "claude"
           resolution.IMessage_state.keeper_name
       | Ok None -> fail "bound conversation did not resolve"
       | Error _ -> fail "binding store unreadable");
      (* An unbound conversation is not this connector's traffic. Messages.app
         holds the operator's personal correspondence, so "no binding" has to
         stay distinct from "store unreadable". *)
      check bool "an unbound conversation resolves to nothing" true
        (IMessage_state.resolve_keeper_for_channel_result
           ~channel_id:"stranger@example.com"
         = Ok None))

let test_malformed_binding_store_is_explicit () =
  with_temp_dir @@ fun dir ->
  with_binding_paths dir (fun () ->
    let path = Filename.concat dir "bindings.json" in
    let oc = open_out path in
    output_string oc "{ this is not json";
    close_out oc;
    let status = IMessage_state.status_json () in
    check bool "the store read is reported as failed" false
      (status |> U.member "binding_store_read_ok" |> U.to_bool);
    check bool "and the connector is not available" false
      (status |> U.member "available" |> U.to_bool);
    check bool "an unreadable store is not an unbound keeper" true
      (Result.is_error
         (IMessage_state.resolve_keeper_for_channel_result
            ~channel_id:"user@example.com")))

let () =
  run "channel_gate_imessage_state"
    [ ( "in-process state"
      , [ test_case "status json redacts the self-chat guid" `Quick
            test_status_redacts_the_self_chat_guid
        ; test_case "a poll publishes liveness and the cursor" `Quick
            test_poll_publishes_liveness_and_cursor
        ; test_case "a failed poll disconnects with its reason" `Quick
            test_failed_poll_disconnects_with_its_reason
        ; test_case "reply mode rejects a typo" `Quick
            test_reply_mode_rejects_a_typo
        ; test_case "reply target fails closed" `Quick
            test_reply_target_fails_closed
        ; test_case "audit entries omit guild_id" `Quick
            test_audit_entries_omit_guild_id
        ; test_case "binding resolution is exact" `Quick
            test_binding_resolution_is_exact
        ; test_case "malformed binding store is explicit" `Quick
            test_malformed_binding_store_is_explicit
        ] )
    ]
