module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Digests = Set.Make (String)
module Body_keys = Set.Make (struct type t = string * string let compare = Stdlib.compare end)
open Result.Syntax

type archive = Archive_not_needed | Archive_read
type report = { protected_digests : int; removed : int; archive : archive }
type marks = { digests : Digests.t; active_bodies : Body_keys.t }
type error =
  | Inventory_unavailable of string
  | Removal_incomplete of { removed : int; detail : string }

let archive_to_string = function
  | Archive_not_needed -> "not_needed"
  | Archive_read -> "read"

let error_to_string = function
  | Inventory_unavailable detail -> "original request inventory unavailable: " ^ detail
  | Removal_incomplete {removed;detail} ->
    Printf.sprintf "original request body sweep stopped after %d removals; last effect may be unconfirmed: %s"
      removed detail

(* Successor intent carries no scope. Protect its digest in every scope while
   the parent is active or archived; an identical body may be shared. *)
let protect_record ~active marked record =
  let digest = Owner.Record.request_digest record in
  let digests = Digests.add digest marked.digests in
  let active_bodies = if active then
      Body_keys.add (Store.digest (Owner.Record.scope record),digest) marked.active_bodies
    else marked.active_bodies in
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
    | Successor_observed _ | Observer _ -> Ok digests)
    (Ok digests) (Progress.events (Owner.Record.progress record)) in
  Ok {digests;active_bodies}

let run_with ~before_remove ~store =
  (* Parser errors can include snippets of private request bodies or records.
     Startup reports the refusal without exposing those input bytes. *)
  let unavailable _detail = Inventory_unavailable "a record or body could not be safely validated" in
  let* marked = Store.fold_startup_tool_request_owners store
    ~init:{digests=Digests.empty;active_bodies=Body_keys.empty}
    ~f:(fun marked ~directory_name ~file_name json ->
      let* record = Owner.decode_published ~directory_name ~file_name json in
      protect_record ~active:true marked record) |> Result.map_error unavailable in
  let* bodies = Store.tool_request_body_inventory_all store
    |> Result.map_error unavailable in
  let present = List.fold_left (fun present (entry : Store.tool_request_body_entry) ->
    Body_keys.add (entry.scope_directory,entry.request_digest) present) Body_keys.empty bodies in
  let* () = if Body_keys.subset marked.active_bodies present then Ok ()
    else Error (Inventory_unavailable "an active original request body is missing") in
  (* Archived records only add protection, so they matter only for a live body
     the live records leave unprotected. The archive holds every settled record
     ever kept, so it is read only then. *)
  let unprotected = List.exists (fun (entry : Store.tool_request_body_entry) ->
    not (Digests.mem entry.request_digest marked.digests)) bodies in
  let* marked,archive = if not unprotected then Ok (marked,Archive_not_needed) else
    let* marked = Store.fold_archived_tool_request_owners store ~init:marked
      ~f:(fun marked ~directory_name ~file_name json ->
        let* record = Owner.decode_published ~directory_name ~file_name json in
        protect_record ~active:false marked record) |> Result.map_error unavailable in
    Ok (marked,Archive_read) in
  let rec remove removed = function
    | [] -> Ok {protected_digests=Digests.cardinal marked.digests;removed;archive}
    | (entry : Store.tool_request_body_entry) :: rest ->
      if Digests.mem entry.request_digest marked.digests then remove removed rest
      else begin
        before_remove entry;
        match Store.remove_inventoried_tool_request_body store entry with
        | Ok () -> remove (removed + 1) rest
        | Error detail -> Error (Removal_incomplete {removed;detail})
      end in
  remove 0 bodies

let run ~store = run_with ~before_remove:(fun _ -> ()) ~store

let run_at_startup ~base_path =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  match Unix.lstat runtime_root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    Ok {protected_digests=0;removed=0;archive=Archive_not_needed}
  | exception Unix.Unix_error (error, operation, _) ->
    Error (Inventory_unavailable (operation ^ ": " ^ Unix.error_message error))
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    run ~store:(Store.create ~root:(Filename.concat runtime_root "lane-addons"))
  | _ -> Error (Inventory_unavailable "workspace runtime root is not a directory")

module For_testing = struct
  let run = run_with
end
