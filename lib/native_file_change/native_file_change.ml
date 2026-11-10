type kind = Directory | File
type target = { path : string; kind : kind; device : int; inode : int }
type operation = Create | Register of string | Drain
type error =
  | Unsupported_platform
  | System_error of { operation : operation; error : Unix.error }
  | Ambiguous_watch_identity
  | Target_changed
  | Closed
type loss = Overflow | Target_retired | Unknown_watch
type change = Changed of target list | Coverage_lost of loss

type raw
external supported : unit -> bool = "masc_file_change_supported"
external create_raw : string array -> bool array -> int array -> int array -> raw = "masc_file_change_create"
external descriptor : raw -> Unix.file_descr = "masc_file_change_descriptor"
external drain_raw : raw -> int * int list = "masc_file_change_drain"
external close_raw : raw -> unit = "masc_file_change_close"

type t = {
  raw : raw;
  descriptor : Eio_unix.Fd.t;
  targets : target array;
  mutable closed : bool;
  mutable release : Eio.Switch.hook;
}

let close t =
  if not t.closed then begin
    t.closed <- true;
    Eio.Switch.remove_hook t.release;
    (* The wrapper stops accepting users before its actual owner closes the
       queue. A pending owner wait must be cancelled before closing. *)
    ignore (Eio_unix.Fd.remove t.descriptor : Unix.file_descr option);
    close_raw t.raw
  end
;;

let create ~sw ~targets =
  if not (supported ()) then Error Unsupported_platform
  else
    let targets = Array.of_list targets in
    let paths = Array.map (fun target -> target.path) targets in
    let directories = Array.map (fun target -> target.kind = Directory) targets in
    let devices = Array.map (fun target -> target.device) targets in
    let inodes = Array.map (fun target -> target.inode) targets in
    match create_raw paths directories devices inodes with
    | exception Unix.Unix_error (Unix.EEXIST, "file_change_ambiguous", _) ->
      Error Ambiguous_watch_identity
    | exception Unix.Unix_error (_, "file_change_target_changed", _) ->
      Error Target_changed
    | exception Unix.Unix_error (error, operation, path) ->
      let operation = if String.equal operation "file_change_register" then Register path else Create in
      Error (System_error { operation; error })
    | raw ->
      let imported = ref None in
      (match
         let fd = Eio_unix.Fd.of_unix ~sw ~blocking:false ~seekable:false
             ~close_unix:false (descriptor raw) in
         imported := Some fd;
         let t = { raw; descriptor = fd; targets; closed = false; release = Eio.Switch.null_hook } in
         t.release <- Eio.Switch.on_release_cancellable sw (fun () -> close t);
         Ok t
       with
       | result -> result
       | exception exn ->
         Option.iter (fun fd -> ignore (Eio_unix.Fd.remove fd : Unix.file_descr option)) !imported;
         close_raw raw;
         raise exn)
;;

let drain t =
  if t.closed then Error Closed
  else
    match Eio_unix.Fd.use_exn "file change drain" t.descriptor (fun _ -> drain_raw t.raw) with
    | 0, [] -> Ok None
    | 0, indices ->
      Ok (Some (Changed (List.sort_uniq Int.compare indices |> List.map (Array.get t.targets))))
    | 1, _ -> Ok (Some (Coverage_lost Overflow))
    | 2, _ -> Ok (Some (Coverage_lost Target_retired))
    | _, _ -> Ok (Some (Coverage_lost Unknown_watch))
    | exception Unix.Unix_error (error, _, _) -> Error (System_error { operation = Drain; error })
;;

let rec await t =
  if t.closed then Error Closed
  else begin
    Eio_unix.Fd.use_exn "file change readiness" t.descriptor Eio_unix.await_readable;
    match drain t with
    | Ok None -> await t
    | Ok (Some change) -> Ok change
    | Error error -> Error error
  end
;;

let error_to_string = function
  | Unsupported_platform -> "kernel file observation is unsupported on this platform"
  | Ambiguous_watch_identity -> "kernel file watch identities changed during registration"
  | Target_changed -> "kernel file watch target changed during registration"
  | Closed -> "kernel file observation is closed"
  | System_error { operation; error } ->
    let operation = match operation with Create -> "create" | Register _ -> "register" | Drain -> "drain" in
    "kernel file observation " ^ operation ^ ": " ^ Unix.error_message error
;;
