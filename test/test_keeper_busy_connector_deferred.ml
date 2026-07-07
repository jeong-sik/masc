(* test_keeper_busy_connector_deferred.ml — RFC-connector-deferred-reply-via-chat-queue §4.

   Production-path proof (not a pure-helper test): a Discord connector message
   that arrives while the keeper already holds an in-flight turn is routed
   through [Gate_keeper_backend.dispatch] onto [Keeper_chat_queue] (where the
   serial consumer can drain it and deliver the reply via the Discord outbound
   adapter), NOT the outbound-less async [Keeper_msg_async] poll store — the
   RFC root-cause fix. It also pins the recording-ownership invariant: the gate
   inbound boundary records the connector user line exactly once, with no paired
   assistant row yet (the message is still pending, waiting to be drained).

   The Discord busy branch enqueues and returns a queued ACK without running a
   keeper turn, so this needs no provider: [proc_mgr]/[net] are [None] and the
   admission slot is held by a sibling fiber for the whole assertion window. *)

open Masc

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  \xe2\x9c\x93 %s\n%!" name
  else (
    incr failures;
    Printf.printf "  \xe2\x9c\x97 %s\n%!" name)

let keeper_name = "busy-connector-keeper"

(* Hold the keeper's admission slot busy in a forked fiber (the proven pattern
   from test_keeper_turn_admission): the body resolves [started] then blocks on
   [release], so the slot stays occupied across [f]. *)
let with_busy_slot ~base ~sw f =
  let started, set_started = Eio.Promise.create () in
  let release, set_release = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    ignore
      (Keeper_turn_admission.run_serialized ~base_path:base ~keeper_name
         (fun () ->
           Eio.Promise.resolve set_started ();
           Eio.Promise.await release)));
  Eio.Promise.await started;
  let result = f () in
  Eio.Promise.resolve set_release ();
  result

let count_user_lines ~base =
  (* The gate inbound boundary records the connector user line as a pending
     (assistant-less) row. Count those rows for the keeper to assert exactly-once
     recording. *)
  List.length
    (List.filter
       (fun (m : Keeper_chat_store.chat_message) ->
          match m.role with Keeper_chat_store.Role.User -> true | _ -> false)
       (Keeper_chat_store.load ~base_dir:base ~keeper_name))

let test_busy_discord_enqueues () =
  Printf.printf
    "Test: busy Discord dispatch enqueues onto Keeper_chat_queue (not async poll)\n%!";
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-busy-conn-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      let config = Workspace.default_config base in
      ignore (Workspace.init config ~agent_name:(Some keeper_name));
      Keeper_turn_admission.For_testing.reset ();
      Keeper_chat_queue.clear ~keeper_name;
      Eio.Switch.run (fun sw ->
        let reply =
          with_busy_slot ~base ~sw (fun () ->
            Gate_keeper_backend.dispatch
              ~connector_kind:Gate_keeper_backend.Discord
              ~sw ~clock ~proc_mgr:None ~net:None ~config
              ~channel:"discord" ~channel_user_id:"user-42"
              ~channel_user_name:"Tester" ~channel_workspace_id:"chan-777"
              ~keeper_name ~idempotency_key:"discord-msg-777"
              ~metadata:[] ~content:"are you there?")
        in
        (* The connector receives a busy ACK now; the deferred reply arrives
           later via the consumer, so there is no async-poll request_id. *)
        (match reply with
         | Gate_protocol.Reply { message_request; content; _ } ->
             check "busy connector reply carries no async-poll request_id"
               (message_request = None);
             check "busy ACK text is non-empty" (String.length content > 0)
         | Gate_protocol.Keeper_error_result _
         | Gate_protocol.Unavailable_result ->
             check "busy Discord dispatch returns a Reply (not error/unavailable)"
               false);
        (* The message lands on the chat queue with the typed Discord source so
           the serial consumer can drain it and route the reply to the channel. *)
        check "exactly one message enqueued"
          (Keeper_chat_queue.length ~keeper_name = 1);
        (match Keeper_chat_queue.dequeue ~keeper_name with
         | Some
             { Keeper_chat_queue.source =
                 Keeper_chat_queue.Discord { channel_id; user_id }
             ; content
             ; _
             } ->
             check "queued source is the Discord channel_id"
               (channel_id = "chan-777");
             check "queued source carries the user_id" (user_id = "user-42");
             check "queued content is the user's message"
               (content = "are you there?")
         | Some _ -> check "queued source is Discord" false
         | None -> check "queue holds the busy message" false);
        (* Ownership invariant (RFC §3.4): the gate inbound boundary recorded the
           user line exactly once; no paired assistant row exists yet because the
           turn has not been drained. *)
        check "gate inbound recorded the connector user line exactly once"
          (count_user_lines ~base = 1)))

let () =
  test_busy_discord_enqueues ();
  if !failures > 0 then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_busy_connector_deferred checks passed\n%!"
