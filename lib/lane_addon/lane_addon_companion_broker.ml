module P=Browser_extension_protocol
type error = Unavailable | Not_started | Outcome_unknown
type selection = { browser_instance_id:string; tab_id:int }
type completion = Released | Abandoned
type binding = {
  execute:P.command -> (Yojson.Safe.t,P.error) result;
  finish:completion -> unit;
}
type phase = Pending | Claimed | Withdrawn
type t = {
  socket_path:string; max_message_bytes:int;
  grants:(string,grant) Hashtbl.t;
  retired:unit Eio.Promise.t; retire:unit Eio.Promise.u;
  stopped:unit Eio.Promise.t; stop:unit Eio.Promise.u;
  mutable live:bool;
}
and grant = {
  broker:t; invocation_id:string; operation_id:string;
  bind:selection -> (binding,error) result;
  cancelled:unit Eio.Promise.t; cancel:unit Eio.Promise.u;
  mutable phase:phase;
}
let ( let* )=Result.bind
let error_json = function
  | Unavailable -> `Assoc ["error",`String "unavailable"]
  | Not_started -> `Assoc ["error",`String "not_started"]
  | Outcome_unknown -> `Assoc ["error",`String "outcome_unknown"]
let revoke t =
  t.live<-false;ignore (Eio.Promise.try_resolve t.retire ());
  Hashtbl.clear t.grants
let await_stopped t = Eio.Promise.await t.stopped
let cancel grant =
  grant.phase<-Withdrawn;
  Hashtbl.remove grant.broker.grants grant.invocation_id;
  ignore (Eio.Promise.try_resolve grant.cancel ())
let end_invocation grant = match grant.phase with
  | Pending -> cancel grant
  | Claimed | Withdrawn -> ()
let descriptor grant = `Assoc ["socket_path",`String grant.broker.socket_path;
  "invocation_id",`String grant.invocation_id;"max_message_bytes",`Int grant.broker.max_message_bytes]
let issue broker ~bind =
  if not broker.live then Error Unavailable else
  let invocation_id=Digestif.SHA256.(to_hex (digest_string (Crypto_rng.generate 32))) in
  let cancelled,cancel=Eio.Promise.create () in
  let grant={broker;invocation_id;operation_id=Random_id.uuid_v7 ();bind;
    cancelled;cancel;phase=Pending} in
  Hashtbl.add broker.grants invocation_id grant;Ok grant
let parse raw =
  match Yojson.Safe.from_string raw with
  | value -> Lane_addon_action.canonical value |> Result.map_error (fun _ -> Not_started)
  | exception Yojson.Json_error _ -> Error Not_started
let handshake = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["browser_instance_id";"invocation_id";"tab_id"] ->
      (match List.assoc "invocation_id" fields,List.assoc "browser_instance_id" fields,List.assoc "tab_id" fields with
       | `String invocation_id,`String browser_instance_id,`Int tab_id when tab_id>=0 ->
           let* _=Browser_lane.client_id_of_string browser_instance_id |> Result.map_error (fun _ -> Not_started) in
           Ok (invocation_id,{browser_instance_id;tab_id})
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
  | Pending | Withdrawn -> false
let while_peer_waits grant reader work =
  let departed=ref false in
  let result=Watched_work.run (fun () ->
    Eio.Fiber.check ();
    if !departed || not (admitted grant) then None else Some (work ()))
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
    let* invocation_id,selection=handshake value in
    match Hashtbl.find_opt t.grants invocation_id with
    | Some ({phase=Pending;_} as grant) when t.live ->
        (* Consume before calling the host factory, which can yield while it
           freshly reads declarations. Another socket cannot steal the bind. *)
        grant.phase<-Claimed;
        Ok (grant,selection)
    | Some {phase=(Pending|Claimed|Withdrawn);_}|None -> Error Not_started in
  match select () with
  | Error error -> write t flow (error_json error)
  | Ok (grant,selection) ->
    Fun.protect ~finally:(fun () -> cancel grant) (fun () ->
      let run () =
        if not (admitted grant) then write t flow (error_json Not_started) else
        let binding,departed=while_peer_waits grant reader (fun () -> grant.bind selection) in
        match binding with
        | None -> ()
        | Some (Error error) -> if not departed && admitted grant then write t flow (error_json error)
        | Some (Ok binding) ->
          let completion=ref Abandoned in
          Fun.protect ~finally:(fun () -> binding.finish !completion) (fun () ->
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
                  (* A departed provider cannot leave an extension effect
                     running behind a released host scope. Clients send one
                     command and await its reply; pipelined bytes also abandon
                     the current uncertain operation. *)
                  let result,departed=while_peer_waits grant reader (fun () -> binding.execute command) in
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
            loop ())) in
      Watched_work.run run ~watcher:(fun () -> Eio.Promise.await grant.cancelled))
let private_listener ~sw ~directory ~directory_identity ~socket_path =
  Eio.Cancel.protect (fun () ->
    let fd,identity=Eio_unix.run_in_systhread (fun () ->
      let fd=Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      try Unix.set_nonblock fd;Unix.bind fd (Unix.ADDR_UNIX socket_path);Unix.listen fd 1;
        fd,Unix.lstat socket_path
      with exn -> Unix.close fd;raise exn) in
    (* Eio.Net.listen installs an unconditional path unlink. Import only the
       descriptor and own removal ourselves, after checking both identities. *)
    Eio.Switch.on_release sw (fun () -> Eio_unix.run_in_systhread (fun () ->
      Unix.close fd;
      try
        let parent=Unix.lstat directory and current=Unix.lstat socket_path in
        if parent.st_kind=Unix.S_DIR && parent.st_dev=directory_identity.Unix.st_dev
          && parent.st_ino=directory_identity.st_ino && current.st_kind=Unix.S_SOCK
          && current.st_dev=identity.Unix.st_dev && current.st_ino=identity.st_ino
        then Unix.unlink socket_path
      with Unix.Unix_error (Unix.ENOENT,_,_) -> ()));
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
       | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok info)
    with Unix.Unix_error _ -> Error Unavailable) in
  let* directory_identity=checked in
  let socket_path=Filename.concat directory "s" in
  let retired,retire=Eio.Promise.create () and stopped,stop=Eio.Promise.create () in
  let t={socket_path;max_message_bytes;grants=Hashtbl.create 4;retired;retire;stopped;stop;live=true} in
  let ready,resolve_ready=Eio.Promise.create () in
  let started=ref false in
  Eio.Switch.check sw;
  Eio.Switch.on_release sw (fun () -> if not !started then (
    revoke t;
    ignore (Eio.Promise.try_resolve resolve_ready (Error Unavailable));
    ignore (Eio.Promise.try_resolve t.stop ())));
  Eio.Fiber.fork_daemon ~sw (fun () ->
    started:=true;
    if not t.live then `Stop_daemon else
    Fun.protect ~finally:(fun () -> revoke t;ignore (Eio.Promise.try_resolve t.stop ())) (fun () ->
      let serve () = Eio.Switch.run (fun scope ->
        let socket=private_listener ~sw:scope ~directory ~directory_identity ~socket_path in
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
    ignore (Eio.Promise.try_resolve t.stop ()));
  (try Eio.Promise.await ready |> Result.map (fun () -> t) with
   | Eio.Cancel.Cancelled _ as exn ->
       revoke t;Eio.Cancel.protect (fun () -> await_stopped t);raise exn)
