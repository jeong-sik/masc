module B = Lane_addon_companion_broker
type creation_error = Unavailable | Cleanup_unconfirmed
type cleanup = Paths_retained of string

type settlement =
  { notify : B.completion Eio.Promise.u
  ; settled : (unit, string) result Eio.Promise.t
  }

type t =
  { broker : B.t
  ; cleanup : (cleanup, string) result Eio.Lazy.t
  ; sw : Eio.Switch.t
  ; settlements : settlement list ref
  ; releasing : bool ref
  }

let broker t = t.broker
let cleanup t = Eio.Lazy.force t.cleanup

let on_finish t settle =
  if !(t.releasing) then Error "private companion is retiring"
  else
    let notified, notify = Eio.Promise.create () in
    let settled, resolve = Eio.Promise.create () in
    let started = ref false in
    (* This release fallback never suspends and never claims settlement. *)
    let unconfirmed () =
      ignore (Eio.Promise.try_resolve resolve (Error "private settlement unconfirmed")) in
    try
      Eio.Switch.check t.sw;
      Eio.Switch.on_release t.sw unconfirmed;
      t.settlements := {notify; settled} :: !(t.settlements);
      (match Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
         started := true;
         if not (Eio.Promise.is_resolved settled) then (
           (* fun-protect-finally-ok: resolving the promise cannot suspend. *)
           Fun.protect ~finally:unconfirmed (fun () ->
             let outcome =
               match settle (Eio.Promise.await notified) with
               | Ok () -> Ok ()
               | Error _ -> Error "private settlement unconfirmed"
               | exception (Eio.Cancel.Cancelled _ as exn) ->
                 ignore (Eio.Promise.try_resolve resolve (Error "private settlement cancelled"));
                 raise exn
               | exception _ -> Error "private settlement unconfirmed" in
             ignore (Eio.Promise.try_resolve resolve outcome)));
         `Stop_daemon)
       with
       | () ->
         if !started then Ok (fun completion -> ignore (Eio.Promise.try_resolve notify completion))
         else (unconfirmed (); Error "private settlement unavailable")
       | exception (Eio.Cancel.Cancelled _ as exn) -> unconfirmed (); raise exn
       | exception _ -> unconfirmed (); Error "private settlement unavailable")
    with
    | Eio.Cancel.Cancelled _ as exn -> unconfirmed (); raise exn
    | Invalid_argument _ -> unconfirmed (); Error "private settlement unavailable"

open Result.Syntax

let same_directory expected current =
  current.Unix.st_dev = expected.Unix.st_dev && current.st_ino = expected.st_ino
  && current.st_kind = Unix.S_DIR && current.st_uid = Unix.getuid () && current.st_perm = 0o700

let same_socket expected current =
  current.Unix.st_dev = expected.Unix.st_dev && current.st_ino = expected.st_ino
  && current.st_kind = Unix.S_SOCK && current.st_uid = Unix.getuid ()

let create ~sw ~max_message_bytes =
  let original = ref None in
  let settlements = ref [] and releasing = ref false in
  let startup_cleanup = ref None in
  let published = ref false and cleanup_failure = ref None in
  (* Enter startup and install its guard before protected allocation. *)
  let result = Eio.Switch.run (fun startup ->
    Eio.Switch.on_release startup (fun () ->
      if not !published then Option.iter (fun cleanup ->
        match Eio.Lazy.force cleanup with
        | Ok (Paths_retained _) -> cleanup_failure := Some "private companion startup path retained"
        | Error detail -> cleanup_failure := Some detail) !startup_cleanup);
    let* directory, identity, cleanup = Eio.Cancel.protect (fun () ->
      let* directory, identity = Eio_unix.run_in_systhread (fun () ->
        let allocated = ref false in
        try
          let directory = Filename.temp_dir "mcp-" "" in
          allocated := true;
          let directory = Unix.realpath directory in
          Ok (directory, Unix.lstat directory)
        with Unix.Unix_error _ | Sys_error _ ->
          if !allocated then cleanup_failure := Some "private companion allocation identity unavailable";
          Error "private companion allocation unavailable") in
      let cleanup = Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
        releasing := true;
        Option.iter B.revoke !original;
        let stopped = match !original with
          | None -> Ok ()
          | Some owner -> B.await_stopped owner in
        (* Broker completion notifications cannot still arrive after its join. *)
        List.iter (fun pending -> ignore (Eio.Promise.try_resolve pending.notify B.Abandoned)) !settlements;
        let settled = Eio.Fiber.List.map (fun pending -> Eio.Promise.await pending.settled) !settlements in
        (* POSIX pathname deletion is not conditional on an inode. Even an
           unchanged lstat followed by unlink/rmdir can delete a same-UID
           successor. Close the owned resources and retain both names. *)
        match stopped, List.find_opt Result.is_error settled with
        | Ok (), None ->
            Log.Misc.warn "Private companion stopped IPC path retained: %s" directory;
            Ok (Paths_retained directory)
        | Error B.Listener_close_unconfirmed, _ ->
            Error "private companion listener close unconfirmed"
        | Ok (), Some (Error detail) -> Error detail
        | Ok (), Some (Ok ()) -> Error "private settlement unconfirmed") in
      startup_cleanup := Some cleanup;
      Ok (directory, identity, cleanup)) in
    Eio.Switch.on_release sw (fun () ->
      match Eio.Lazy.force cleanup with
      | Ok (Paths_retained _) -> ()
      | Error _ -> Log.Misc.warn "Private companion allocation remains retained");
    let* owner = B.create ~sw ~directory ~max_message_bytes
      |> Result.map_error (fun _ -> "private companion listener unavailable") in
    original := Some owner;
    let* socket_identity = Eio_unix.run_in_systhread (fun () ->
      try
        let before = Unix.lstat directory in
        let socket = Unix.lstat (Filename.concat directory "s") in
        let after = Unix.lstat directory in
        if same_directory identity before && same_directory identity after
          && socket.st_kind = Unix.S_SOCK && socket.st_uid = Unix.getuid () then Ok socket
        else Error "private companion allocation identity changed"
      with Unix.Unix_error _ -> Error "private companion socket unavailable") in
    let* () = Eio_unix.run_in_systhread (fun () ->
      try
        if same_directory identity (Unix.lstat directory)
          && same_socket socket_identity (Unix.lstat (Filename.concat directory "s")) then Ok ()
        else Error "private companion allocation identity changed"
      with Unix.Unix_error _ -> Error "private companion socket unavailable") in
    Eio.Fiber.check ();
    published := true;
    Ok {broker=owner; cleanup; sw; settlements; releasing}) in
  match !cleanup_failure with
  | Some _ -> Error Cleanup_unconfirmed
  | None -> Result.map_error (fun _ -> Unavailable) result
