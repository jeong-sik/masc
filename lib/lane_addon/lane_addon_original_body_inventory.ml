module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Digests = Set.Make (String)
module Body_keys = Set.Make (struct
  type t = string * string

  let compare (a1, b1) (a2, b2) =
    let c = String.compare a1 a2 in
    if c <> 0 then c else String.compare b1 b2
end)
open Result.Syntax

type report = { protected_digests : int; unprotected_files : int;
  unprotected_logical_bytes : int64 }
type marks = { digests : Digests.t; active_bodies : Body_keys.t }
type error = Inventory_unavailable of string

let error_to_string = function
  | Inventory_unavailable detail -> "original request inventory unavailable: " ^ detail

(* Successor intent carries no scope. Protect its digest in every scope while
   the parent is active; an identical body may be shared. *)
let protect_record marked record =
  let digest = Owner.Record.request_digest record in
  let digests = Digests.add digest marked.digests in
  let active_bodies =
    Body_keys.add (Store.digest (Owner.Record.scope record),digest) marked.active_bodies in
  let* digests = List.fold_left (fun result event ->
    let* digests = result in
    match event with
    | Progress.Successor_intended successor -> Ok (Digests.add successor.request_digest digests)
    | Preparation_intended {request;_} | Replacement_intended {request;_} ->
      let* digest = Owner.request_digest request in
      Ok (Digests.add digest digests)
    | Dispatch_intended | Admission_declined _ | Execution_observed _ | Judgment_retained _
    | Preparation_observed _ | Replacement_observed _ | Commit_intended _ | Commit_uncertain _
    | Commit_retry_observed _ | Commit_observed _ | Commit_conflicted _ | Refused _
    | Refusal_settled _ | Successor_observed _ | Observer _ -> Ok digests)
    (Ok digests) (Progress.events (Owner.Record.progress record)) in
  Ok {digests;active_bodies}

let run ~store =
  (* Parser errors can include snippets of private request bodies or records.
     Startup reports the refusal without exposing those input bytes. *)
  let unavailable _detail = Inventory_unavailable "a record or body could not be safely validated" in
  let* marked = Store.fold_startup_tool_request_owners store
    ~init:{digests=Digests.empty;active_bodies=Body_keys.empty}
    ~f:(fun marked ~directory_name ~file_name json ->
      let* record = Owner.decode_published ~directory_name ~file_name json in
      protect_record marked record) |> Result.map_error unavailable in
  let* bodies = Store.tool_request_body_inventory_all store
    |> Result.map_error unavailable in
  let present = List.fold_left (fun present (entry : Store.tool_request_body_entry) ->
    Body_keys.add (entry.scope_directory,entry.request_digest) present) Body_keys.empty bodies in
  let* () = if Body_keys.subset marked.active_bodies present then Ok ()
    else Error (Inventory_unavailable "an active original request body is missing") in
  let* unprotected_files,unprotected_logical_bytes =
    List.fold_left (fun counts (entry : Store.tool_request_body_entry) ->
      let* count,bytes = counts in
      if Digests.mem entry.request_digest marked.digests then Ok (count,bytes)
      else
        let size = entry.snapshot.Unix.st_size in
        if size < 0 then Error (Inventory_unavailable "a live body has a negative logical size")
        else
          let size = Int64.of_int size in
          if Int64.compare bytes (Int64.sub Int64.max_int size) > 0 then
            Error (Inventory_unavailable "live body logical sizes cannot be represented")
          else Ok (count + 1,Int64.add bytes size)) (Ok (0,0L)) bodies in
  Ok {protected_digests=Digests.cardinal marked.digests;
      unprotected_files;unprotected_logical_bytes}

let run_at_startup ~base_path =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  match Unix.lstat runtime_root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Ok {protected_digests=0;unprotected_files=0;unprotected_logical_bytes=0L}
  | exception Unix.Unix_error (error, operation, _) ->
    Error (Inventory_unavailable (operation ^ ": " ^ Unix.error_message error))
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    run ~store:(Store.create ~root:(Store.directory ~masc_dir:runtime_root))
  | _ -> Error (Inventory_unavailable "workspace runtime root is not a directory")
