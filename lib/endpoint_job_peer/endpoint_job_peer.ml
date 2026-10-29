type identity = { uid : int; gid : int; process_id : int }
type t = { fd : Eio_unix.Fd.t; identity : identity }
type error =
  | Unsupported
  | Invalid_uid
  | Unsupported_transport
  | Not_connected
  | Closed
  | Uid_mismatch
  | Identity_changed
  | Syscall_failed of Unix.error

let error_to_string = function
  | Unsupported -> "endpoint kernel peer credentials unavailable"
  | Invalid_uid -> "endpoint control account UID invalid"
  | Unsupported_transport -> "endpoint control requires a Unix stream socket"
  | Not_connected -> "endpoint control socket is not connected"
  | Closed -> "endpoint control connection closed"
  | Uid_mismatch -> "endpoint control account does not match policy"
  | Identity_changed -> "endpoint control connection identity changed"
  | Syscall_failed error -> "endpoint control credential read failed: " ^ Unix.error_message error

external supported_raw : unit -> bool = "masc_endpoint_peer_supported"
external credentials_raw : Unix.file_descr -> (int * int * int) option
  = "masc_endpoint_peer_credentials"
let supported=supported_raw ()

let read fd =
  Eio_unix.Fd.use fd ~if_closed:(fun () -> Error Closed) (fun raw ->
    match credentials_raw raw with
    | Some (uid,gid,process_id) -> Ok {uid;gid;process_id}
    | None -> Error Unsupported_transport
    | exception Unix.Unix_error (Unix.ENOTCONN,_,_) -> Error Not_connected
    | exception Unix.Unix_error (error,_,_) -> Error (Syscall_failed error))

let authenticate ~allowed_uid flow =
  if allowed_uid<0 then Error Invalid_uid
  else if not supported then Error Unsupported
  else match Eio_unix.Resource.fd_opt flow with
    | None -> Error Unsupported_transport
    | Some fd ->
      (match read fd with
       | Error error -> Error error
       | Ok identity ->
         if identity.uid<>allowed_uid then Error Uid_mismatch
         else Ok {fd;identity})

let identity peer=peer.identity
let revalidate ~allowed_uid peer =
  if allowed_uid<0 then Error Invalid_uid
  else match read peer.fd with
    | Error error -> Error error
    | Ok identity ->
        if identity.uid<>allowed_uid then Error Uid_mismatch
        else if identity<>peer.identity then Error Identity_changed
        else Ok ()
