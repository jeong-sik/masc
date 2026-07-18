(* The product-specific busy router was deleted: Discord and Slack leaves now
   inject one typed delivery into [accept_connector]. This target retains only
   the production acceptance invariants that are not covered by the leaf
   projection tests. *)

open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  \xe2\x9c\x93 %s\n%!" name
  else (
    incr failures;
    Printf.printf "  \xe2\x9c\x97 %s\n%!" name)
;;

let contains ~affix text = Astring.String.is_infix ~affix text
let keeper_name = "connector-acceptance-keeper"

let count_user_lines ~base =
  Keeper_chat_store.load ~base_dir:base ~keeper_name
  |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
    match message.role with
    | Keeper_chat_store.Role.User -> true
    | Keeper_chat_store.Role.Assistant | Keeper_chat_store.Role.Tool -> false)
  |> List.length
;;

let configure_queue ~base =
  Keeper_chat_queue.For_testing.reset ();
  let report = Keeper_chat_queue.configure_persistence ~base_path:base in
  check "chat queue persistence configured without load errors" (report.load_errors = [])
;;

let test_exact_source_identity_converges () =
  Printf.printf
    "Test: durable connector acceptance converges on the producer request id\n%!";
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-connector-accept-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1_000_000.)))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote base))))
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let clock = Eio.Stdenv.clock env in
       let config = Workspace.default_config base in
       ignore (Workspace.init config ~agent_name:(Some keeper_name));
       configure_queue ~base;
       let accept metadata =
         Gate_keeper_backend.accept_connector
           ~delivery:
             { source =
                 Keeper_chat_queue.Discord
                   { channel_id = "channel-exact"; user_id = "user-exact" }
             ; surface =
                 Surface_ref.Discord
                   { guild_id = None
                   ; channel_id = "channel-exact"
                   ; parent_channel_id = None
                   ; thread_id = None
                   }
             ; conversation_id = Some "discord:dm:channel:channel-exact"
             ; external_message_id = Some "source-123"
             }
           ~clock
           ~config
           ~channel:"discord"
           ~channel_user_id:"user-exact"
           ~channel_user_name:"Exact User"
           ~channel_workspace_id:"channel-exact"
           ~keeper_name
           ~idempotency_key:"discord-msg-source-123"
           ~metadata
           ~content:"deliver exactly once"
       in
       (match
          accept
            [ "conversation_id", "discord:dm:channel:another-channel"
            ; "external_message_id", "source-123"
            ]
        with
        | Gate_protocol.Keeper_error_result detail ->
          check
            "conflicting metadata identity fails closed"
            (contains ~affix:"conflicts with metadata" detail)
        | Gate_protocol.Reply _ | Gate_protocol.Unavailable_result ->
          check "conflicting metadata identity fails closed" false);
       let request_of_reply = function
         | Gate_protocol.Reply { message_request = Some request; _ } -> request
         | Gate_protocol.Reply { message_request = None; _ }
         | Gate_protocol.Keeper_error_result _
         | Gate_protocol.Unavailable_result ->
           failwith "durable connector acceptance did not return a receipt"
       in
       let metadata = [ "external_message_id", "source-123" ] in
       let first = request_of_reply (accept metadata) in
       let repeated = request_of_reply (accept metadata) in
       check
         "receipt is the exact producer request identity"
         (String.equal first.request_id "discord-msg-source-123");
       check
         "active replay returns the same receipt"
         (String.equal repeated.request_id first.request_id);
       let pending = (Keeper_chat_queue.snapshot ~keeper_name).pending in
       check "active replay keeps one FIFO receipt" (List.length pending = 1);
       check "accepted user transcript row is idempotent" (count_user_lines ~base = 1);
       (match Keeper_chat_queue.lease_next ~keeper_name with
        | `Leased lease ->
          ignore
            (Keeper_chat_queue.finalize
               ~keeper_name
               ~lease_id:lease.lease_id
               ~outcome:
                 (Keeper_chat_queue.Mark_delivered
                    { completed_at = Time_compat.now (); outcome_ref = None })
             : [ `Finalized of Keeper_chat_queue.Receipt_id.t
               | `Unknown_lease
               | `Error of Keeper_chat_queue.mutation_error
               ])
        | `Empty | `Already_leased _ | `Recovery_required _ | `Error _ ->
          check "source receipt leases before terminal replay" false);
       let terminal = request_of_reply (accept metadata) in
       check
         "terminal replay reports done without redispatch"
         (terminal.status = Gate_protocol.Done);
       let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
       check
         "terminal replay does not create pending work"
         (snapshot.pending = [] && Int64.equal snapshot.terminal_count 1L))
;;

let () =
  test_exact_source_identity_converges ();
  (* For_testing.reset now requires an Eio context (main's idiom runs it via
     Switch.on_release inside the test); at process exit it is moot, so the
     toplevel call is dropped rather than leaking the effect. *)
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All connector acceptance checks passed\n%!"
;;
