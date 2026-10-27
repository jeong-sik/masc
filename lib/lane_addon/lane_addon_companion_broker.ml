module P=Browser_extension_protocol
type error = Unavailable | Not_started | Outcome_unknown
type shutdown_error = Listener_close_unconfirmed
type selection = { browser_instance_id:string; tab_id:int }
type completion = Released | Abandoned
type binding = {
  execute:P.command -> (Yojson.Safe.t,P.error) result;
  finish:completion -> unit;
}
type phase = Pending | Accepted | Claimed | Withdrawn
type invocation_decision = Awaiting_decision | Admitted | Rejected
type t = {
  socket_path:string; max_message_bytes:int;
  grants:(string,grant) Hashtbl.t;
  publications:(string,grant) Hashtbl.t;
  retired:unit Eio.Promise.t; retire:unit Eio.Promise.u;
  stopped:(unit,shutdown_error) result Eio.Promise.t;
  stop:(unit,shutdown_error) result Eio.Promise.u;
  mutable live:bool;
}
and grant = {
  broker:t; invocation_id:string; operation_id:string;
  bind:selection -> (binding,error) result;
  cancelled:unit Eio.Promise.t; cancel:unit Eio.Promise.u;
  mutable phase:phase;
  publication_id:string option;
  publish:(Yojson.Safe.t -> (unit,error) result) option;
  mutable decision:invocation_decision;
  decided:unit Eio.Promise.t; decide:unit Eio.Promise.u;
  publication_cancelled:unit Eio.Promise.t; cancel_publication:unit Eio.Promise.u;
}
type opening = Bind of string * selection | Withdraw of string | Publish of string * Yojson.Safe.t
type connection_start = Binding of grant * selection | Withdrawal of string
  | Publication of grant * Yojson.Safe.t
let ( let* )=Result.bind
let error_json = function
  | Unavailable -> `Assoc ["error",`String "unavailable"]
  | Not_started -> `Assoc ["error",`String "not_started"]
  | Outcome_unknown -> `Assoc ["error",`String "outcome_unknown"]
let revoke t =
  t.live<-false;ignore (Eio.Promise.try_resolve t.retire ());
  Hashtbl.clear t.grants;Hashtbl.clear t.publications
let await_stopped t = Eio.Promise.await t.stopped
let withdraw_browser grant =
  grant.phase<-Withdrawn;
  Hashtbl.remove grant.broker.grants grant.invocation_id;
  ignore (Eio.Promise.try_resolve grant.cancel ())
let cancel_invocation grant =
  withdraw_browser grant;
  grant.decision<-Rejected;
  Option.iter (Hashtbl.remove grant.broker.publications) grant.publication_id;
  ignore (Eio.Promise.try_resolve grant.decide ());
  ignore (Eio.Promise.try_resolve grant.cancel_publication ())
let accept grant =
  if not grant.broker.live then Error Unavailable else
  match grant.decision with
  | Awaiting_decision ->
      grant.decision<-Admitted;
      (match grant.phase with Pending -> grant.phase<-Accepted | Accepted|Claimed|Withdrawn -> ());
      ignore (Eio.Promise.try_resolve grant.decide ());Ok ()
  | Admitted -> Ok ()
  | Rejected -> Error Not_started
let end_invocation grant = match grant.decision with
  | Awaiting_decision | Rejected -> cancel_invocation grant
  | Admitted -> ()
let descriptor grant = `Assoc ["socket_path",`String grant.broker.socket_path;
  "invocation_id",`String grant.invocation_id;"max_message_bytes",`Int grant.broker.max_message_bytes;
  "publication_id",(match grant.publication_id with None -> `Null | Some id -> `String id)]
let nonce ()=Agent_core_sha256.(to_hex (digest_string (Crypto_rng.generate 32)))
let issue broker ~publish ~bind =
  if not broker.live then Error Unavailable else
  let invocation_id=nonce () in
  let publication_id=Option.map (fun _ -> nonce ()) publish in
  let cancelled,cancel=Eio.Promise.create () in
  let decided,decide=Eio.Promise.create () in
  let publication_cancelled,cancel_publication=Eio.Promise.create () in
  let grant={broker;invocation_id;operation_id=Random_id.uuid_v7 ();bind;
    cancelled;cancel;phase=Pending;publication_id;publish;decision=Awaiting_decision;
    decided;decide;publication_cancelled;cancel_publication} in
  Hashtbl.add broker.grants invocation_id grant;
  Option.iter (fun id -> Hashtbl.add broker.publications id grant) publication_id;
  Ok grant
let parse raw =
  match Yojson.Safe.from_string raw with
  | value -> Lane_addon_action.canonical value |> Result.map_error (fun _ -> Not_started)
  | exception Yojson.Json_error _ -> Error Not_started
let capability = function
  | `String value when String.length value=64
      && String.for_all (fun c -> c>='0' && c<='9' || c>='a' && c<='f') value -> Ok value
  | _ -> Error Not_started
let handshake = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["event";"publication_id"] ->
      let* publication_id=capability (List.assoc "publication_id" fields) in
      Ok (Publish (publication_id,List.assoc "event" fields))
  | `Assoc fields when List.sort String.compare (List.map fst fields)=["invocation_id";"withdraw"] ->
      let* invocation_id=capability (List.assoc "invocation_id" fields) in
      (match List.assoc "withdraw" fields with
       | `Bool true -> Ok (Withdraw invocation_id) | _ -> Error Not_started)
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["browser_instance_id";"invocation_id";"tab_id"] ->
      (match List.assoc "invocation_id" fields,List.assoc "browser_instance_id" fields,List.assoc "tab_id" fields with
       | raw_invocation_id,`String browser_instance_id,`Int tab_id when tab_id>=0 ->
           let* invocation_id=capability raw_invocation_id in
           let* _=Browser_lane.client_id_of_string browser_instance_id |> Result.map_error (fun _ -> Not_started) in
           Ok (Bind (invocation_id,{browser_instance_id;tab_id}))
       | _ -> Error Not_started)
  | _ -> Error Not_started
let read t reader =
  match Eio.Buf_read.line reader with
  | raw when String.length raw<=t.max_message_bytes -> parse raw
  | _ -> Error Not_started
  | exception (End_of_file|Eio.Buf_read.Buffer_limit_exceeded) -> Error Not_started
let write t flow json =
  let raw=Yojson.Safe.to_string json in
  let raw=if String.length raw<=t.max_message_bytes then raw
    else Yojson.Safe.to_string (error_json Outcome_unknown) in
  Eio.Flow.copy_string (raw ^ "\n") flow
let matches grant selection = function
  | P.Prepare {operation_id;tab_id;_} -> operation_id=grant.operation_id && tab_id=selection.tab_id
  | P.Invoke {operation_id;_} | P.Release operation_id -> operation_id=grant.operation_id
let admitted grant = grant.broker.live && match grant.phase with
  | Claimed -> not (Eio.Promise.is_resolved grant.cancelled)
  | Pending | Accepted | Withdrawn -> false
let while_peer_waits ~admit reader work =
  let departed=ref false in
  let result=Watched_work.run (fun () ->
    Eio.Fiber.check ();
    if !departed || not (admit ()) then None else Some (work ()))
    ~watcher:(fun () ->
      (* Use the framing reader: it may already own pipelined bytes. Reading
         the raw flow here would miss that buffered input and admit effects. *)
      (match Eio.Buf_read.any_char reader with
       | _ -> departed:=true
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception _ -> departed:=true);
      None) in
  result,!departed
let serve_connection t flow =
  let reader=Eio.Buf_read.of_flow flow ~initial_size:(min 4096 (t.max_message_bytes+1))
    ~max_size:(t.max_message_bytes+1) in
  let select () =
    let* value=read t reader in
    let* opening=handshake value in
    match opening with
    | Withdraw invocation_id -> Ok (Withdrawal invocation_id)
    | Publish (publication_id,event) ->
        (match Hashtbl.find_opt t.publications publication_id with
         | Some grant when t.live -> Ok (Publication (grant,event))
         | Some _|None -> Error Not_started)
    | Bind (invocation_id,selection) ->
        match Hashtbl.find_opt t.grants invocation_id with
        | Some ({phase=(Pending|Accepted);_} as grant) when t.live ->
            (* Consume before calling the host factory, which can yield while it
               freshly reads declarations. Another socket cannot steal the bind. *)
            grant.phase<-Claimed;
            Ok (Binding (grant,selection))
        | Some {phase=(Pending|Accepted|Claimed|Withdrawn);_}|None -> Error Not_started in
  match select () with
  | Error error -> write t flow (error_json error)
  | Ok (Withdrawal invocation_id) ->
      (* This credentialless control can only remove authority. Absence is an
         authoritative no-grant result, so lost acknowledgements are safely
         reconciled using the same nonce. No binding factory or Browser input. *)
      Option.iter withdraw_browser (Hashtbl.find_opt t.grants invocation_id);
      write t flow (`Assoc ["withdrawn",`Bool true])
  | Ok (Publication (grant,event)) ->
    let available ()=t.live && match grant.decision with
      | Awaiting_decision|Admitted -> true | Rejected -> false in
    let run ()=
      let result,departed=while_peer_waits ~admit:available reader (fun () ->
        Eio.Promise.await grant.decided;
        match grant.decision,grant.publish with
        | Admitted,Some publish when t.live -> publish event
        | (Awaiting_decision|Admitted|Rejected),(Some _|None) -> Error Not_started) in
      if departed || not (available ()) then () else
      match result with
      | Some (Ok ()) -> write t flow (`Assoc ["accepted",`Bool true])
      | Some (Error error) -> write t flow (error_json error)
      | None -> () in
    Watched_work.run run ~watcher:(fun () -> Eio.Promise.await grant.publication_cancelled)
  | Ok (Binding (grant,selection)) ->
    let owned_binding=ref None in
    Fun.protect ~finally:(fun () ->
      withdraw_browser grant;
      Option.iter (fun (binding,completion) -> binding.finish !completion) !owned_binding) (fun () ->
      let run () =
        if not (admitted grant) then write t flow (error_json Not_started) else
        let binding,departed=while_peer_waits ~admit:(fun () -> admitted grant) reader (fun () ->
          match grant.bind selection with
          | Error error -> Error error
          | Ok binding ->
              let completion=ref Abandoned in
              (* Register ownership before the watched factory can lose its
                 result to invocation cancellation. The outer finalizer runs
                 only after that work and its cancellation cleanup join. *)
              owned_binding:=Some (binding,completion);
              Ok (binding,completion)) in
        match binding with
        | None -> ()
        | Some (Error error) -> if not departed && admitted grant then write t flow (error_json error)
        | Some (Ok (binding,completion)) ->
            if departed || not (admitted grant) then () else (
            write t flow (`Assoc ["bound",`Bool true;"operation_id",`String grant.operation_id]);
            let rec loop () =
              match read t reader with
              | Error error -> write t flow (error_json error)
              | Ok value ->
                match P.of_json value with
                | Error () -> write t flow (error_json Not_started)
                | Ok command when not (admitted grant && matches grant selection command) -> write t flow (error_json Not_started)
                | Ok command ->
                  let result,departed=while_peer_waits ~admit:(fun () -> admitted grant) reader (fun () -> binding.execute command) in
                  if departed || not (admitted grant) then () else
                  match result with
                  | None -> ()
                  | Some (Error P.Not_started) -> write t flow (error_json Not_started)
                  | Some (Error P.Outcome_unknown) -> write t flow (error_json Outcome_unknown)
                  | Some (Ok value) ->
                    (match command with
                     | P.Release _ ->
                         if value=`Assoc ["released",`Bool true] then (
                           completion:=Released;write t flow (`Assoc ["value",value]))
                         else write t flow (error_json Outcome_unknown)
                     | P.Prepare _|P.Invoke _ -> write t flow (`Assoc ["value",value]);loop ()) in
            loop ()) in
      Watched_work.run run ~watcher:(fun () -> Eio.Promise.await grant.cancelled))
let private_listener ~sw ~socket_path ~shutdown =
  Eio.Cancel.protect (fun () ->
    let close fd =
      match Unix.close fd with
      | () -> shutdown := Ok ()
      | exception Unix.Unix_error _ -> shutdown := Error Listener_close_unconfirmed in
    let fd=Eio_unix.run_in_systhread (fun () ->
      let fd=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      shutdown := Error Listener_close_unconfirmed;
      try Unix.set_nonblock fd;Unix.bind fd (Unix.ADDR_UNIX socket_path);Unix.listen fd 1;
        fd
      with exn -> close fd;raise exn) in
    (* Eio.Net.listen installs an unconditional path unlink. Import only the
       descriptor. A pathname check cannot authorize deleting a successor
       installed between that check and unlink, so retain the socket path. *)
    Eio.Switch.on_release sw (fun () -> Eio_unix.run_in_systhread (fun () ->
      close fd));
    Eio_unix.Net.import_socket_listening ~sw ~close_unix:false fd)
let create ~sw ~directory ~max_message_bytes =
  if max_message_bytes<String.length (Yojson.Safe.to_string (error_json Outcome_unknown))
      || max_message_bytes>=Sys.max_string_length then Error Unavailable else
  let checked=Eio_unix.run_in_systhread (fun () ->
    try
      let info=Unix.lstat directory in
      if Filename.is_relative directory || Unix.realpath directory<>directory then Error Unavailable else
      let* ()=Resource_requirement.check ~label:"private companion directory" Resource_requirement.private_directory
        ~path:directory info |> Result.map_error (fun _ -> Unavailable) in
      (match Unix.lstat (Filename.concat directory "s") with
       | _ -> Error Unavailable
       | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ())
    with Unix.Unix_error _ -> Error Unavailable) in
  let* ()=checked in
  let socket_path=Filename.concat directory "s" in
  let retired,retire=Eio.Promise.create () and stopped,stop=Eio.Promise.create () in
  let t={socket_path;max_message_bytes;grants=Hashtbl.create 4;publications=Hashtbl.create 4;retired;retire;stopped;stop;live=true} in
  let ready,resolve_ready=Eio.Promise.create () in
  let shutdown = ref (Ok ()) in
  let started=ref false in
  Eio.Switch.check sw;
  Eio.Switch.on_release sw (fun () -> if not !started then (
    revoke t;
    ignore (Eio.Promise.try_resolve resolve_ready (Error Unavailable));
    ignore (Eio.Promise.try_resolve t.stop !shutdown)));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    started:=true;
    if not t.live then `Stop_daemon else
    Fun.protect ~finally:(fun () -> revoke t;ignore (Eio.Promise.try_resolve t.stop !shutdown)) (fun () ->
      let serve () = Eio.Switch.run (fun scope ->
        let socket=private_listener ~sw:scope ~socket_path ~shutdown in
        Eio.Promise.resolve resolve_ready (Ok ());
        while true do
          Eio.Switch.check scope;
          Eio.Net.accept_fork ~sw:scope socket ~on_error:(fun _ -> ()) (fun flow _ ->
            match serve_connection t flow with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception _ -> ())
        done) in
      (try Watched_work.run serve ~watcher:(fun () -> Eio.Promise.await t.retired)
       with
       | Eio.Cancel.Cancelled _ as exn ->
           ignore (Eio.Promise.try_resolve resolve_ready (Error Unavailable));raise exn
       | _ -> ignore (Eio.Promise.try_resolve resolve_ready (Error Unavailable)));
      `Stop_daemon));
  (* Eio starts a fork callback immediately. A cancelled owner can instead
     decline the fork; no listener exists in that case and neither waiter may
     depend on the owner's later release hooks to make progress. *)
  if not !started then (
    revoke t;
    ignore (Eio.Promise.try_resolve resolve_ready (Error Unavailable));
    ignore (Eio.Promise.try_resolve t.stop !shutdown));
  (try Eio.Promise.await ready |> Result.map (fun () -> t) with
   | Eio.Cancel.Cancelled _ as exn ->
       revoke t;ignore (Eio.Cancel.protect (fun () -> await_stopped t));raise exn)
