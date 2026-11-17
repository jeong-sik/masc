module Objects = Agent_core.Checkpoint_objects
module Files = Keeper_checkpoint_store_history_files
module Decode = Keeper_checkpoint_store_decode
module Summary = Keeper_checkpoint_store_summary
module Lineage = Keeper_checkpoint_store_lineage
module Object_store = Keeper_checkpoint_object_store
module Digests = Map.Make (String)
open Decode

type t =
  | Written_lineage of
      { canonical_path : string
      ; identity : Summary.canonical_identity
      }
  | Read_files of
      { session_dir : string
      ; canonical_path : string
      ; canonical : Fs_compat.owned_regular_file_snapshot
      ; objects : (Objects.digest * Fs_compat.owned_regular_file_snapshot) list
      }

type revalidation =
  | Unchanged
  | Changed
  | Unavailable of checkpoint_load_error

let protect_read f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Unix.Unix_error (errno, _, _) as exn ->
    Error (Read_failed { cause = Os_error errno; detail = Printexc.to_string exn })
  | exn -> Error (Read_failed { cause = Read_raised; detail = Printexc.to_string exn })

let load_with ~after_object_read ~session_dir ~session_id =
  if not (Files.leaf_is_real_segment session_id)
  then Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = Files.agent_core_checkpoint_path ~session_dir ~session_id in
    let identity = Summary.canonical_identity_opt canonical_path in
    match Option.bind identity (fun identity ->
      Option.map (fun checkpoint -> checkpoint, identity)
        (Lineage.reusable_written_value ~canonical_path ~identity)) with
    | Some (checkpoint, identity) ->
      Ok (checkpoint, Written_lineage { canonical_path; identity })
    | None ->
      protect_read (fun () ->
        let ownership_root = Filename.dirname session_dir in
        match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root canonical_path with
        | Error error -> Error (classify_owned_read_error error)
        | Ok None -> Error Not_found
        | Ok (Some observed) ->
          let decoded = offload_checkpoint_cpu (fun () ->
            let open Result.Syntax in
            let* head = Objects.head_of_string observed.content in
            let files = ref Digests.empty in
            let read_object digest =
              let path = Object_store.path ~session_dir digest in
              match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root path with
              | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
              | Ok None -> Ok None
              | Ok (Some object_file) ->
                files := Digests.add (digest :> string) (digest, object_file.snapshot) !files;
                after_object_read digest;
                Ok (Some object_file.content)
            in
            let+ checkpoint = Objects.load_read_only ~read_object head in
            head, checkpoint, List.map snd (Digests.bindings !files)) in
          match decoded with
          | Error error -> Error (classify_objects_error error)
          | Ok (head, checkpoint, objects) ->
            let snapshot = observed.snapshot in
            let identity_before : Summary.canonical_identity =
              { device = snapshot.device; inode = snapshot.inode
              ; size = snapshot.file_size; mtime = snapshot.modified_at } in
            Summary.publish_summary_after_parse ~canonical_path
              ~identity_before:(Some identity_before) ~objects:Summary.Objects_seen head;
            Ok (checkpoint, Read_files
              { session_dir; canonical_path; canonical = snapshot; objects }))

let load = load_with ~after_object_read:(fun _digest -> ())

let revalidate_files ~session_dir ~canonical_path ~canonical ~objects =
  let ownership_root = Filename.dirname session_dir in
  let read path =
    Fs_compat.load_owned_regular_file_range ~ownership_root ~offset:0 ~max_bytes:0 path in
  let canonical_state () =
    match read canonical_path with
    | Error error -> Unavailable (classify_owned_read_error error)
    | Ok None -> Unavailable Not_found
    | Ok (Some observed) ->
      if Fs_compat.equal_owned_regular_file_snapshot canonical observed.snapshot
      then Unchanged else Changed
  in
  let rec object_state = function
    | [] -> Unchanged
    | (digest, snapshot) :: rest ->
      (match read (Object_store.path ~session_dir digest) with
       | Error error -> Unavailable (Objects_invalid (Objects.Object_unreadable
           { digest; detail = Fs_compat.owned_regular_file_read_error_to_string error }))
       | Ok None -> Unavailable (Objects_invalid (Objects.Object_missing digest))
       | Ok (Some observed) ->
         if Fs_compat.equal_owned_regular_file_snapshot snapshot observed.snapshot
         then object_state rest else Changed)
  in
  match canonical_state () with
  | Changed | Unavailable _ as state -> state
  | Unchanged ->
    let state = object_state objects in
    (* Do not report an old graph's missing object as the current graph's
       error if another canonical was published during this observation. *)
    (match canonical_state () with
     | Unchanged -> state
     | Changed | Unavailable _ as current -> current)

let revalidate witness =
  match protect_read (fun () ->
    Ok (match witness with
      | Written_lineage { canonical_path; identity } ->
        (match Summary.canonical_identity_opt canonical_path with
         | Some current when Summary.canonical_identity_equal current identity ->
           if Lineage.written_lineage_is_reusable ~canonical_path ~identity
           then Unchanged else Changed
         | Some _ | None -> Changed)
      | Read_files { session_dir; canonical_path; canonical; objects } ->
        revalidate_files ~session_dir ~canonical_path ~canonical ~objects)) with
  | Ok state -> state
  | Error error -> Unavailable error

module For_testing = struct
  let load_after_object_read = load_with
end
