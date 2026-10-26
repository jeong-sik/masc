module P = Endpoint_job_protocol
module L = Endpoint_job_launch
let ( let* ) = Result.bind
type error =
  | Invalid_storage | Storage_unavailable | Source_protocol_error
  | Offset_unavailable | Invalid_range | Interrupted | Capture_failed
  | Codec_error of P.codec_error
  | Publication_failed of Fs_compat.capability_write_error | Recovery_failed of string
let error_to_string = function
  | Invalid_storage -> "original output storage authority changed"
  | Storage_unavailable -> "original output I/O unavailable"
  | Source_protocol_error -> "output source returned no bytes without EOF"
  | Offset_unavailable -> "output exceeds this file backend's offset range"
  | Invalid_range -> "output read range invalid"
  | Interrupted -> "output capture interrupted before durable sealing"
  | Capture_failed -> "output capture failed before durable sealing"
  | Codec_error e -> P.error_to_string e
  | Publication_failed e -> Fs_compat.capability_write_error_to_string e
  | Recovery_failed detail -> "output publication recovery: " ^ detail
type seal = { byte_length : int64; sha256 : P.Sha256.t }
type state = Growing of int64 | Sealed of seal | Unavailable of error
type t = {
  file : Eio.File.rw_ty Eio.Resource.t;
  state : state Atomic.t;
  done_ : (seal,error) result Eio.Promise.t;
}
type chunk = { data : string; extent : P.extent }
type metadata_operation = Open_recovery | Publish of string
type metadata_stage = Waiting | Acquired
(* Transfer-buffer size only. Neither total output nor execution is capped. *)
let buffer_bytes = 65536
let cpu f = Domain_pool_ref.submit_cpu_or_inline f
let io f = try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ | End_of_file -> Error Storage_unavailable
let offset value =
  if value<0L || value>Optint.Int63.to_int64 Optint.Int63.max_int then Error Offset_unavailable
  else Ok (Optint.Int63.of_int64 value)
let tag = function P.Stdout -> "stdout" | P.Stderr -> "stderr"
let extent t = match Atomic.get t.state with
  | Growing n -> Ok (P.Growing n)
  | Sealed seal -> Ok (P.Sealed {byte_length=seal.byte_length;sha256=seal.sha256})
  | Unavailable e -> Error e
let await_sealed t = Eio.Promise.await t.done_

let with_lane registry stream f =
  let* outcome=Fs_compat.Publication_recovery.with_lane ~registry ~owner:("output-" ^ tag stream) f
    |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.lane_open_error_to_string e)) in
  match outcome with
  | Lane_released value -> value
  | Lane_release_failed {value;release_failure} ->
    let detail=Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure in
    Error (Recovery_failed (match value with Ok () -> detail | Error e -> error_to_string e ^ "; " ^ detail))
let with_metadata owner on_metadata operation f =
  on_metadata operation Waiting;
  L.with_storage_publication owner (fun () -> on_metadata operation Acquired;f ())
let publish owner on_metadata registry storage ~root_stat ~root_path stream ~leaf ~permissions content =
  let* target=Fs_compat.capability_publication_target ~allowed_root_path:root_path
      ~allowed_root_device:root_stat.Eio.File.Stat.dev ~allowed_root_inode:root_stat.ino
      ~parent_components:[] ~target_leaf:leaf ~permissions
    |> Result.map_error (fun e -> Recovery_failed (Fs_compat.capability_publication_target_error_to_string e)) in
  with_metadata owner on_metadata (Publish leaf) (fun () ->
    with_lane registry stream (fun recovery ->
      Fs_compat.create_capability_file_exclusive ~recovery ~parent:storage ~target content
      |> Result.map_error (fun e -> Publication_failed e)))

let start_with_hook ~after_chunk ~on_metadata ~sw ~fs ~owner ~stream ~source =
  Eio.Switch.check sw;
  let storage=L.storage owner in
  let* root_stat=io (fun () -> Eio.Path.stat ~follow:true storage) in
  let* ()=if root_stat.kind=`Directory && root_stat.uid=Int64.of_int (Unix.geteuid ())
      && root_stat.perm land 0o7777=0o700 then Ok () else Error Invalid_storage in
  let* root_path=io (fun () -> Eio.Path.native_exn storage) in
  let* recovery=with_metadata owner on_metadata Open_recovery (fun () ->
    Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root:storage
    |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.registry_error_to_string e))) in
  let leaf=tag stream ^ ".bin" in
  let* ()=publish owner on_metadata recovery storage ~root_stat ~root_path stream ~leaf ~permissions:0o600 "" in
  let* expected=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(storage / leaf)) in
  let* file=io (fun () -> Eio.Path.open_out ~sw ~create:`Never Eio.Path.(storage / leaf)) in
  let* actual=io (fun () -> Eio.File.stat file) in
  let valid_file byte_length (stat : Eio.File.Stat.t) =
    stat.kind=`Regular_file && stat.dev=actual.dev && stat.ino=actual.ino
    && stat.nlink=1L && stat.uid=root_stat.uid && stat.perm land 0o7777=0o600
    && Optint.Int63.to_int64 stat.size=byte_length in
  let validate_attachment byte_length =
    let* root=io (fun () -> Eio.Path.stat ~follow:false storage) in
    let* held=io (fun () -> Eio.File.stat file) in
    let* canonical=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(storage / leaf)) in
    if root.kind=`Directory && root.dev=root_stat.dev && root.ino=root_stat.ino
        && root.uid=root_stat.uid && root.perm land 0o7777=0o700
        && valid_file byte_length held && valid_file byte_length canonical
      then Ok () else Error Invalid_storage in
  let* ()=if valid_file 0L expected && valid_file 0L actual
    then validate_attachment 0L else Error Invalid_storage in
  let done_,resolve=Eio.Promise.create () in
  let t={file;state=Atomic.make (Growing 0L);done_} in
  let finish value =
    Atomic.set t.state (match value with Ok seal -> Sealed seal | Error e -> Unavailable e);
    Eio.Promise.resolve resolve value in
  let seal byte_length context =
    let* ()=validate_attachment byte_length in
    let* ()=io (fun () -> Eio.File.sync file) in
    let* ()=validate_attachment byte_length in
    let* original=P.request_to_json (P.Inspect (L.original owner)) |> Result.map_error (fun e -> Codec_error e) in
    let hash=cpu (fun () -> Digestif.SHA256.(to_hex (get context))) in
    let* sha256=P.Sha256.of_string hash |> Result.map_error (fun _ -> Capture_failed) in
    let content=cpu (fun () -> Yojson.Safe.to_string (`Assoc ["version",`Int 1;"original",original;
      "stream",`String (tag stream);"byte_length",`String (Int64.to_string byte_length);
      "sha256",`String hash;"file_device",`String (Int64.to_string actual.dev);
      "file_inode",`String (Int64.to_string actual.ino)])) in
    let* ()=validate_attachment byte_length in
    let* ()=publish owner on_metadata recovery storage ~root_stat ~root_path stream
      ~leaf:(tag stream ^ ".seal.json") ~permissions:0o400 content in
    let* ()=validate_attachment byte_length in
    Ok {byte_length;sha256} in
  let buffer=Cstruct.create buffer_bytes in
  let rec capture byte_length context =
    match Eio.Flow.single_read source buffer with
    | n ->
      if n<=0 then Error Source_protocol_error else
      let next=Int64.add byte_length (Int64.of_int n) in
      let* position=offset byte_length in
      let* _=offset next in
      let part=Cstruct.sub buffer 0 n in
      Eio.File.pwrite_all file ~file_offset:position [part];
      after_chunk ();
      let bytes=Cstruct.to_string part in
      let context=cpu (fun () -> Digestif.SHA256.feed_string context bytes) in
      Atomic.set t.state (Growing next);
      capture next context
    | exception End_of_file -> seal byte_length context in
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (match io (fun () -> capture 0L Digestif.SHA256.empty) with
     | Ok value -> finish value
     | Error e -> finish (Error e)
     | exception (Eio.Cancel.Cancelled _ as ex) ->
       let bt=Printexc.get_raw_backtrace () in finish (Error Interrupted);Printexc.raise_with_backtrace ex bt
     | exception ex ->
       let bt=Printexc.get_raw_backtrace () in finish (Error Capture_failed);Printexc.raise_with_backtrace ex bt);
    `Stop_daemon);
  Ok t

let start ~sw ~fs ~owner ~stream ~source =
  start_with_hook ~after_chunk:(fun () -> ()) ~on_metadata:(fun _ _ -> ()) ~sw ~fs ~owner ~stream ~source

module For_testing = struct
  type nonrec metadata_operation = metadata_operation = Open_recovery | Publish of string
  type nonrec metadata_stage = metadata_stage = Waiting | Acquired
  let start = start_with_hook
end

let read t ~offset:requested ~max_bytes =
  let* observed=extent t in
  let length=match observed with P.Growing n -> n | P.Sealed {byte_length;_} -> byte_length in
  if requested<0L || requested>length || max_bytes<=0 then Error Invalid_range else
  let count=Int64.min (Int64.sub length requested) (Int64.of_int (min buffer_bytes max_bytes)) |> Int64.to_int in
  let* position=offset requested in
  let buffer=Cstruct.create count in
  let* ()=if count=0 then Ok () else io (fun () -> Eio.File.pread_exact t.file ~file_offset:position [buffer]) in
  let* _=extent t in
  Ok {data=Cstruct.to_string buffer;extent=observed}
