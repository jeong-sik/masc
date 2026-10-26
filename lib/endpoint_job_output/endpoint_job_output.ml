module P = Endpoint_job_protocol
module L = Endpoint_job_launch
module R = Endpoint_job_registry
let ( let* ) = Result.bind
type error =
  | Invalid_storage | Storage_unavailable | Source_protocol_error
  | Offset_unavailable | Invalid_range | Interrupted | Capture_failed
  | Codec_error of P.codec_error
  | Registry_error of R.error
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
  | Registry_error e -> R.error_to_string e
  | Publication_failed e -> Fs_compat.capability_write_error_to_string e
  | Recovery_failed detail -> "output publication recovery: " ^ detail
type seal = { byte_length : int64; sha256 : P.Sha256.t }
type state = Growing of int64 | Sealed of seal | Unavailable of error
type reader = Captured of Eio.File.ro_ty Eio.Resource.t | Reopened of Fs_compat.owned_reader
type t = {
  file : reader;
  state : state Atomic.t;
  done_ : (seal,error) result Eio.Promise.t;
  validate_read : (unit -> (unit,error) result) option;
}
type chunk = { data : string; extent : P.extent }
type metadata_operation = Open_recovery | Publish of string
type metadata_stage = Waiting | Acquired
(* Transfer-buffer size only. Neither total output nor execution is capped. *)
let buffer_bytes = 65536
let cpu f = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ f
let io f = try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ | End_of_file -> Error Storage_unavailable
let reader_stat = function
  | Captured file -> Eio.File.stat file
  | Reopened file -> Fs_compat.owned_reader_stat file
let reader_pread_exact reader ~file_offset buffers = match reader with
  | Captured file -> Eio.File.pread_exact file ~file_offset buffers
  | Reopened file ->
    let position=ref (Optint.Int63.to_int64 file_offset) in
    List.iter (fun buffer ->
      let rec fill consumed =
        if consumed<Cstruct.length buffer then (
          let data=Fs_compat.owned_reader_pread file ~offset:!position ~length:(Cstruct.length buffer-consumed) in
          let n=String.length data in
          if n=0 then raise End_of_file;
          Cstruct.blit_from_string data 0 buffer consumed n;
          position:=Int64.add !position (Int64.of_int n);
          fill (consumed+n)) in
      fill 0) buffers
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
  let t={file=Captured (file :> Eio.File.ro_ty Eio.Resource.t);state=Atomic.make (Growing 0L);done_;validate_read=None} in
  let finish value =
    Atomic.set t.state (match value with Ok seal -> Sealed seal | Error e -> Unavailable e);
    Eio.Promise.resolve resolve value in
  let seal byte_length context =
    let* ()=validate_attachment byte_length in
    let* ()=io (fun () -> Eio.File.sync file) in
    let* ()=validate_attachment byte_length in
    let* original=P.request_to_json (P.Inspect (L.original owner)) |> Result.map_error (fun e -> Codec_error e) in
    let hash=cpu (fun () -> Agent_core_sha256.(to_hex (get context))) in
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
      let context=cpu (fun () -> Agent_core_sha256.feed_string context bytes) in
      Atomic.set t.state (Growing next);
      capture next context
    | exception End_of_file -> seal byte_length context in
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    (match io (fun () -> capture 0L Agent_core_sha256.empty) with
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

let read t ~offset:requested ~max_bytes =
  let validate ()=match t.validate_read with None -> Ok () | Some f -> f () in
  let* ()=validate () in
  let* observed=extent t in
  let length=match observed with P.Growing n -> n | P.Sealed {byte_length;_} -> byte_length in
  if requested<0L || requested>length || max_bytes<=0 then Error Invalid_range else
  let count=Int64.min (Int64.sub length requested) (Int64.of_int (min buffer_bytes max_bytes)) |> Int64.to_int in
  let* position=offset requested in
  let buffer=Cstruct.create count in
  let* ()=if count=0 then Ok () else io (fun () -> reader_pread_exact t.file ~file_offset:position [buffer]) in
  let* _=extent t in
  let* ()=validate () in
  Ok {data=Cstruct.to_string buffer;extent=observed}

(* This private seal is a controller record, not payload text or a protocol
   result. Exact fields and the embedded original are still strictly decoded. *)
let seal_fields value =
  let required=["version";"original";"stream";"byte_length";"sha256";"file_device";"file_inode"] in
  match value with
  | `Assoc fields ->
    let names=List.map fst fields in
    if List.length names=List.length required
        && List.for_all (fun name -> List.length (List.filter ((=) name) names)=1) required
      then Ok fields else Error Invalid_storage
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> Error Invalid_storage

let seal_count = function
  | `String value -> (match Int64.of_string_opt value with
      | Some n when n>=0L && Int64.to_string n=value -> Ok n
      | None | Some _ -> Error Invalid_storage)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> Error Invalid_storage

let decode_seal ~original ~stream content =
  let json=try Ok (Yojson.Safe.from_string content) with Yojson.Json_error _ -> Error Invalid_storage in
  let* json=json in let* fields=seal_fields json in
  let get key=List.assoc key fields in
  let* ()=if get "version"=`Int 1 && get "stream"=`String (tag stream)
    then Ok () else Error Invalid_storage in
  let* request=P.request_of_json (get "original") |> Result.map_error (fun e -> Codec_error e) in
  let* ()=match request with
    | P.Inspect actual when actual=original -> Ok ()
    | P.Start _ | Reconcile_admission _ | Activate _ | Inspect _ | Read_output _ | Cancel _ | Release _ -> Error Invalid_storage in
  let* byte_length=seal_count (get "byte_length") in
  let* device=seal_count (get "file_device") in let* inode=seal_count (get "file_inode") in
  let* sha256=match get "sha256" with
    | `String value -> P.Sha256.of_string value |> Result.map_error (fun _ -> Invalid_storage)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> Error Invalid_storage in
  Ok ({byte_length;sha256},device,inode)

let stable_stat (before : Eio.File.Stat.t) (after : Eio.File.Stat.t) =
  (* Reads may advance atime; every other observed property must remain fixed. *)
  {before with atime=after.atime}=after

let reopen_with_hook ~after_chunk ~after_stat ~sync_reader ~sw ~storage ~stream =
  Eio.Switch.check sw;
  let* known=R.refresh (R.storage_record storage) |> Result.map_error (fun e -> Registry_error e) in
  let* ()=match R.launch_state known with
    | R.Requested _ -> Ok () | R.Not_requested -> Error Invalid_storage in
  let directory=R.storage_path storage in
  let* root=io (fun () -> Eio.Path.stat ~follow:true directory) in
  let valid_root (stat : Eio.File.Stat.t) =
    stat.kind=`Directory && stat.dev=root.dev && stat.ino=root.ino
    && stat.uid=Int64.of_int (Unix.geteuid ()) && stat.perm land 0o7777=0o700 in
  let* ()=if valid_root root then Ok () else Error Invalid_storage in
  let private_file permission (stat : Eio.File.Stat.t) =
    stat.kind=`Regular_file && stat.nlink=1L && stat.uid=root.uid
    && stat.perm land 0o7777=permission in
  let open_private leaf permission =
    let path=Eio.Path.(directory / leaf) in
    let* before=io (fun () -> Eio.Path.stat ~follow:false path) in
    let* ()=if private_file permission before then Ok () else Error Invalid_storage in
    after_stat ~leaf;
    let* opened=io (fun () -> Fs_compat.open_owned_reader ~sw ~parent:directory ~leaf) in
    let* opened=opened |> Result.map_error (fun _ -> Invalid_storage) in
    let file=Reopened opened in
    let* held=io (fun () -> reader_stat file) in
    let* canonical=io (fun () -> Eio.Path.stat ~follow:false path) in
    if stable_stat before held && stable_stat before canonical then Ok (file,before)
    else Error Invalid_storage in
  let* metadata,metadata_stat=open_private (tag stream ^ ".seal.json") 0o400 in
  let metadata_length=Optint.Int63.to_int64 metadata_stat.size in
  let* ()=if metadata_length>=0L && metadata_length<=Int64.of_int Sys.max_string_length
    then Ok () else Error Invalid_storage in
  let content=Cstruct.create (Int64.to_int metadata_length) in
  let* ()=io (fun () -> reader_pread_exact metadata ~file_offset:Optint.Int63.zero [content]) in
  let original=P.original ~binding:(R.binding known) ~admission_id:(R.admission_id known) in
  let* seal,device,inode=cpu (fun () -> decode_seal ~original ~stream (Cstruct.to_string content)) in
  let* file,file_stat=open_private (tag stream ^ ".bin") 0o600 in
  let* ()=if file_stat.dev=device && file_stat.ino=inode
      && Optint.Int63.to_int64 file_stat.size=seal.byte_length
    then Ok () else Error Invalid_storage in
  let validate () =
    let* current_root=io (fun () -> Eio.Path.stat ~follow:false directory) in
    let* held=io (fun () -> reader_stat file) in
    let* canonical=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(directory / (tag stream ^ ".bin"))) in
    let* held_metadata=io (fun () -> reader_stat metadata) in
    let* canonical_metadata=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(directory / (tag stream ^ ".seal.json"))) in
    let* ()=if valid_root current_root && stable_stat file_stat held && stable_stat file_stat canonical
        && stable_stat metadata_stat held_metadata && stable_stat metadata_stat canonical_metadata
      then Ok () else Error Invalid_storage in
    let* _=R.refresh known |> Result.map_error (fun e -> Registry_error e) in Ok () in
  let buffer=Cstruct.create buffer_bytes in
  let rec hash position context =
    if position=seal.byte_length then Ok context else
    let count=Int64.min (Int64.of_int buffer_bytes) (Int64.sub seal.byte_length position) |> Int64.to_int in
    let part=Cstruct.sub buffer 0 count in
    let* file_offset=offset position in
    let* ()=io (fun () -> reader_pread_exact file ~file_offset [part]) in
    let bytes=Cstruct.to_string part in
    let context=cpu (fun () -> Agent_core_sha256.feed_string context bytes) in
    after_chunk ();
    hash (Int64.add position (Int64.of_int count)) context in
  let* ()=validate () in
  let* context=hash 0L Agent_core_sha256.empty in
  let actual=cpu (fun () -> Agent_core_sha256.(to_hex (get context))) in
  let* ()=if actual=P.Sha256.to_string seal.sha256 then Ok () else Error Invalid_storage in
  let* ()=validate () in
  let sync leaf = function
    | Captured _ -> Error Invalid_storage
    | Reopened reader ->
      let* synced=io (fun () -> sync_reader ~parent:directory ~leaf reader) in
      synced |> Result.map_error (fun _ -> Invalid_storage) in
  let* ()=sync (tag stream ^ ".bin") file in
  let* ()=sync (tag stream ^ ".seal.json") metadata in
  let* ()=validate () in
  Eio.Switch.check sw;
  let done_,resolve=Eio.Promise.create () in Eio.Promise.resolve resolve (Ok seal);
  Ok {file;state=Atomic.make (Sealed seal);done_;validate_read=Some validate}

let reopen ~sw ~storage ~stream =
  reopen_with_hook ~after_chunk:(fun () -> ()) ~after_stat:(fun ~leaf:_ -> ())
    ~sync_reader:Fs_compat.sync_owned_reader ~sw ~storage ~stream

let revalidate_sealed t =
  match Atomic.get t.state,t.validate_read with
  | Sealed seal,Some validate -> let* ()=validate () in Ok seal
  | Unavailable e,_ -> Error e
  | Growing _,_ | Sealed _,None -> Error Invalid_storage

module For_testing = struct
  type nonrec metadata_operation = metadata_operation = Open_recovery | Publish of string
  type nonrec metadata_stage = metadata_stage = Waiting | Acquired
  let start = start_with_hook
  let reopen ~after_chunk ~after_stat ~before_sync ~sw ~storage ~stream =
    let sync_reader ~parent ~leaf reader =
      Fs_compat.Owned_reader_for_testing.sync_owned_reader ~before_sync:(before_sync ~leaf) ~parent ~leaf reader in
    reopen_with_hook ~after_chunk ~after_stat ~sync_reader ~sw ~storage ~stream
end
