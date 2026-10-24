(** Source scenarios for the actual OCaml private broker on Unix sockets.
    No provider or Browser is started. They are not executed by parse-only. *)
open Alcotest
open Masc
module B=Lane_addon_companion_broker
module P=Browser_extension_protocol
let ok = function Ok value -> value | Error _ -> fail "private broker fixture failed"
let browser_instance_id="0b000000-0000-4000-8000-000000000025"
let field name value=Yojson.Safe.Util.member name value
let with_broker run =
  let directory=Filename.temp_dir "cpb-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () ->
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
        let broker=B.create ~sw ~directory ~max_message_bytes:16384 |> ok in
        Eio.Switch.on_release sw (fun () -> B.revoke broker);
        run env sw broker))))
let connect env sw grant =
  let descriptor=B.descriptor grant in
  let path=field "socket_path" descriptor |> Yojson.Safe.Util.to_string in
  let flow=Eio.Net.connect ~sw (Eio.Stdenv.net env) (`Unix path) in
  let reader=Eio.Buf_read.of_flow flow ~max_size:16385 in
  flow,reader
let send flow value=Eio.Flow.copy_string (Yojson.Safe.to_string value ^ "\n") flow
let receive reader=Eio.Buf_read.line reader |> Yojson.Safe.from_string
let handshake grant=`Assoc ["invocation_id",field "invocation_id" (B.descriptor grant);
  "browser_instance_id",`String browser_instance_id;"tab_id",`Int 7]
let operation reader=receive reader |> field "operation_id" |> Yojson.Safe.Util.to_string
let invoke operation_id=P.Invoke {operation_id;program="async()=>({})";arguments=`Assoc []}
let released=`Assoc ["released",`Bool true]
let issue broker ~bind=B.issue broker ~bind |> ok
let normal_binding_and_consumption () = with_broker (fun env sw broker ->
  let calls=ref [] and finishes=ref [] and binds=ref 0 in
  let finished,finish=Eio.Promise.create () in
  let grant=issue broker ~bind:(fun selected ->
    incr binds;
    check string "original Browser selection" browser_instance_id selected.B.browser_instance_id;
    check int "original MASC tab" 7 selected.tab_id;
    Ok {B.execute=(fun command -> calls:=command::!calls;
      Ok (match command with P.Release _ -> released | Prepare _ -> `Assoc ["prepared",`Bool true]
        | Invoke _ -> `Assoc ["reference",`String "PRIVATE_REFERENCE_MARKER"]));
      finish=(fun completion -> finishes:=completion::!finishes;Eio.Promise.resolve finish ())}) in
  let flow,reader=connect env sw grant in
  send flow (handshake grant);
  let operation_id=operation reader in
  B.end_invocation grant;
  let second,second_reader=connect env sw grant in
  send second (handshake grant);
  check bool "a claimed grant cannot bind a second socket" true
    (receive second_reader=`Assoc ["error",`String "not_started"]);
  check int "factory consumed once before yielding" 1 !binds;
  let commands=[P.Prepare {operation_id;tab_id=7;extension_id=String.make 32 'a';directory="/private/vendor-extension";
      program="async()=>({ready:true})";arguments=`Assoc []}; invoke operation_id; P.Release operation_id] in
  List.iter (fun command -> send flow (P.to_json command);
    let reply=receive reader in check bool "private frame has a value" true (field "value" reply<>`Null)) commands;
  Eio.Promise.await finished;
  check bool "original commands remain unchanged" true (List.rev !calls=commands);
  check bool "normal release finishes once" true (!finishes=[B.Released]);
  let again,again_reader=connect env sw grant in send again (handshake grant);
  check bool "consumed grant cannot be replayed after release" true
    (receive again_reader=`Assoc ["error",`String "not_started"]))
let unused_grant () = with_broker (fun env sw broker ->
  let binds=ref 0 in
  let grant=issue broker ~bind:(fun _ -> incr binds;Error B.Not_started) in
  B.end_invocation grant;
  let flow,reader=connect env sw grant in send flow (handshake grant);
  check bool "normal return withdraws unused private admission" true
    (receive reader=`Assoc ["error",`String "not_started"]);
  check int "withdrawn grant calls no factory" 0 !binds)
let accepted_grant_binds_after_return () = with_broker (fun env sw broker ->
  let binds=ref 0 in
  let finished,finish=Eio.Promise.create () in
  let grant=issue broker ~bind:(fun _ -> incr binds;Ok {
    B.execute=(fun _ -> Ok released);finish=(fun _ -> Eio.Promise.resolve finish ())}) in
  B.accept grant;
  B.end_invocation grant;
  check int "accepted invocation has not eagerly selected a Browser" 0 !binds;
  let flow,reader=connect env sw grant in send flow (handshake grant);
  let operation_id=operation reader in
  check int "background bind consumes only the original accepted grant" 1 !binds;
  send flow (P.to_json (P.Release operation_id));
  check bool "original operation settles after public invocation return" true
    (receive reader=`Assoc ["value",released]);
  Eio.Promise.await finished;
  B.accept grant;
  B.end_invocation grant;
  let again,again_reader=connect env sw grant in send again (handshake grant);
  check bool "accept never resurrects a consumed original grant" true
    (receive again_reader=`Assoc ["error",`String "not_started"]);
  check int "no replacement factory is called" 1 !binds)
let accepted_grant_can_be_withdrawn () = with_broker (fun env sw broker ->
  let binds=ref 0 in
  let grant=issue broker ~bind:(fun _ -> incr binds;Error B.Not_started) in
  B.accept grant;B.end_invocation grant;
  let withdrawal=`Assoc ["invocation_id",field "invocation_id" (B.descriptor grant);"withdraw",`Bool true] in
  let control,control_reader=connect env sw grant in send control withdrawal;
  check bool "unused accepted nonce is withdrawn through the private control socket" true
    (receive control_reader=`Assoc ["withdrawn",`Bool true]);
  let repeated,repeated_reader=connect env sw grant in send repeated withdrawal;
  check bool "absent nonce withdrawal is idempotent and creates no binding" true
    (receive repeated_reader=`Assoc ["withdrawn",`Bool true]);
  B.accept grant;
  let flow,reader=connect env sw grant in send flow (handshake grant);
  check bool "cancelled deferred admission cannot be restored by accept" true
    (receive reader=`Assoc ["error",`String "not_started"]);
  check int "withdrawal sends no Browser input" 0 !binds)
let pipelined_command_is_not_dispatched () = with_broker (fun env sw broker ->
  let calls=ref 0 in
  let finished,finish=Eio.Promise.create () in
  let grant=issue broker ~bind:(fun _ -> Ok {
    B.execute=(fun _ -> incr calls;Ok (`Assoc []));finish=(fun _ -> Eio.Promise.resolve finish ())}) in
  let flow,reader=connect env sw grant in send flow (handshake grant);
  let operation_id=operation reader in
  let command=Yojson.Safe.to_string (P.to_json (invoke operation_id)) ^ "\n" in
  Eio.Flow.copy_string (command ^ command) flow;
  Eio.Promise.await finished;
  check int "reader-buffered pipelining sends no Browser effect" 0 !calls)
let peer_loss_joins_execute () = with_broker (fun env sw broker ->
  let entered,enter=Eio.Promise.create () and cancelled,cancel=Eio.Promise.create () in
  let cleanup,allow_cleanup=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let finished,finish=Eio.Promise.create () in
  let completions=ref [] in
  let grant=issue broker ~bind:(fun _ -> Ok {
    B.execute=(fun _ -> Eio.Promise.resolve enter ();
      (try Eio.Promise.await never with Eio.Cancel.Cancelled _ ->
        Eio.Promise.resolve cancel ();Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup));
      Ok (`Assoc ["private",`String "LATE_PRIVATE_MARKER"]));
    finish=(fun completion -> completions:=completion::!completions;Eio.Promise.resolve finish ())}) in
  let flow,reader=connect env sw grant in send flow (handshake grant);
  let operation_id=operation reader in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ())) (fun () ->
    send flow (P.to_json (invoke operation_id));Eio.Promise.await entered;
    Eio.Flow.close flow;Eio.Promise.await cancelled;
    check bool "finish waits for original execute cleanup" false (Eio.Promise.is_resolved finished);
    Eio.Promise.resolve allow_cleanup ();Eio.Promise.await finished;
    check bool "cancellation-ignoring success is abandoned" true (!completions=[B.Abandoned])))
let peer_loss_joins_bind () = with_broker (fun env sw broker ->
  let entered,enter=Eio.Promise.create () and cancelled,cancel=Eio.Promise.create () in
  let cleanup,allow_cleanup=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let finished,finish=Eio.Promise.create () in
  let calls=ref 0 and completions=ref [] in
  let grant=issue broker ~bind:(fun _ ->
    Eio.Promise.resolve enter ();
    (try Eio.Promise.await never with Eio.Cancel.Cancelled _ ->
      Eio.Promise.resolve cancel ();Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup));
    Ok {B.execute=(fun _ -> incr calls;Ok (`Assoc []));
      finish=(fun completion -> completions:=completion::!completions;Eio.Promise.resolve finish ())}) in
  let flow,_=connect env sw grant in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ())) (fun () ->
    send flow (handshake grant);Eio.Promise.await entered;
    Eio.Flow.close flow;Eio.Promise.await cancelled;
    check bool "initial bind cleanup is joined" false (Eio.Promise.is_resolved finished);
    Eio.Promise.resolve allow_cleanup ();Eio.Promise.await finished;
    check int "departed bind never reaches Browser dispatch" 0 !calls;
    check bool "late binding is finished exactly once" true (!completions=[B.Abandoned])))
let revoke_signal_and_join_are_distinct () = with_broker (fun env sw broker ->
  let entered,enter=Eio.Promise.create () and cancelled,cancel=Eio.Promise.create () in
  let cleanup,allow_cleanup=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let completions=ref [] in
  let grant=issue broker ~bind:(fun _ -> Ok {
    B.execute=(fun _ -> Eio.Promise.resolve enter ();
      (try Eio.Promise.await never with Eio.Cancel.Cancelled _ ->
        Eio.Promise.resolve cancel ();Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup));
      Ok (`Assoc []));finish=(fun completion -> completions:=completion::!completions)}) in
  let flow,reader=connect env sw grant in send flow (handshake grant);
  let operation_id=operation reader in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ())) (fun () ->
    send flow (P.to_json (invoke operation_id));Eio.Promise.await entered;
    B.revoke broker;B.revoke broker;
    Eio.Promise.await cancelled;
    let stopped=Eio.Fiber.fork_promise ~sw (fun () -> B.await_stopped broker) in
    Eio.Fiber.yield ();
    check bool "revoke signal is not a cleanup receipt" false (Eio.Promise.is_resolved stopped);
    check bool "revocation refuses new grants" true
      (B.issue broker ~bind:(fun _ -> Error B.Not_started)=Error B.Unavailable);
    Eio.Promise.resolve allow_cleanup ();
    check bool "listener descriptor close is confirmed" true (Eio.Promise.await_exn stopped = Ok ());
    check bool "joined revocation finished the original binding once" true (!completions=[B.Abandoned])))
let cancelled_invocation_joins_bind () = with_broker (fun env sw broker ->
  let entered,enter=Eio.Promise.create () and cancelled,cancelled_resolver=Eio.Promise.create () in
  let cleanup,allow_cleanup=Eio.Promise.create () and never,_=Eio.Promise.create () in
  let finished,finish=Eio.Promise.create () in
  let completions=ref [] and calls=ref 0 in
  let grant=issue broker ~bind:(fun _ -> Eio.Promise.resolve enter ();
    (try Eio.Promise.await never with Eio.Cancel.Cancelled _ ->
      Eio.Promise.resolve cancelled_resolver ();Eio.Cancel.protect (fun () -> Eio.Promise.await cleanup));
    Ok {B.execute=(fun _ -> incr calls;Ok (`Assoc []));
      finish=(fun completion -> completions:=completion::!completions;Eio.Promise.resolve finish ())}) in
  let flow,reader=connect env sw grant in
  Fun.protect ~finally:(fun () -> ignore (Eio.Promise.try_resolve allow_cleanup ())) (fun () ->
    send flow (handshake grant);Eio.Promise.await entered;
    B.cancel grant;Eio.Promise.await cancelled;
    check bool "invocation cancellation joins the original factory" false (Eio.Promise.is_resolved finished);
    Eio.Promise.resolve allow_cleanup ();Eio.Promise.await finished;
    check int "cancelled invocation admits no Browser command" 0 !calls;
    check bool "late binding is abandoned exactly once" true (!completions=[B.Abandoned]);
    check bool "late binding success never escapes cancellation" true
      (match Eio.Buf_read.line reader with _ -> false | exception End_of_file -> true)))
let ()=run "private companion broker" ["invocation authority",[
  test_case "one original connection and safe release" `Quick normal_binding_and_consumption;
  test_case "unused invocation grant is withdrawn" `Quick unused_grant;
  test_case "accepted grant binds after public invocation return" `Quick accepted_grant_binds_after_return;
  test_case "accepted deferred grant remains cancellable" `Quick accepted_grant_can_be_withdrawn;
  test_case "buffered pipelining is refused before effect" `Quick pipelined_command_is_not_dispatched;
  test_case "peer loss cancels and joins original execute" `Quick peer_loss_joins_execute;
  test_case "peer loss cancels and joins initial bind" `Quick peer_loss_joins_bind;
  test_case "revocation admission and joined cleanup remain distinct" `Quick revoke_signal_and_join_are_distinct;
  test_case "cancelled original invocation joins initial bind" `Quick cancelled_invocation_joins_bind]]
