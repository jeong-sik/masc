module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Ids = Set.Make (String)
open Result.Syntax

type report =
  { declarations : int
  ; live_originals : int
  ; kept_exact_records : int
  ; kept_proofs : int
  ; removed_proofs : int
  ; removed_proof_bytes : int64
  ; removed_exact_records : int
  ; removed_exact_record_bytes : int64
  }

type error =
  | Sweep_refused of string
  | Removal_stopped of
      { removed_proofs : int
      ; removed_exact_records : int
      ; detail : string
      }

let error_to_string = function
  | Sweep_refused detail -> "unowned Exact sweep deleted nothing: " ^ detail
  | Removal_stopped { removed_proofs; removed_exact_records; detail } ->
    Printf.sprintf
      "unowned Exact sweep stopped after deleting %d execution links and %d Exact records: %s"
      removed_proofs removed_exact_records detail

(* Parser errors can carry snippets of private records, so a refusal names
   only the class of failure. *)
let refuse detail _ = Sweep_refused detail

let guarded f =
  try f () with
  | Unix.Unix_error (error, operation, _) ->
    Error (Sweep_refused (operation ^ ": " ^ Unix.error_message error))
  | Sys_error _ -> Error (Sweep_refused "an Exact file could not be read")

let original_required (declaration : Lane_addon_config.declaration) =
  Server_workspace_memory_addon_validation.original_required declaration.package
  || Server_librarian_addon_validation.original_required declaration.package

type listed = { file_name : string; path : string; size : int64 }

(* A declaration directory holds only <name>.json files. A staging file a
   write left is skipped; any other entry refuses the sweep. *)
let list_directory ~root directory =
  let path = Filename.concat root directory in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir path
    |> Array.to_list
    |> List.sort String.compare
    |> List.fold_left
         (fun acc file_name ->
           let* acc = acc in
           if Fs_compat.is_atomic_orphan_name file_name then Ok acc
           else
             let file = Filename.concat path file_name in
             let stat = Unix.lstat file in
             if stat.Unix.st_kind = Unix.S_REG && Filename.check_suffix file_name ".json" then
               Ok ({ file_name; path = file; size = Int64.of_int stat.Unix.st_size } :: acc)
             else Error (Sweep_refused "an Exact directory entry is not a JSON file"))
         (Ok [])
  | _ -> Error (Sweep_refused "an Exact directory is not a directory")

let read_json path =
  match Yojson.Safe.from_file path with
  | json -> Ok json
  | exception Yojson.Json_error _ -> Error (Sweep_refused "an execution link is not JSON")

type link = { request_id : string; file : listed }

type declaration_files =
  { declaration_id : string
  ; records : listed list
  ; links : link list
  }

let list_declaration ~root (declaration : Lane_addon_config.declaration) =
  let declaration_id = declaration.id in
  let* records = list_directory ~root (Store.exact_request_directory ~declaration_id) in
  let* links = list_directory ~root (Exact.proof_directory ~declaration_id) in
  let+ links =
    List.fold_left
      (fun acc (file : listed) ->
        let* acc = acc in
        let* json = read_json file.path in
        let+ request_id =
          Exact.proof_request_id ~declaration_id ~file_name:file.file_name json
          |> Result.map_error (refuse "an execution link names no request of its own")
        in
        { request_id; file } :: acc)
      (Ok []) links
  in
  { declaration_id; records; links }

let list_declarations ~root declarations =
  List.fold_left
    (fun acc declaration ->
      let* acc = acc in
      let+ files = list_declaration ~root declaration in
      files :: acc)
    (Ok []) declarations

let live_ids ~store =
  Store.fold_tool_request_owner_inventory_all store ~init:Ids.empty
    ~f:(fun ids ~directory_name ~file_name json ->
      let+ record = Owner.decode_published ~directory_name ~file_name json in
      Ids.add (Owner.Record.request_id record) ids)
  |> Result.map_error (refuse "a live original could not be read")

type plan =
  { kept_records : int
  ; kept_links : int
  ; records : listed list
  ; links : listed list
  }

let plan_declaration ~live plan files =
  let owned_names =
    Ids.map
      (fun request_id ->
        Filename.basename
          (Store.exact_request_path ~declaration_id:files.declaration_id ~request_id))
      live
  in
  let plan =
    List.fold_left
      (fun plan (record : listed) ->
        if Ids.mem record.file_name owned_names then
          { plan with kept_records = plan.kept_records + 1 }
        else { plan with records = record :: plan.records })
      plan files.records
  in
  List.fold_left
    (fun plan link ->
      if Ids.mem link.request_id live then { plan with kept_links = plan.kept_links + 1 }
      else { plan with links = link.file :: plan.links })
    plan files.links

(* Deletes in order and stops at the first failure with how many it deleted. *)
let remove doomed =
  List.fold_left
    (fun acc { path; size; file_name = _ } ->
      let* count, bytes = acc in
      match Unix.unlink path with
      | () -> Ok (count + 1, Int64.add bytes size)
      | exception Unix.Unix_error (error, _, _) -> Error (count, Unix.error_message error))
    (Ok (0, 0L)) doomed

(* Inside the barrier: no settle moves an original between the read and the
   deletions. *)
let sweep ~store ~declarations listed =
  let* live = guarded (fun () -> live_ids ~store) in
  let plan =
    List.fold_left (plan_declaration ~live)
      { kept_records = 0; kept_links = 0; records = []; links = [] }
      listed
  in
  let* removed_proofs, removed_proof_bytes =
    remove plan.links
    |> Result.map_error (fun (removed_proofs, detail) ->
      Removal_stopped { removed_proofs; removed_exact_records = 0; detail })
  in
  let+ removed_exact_records, removed_exact_record_bytes =
    remove plan.records
    |> Result.map_error (fun (removed_exact_records, detail) ->
      Removal_stopped { removed_proofs; removed_exact_records; detail })
  in
  { declarations
  ; live_originals = Ids.cardinal live
  ; kept_exact_records = plan.kept_records
  ; kept_proofs = plan.kept_links
  ; removed_proofs
  ; removed_proof_bytes
  ; removed_exact_records
  ; removed_exact_record_bytes
  }

let run ~store ~declarations =
  let declarations = List.filter original_required declarations in
  (* Listed first: a record or link whose original is live by now was
     retained before it was written, so the read below sees that original. *)
  let* listed = guarded (fun () -> list_declarations ~root:(Store.root store) declarations) in
  match
    Store.with_tool_request_settlement_barrier store (fun () ->
      sweep ~store ~declarations:(List.length declarations) listed)
  with
  | Ok result -> result
  | Error detail -> Error (Sweep_refused ("under the settlement barrier: " ^ detail))

let run_for_workspace config =
  let snapshot =
    Lane_addon_config.load ~directory:(Lane_addon_runtime.configuration_directory config)
  in
  if not snapshot.complete then
    Error (Sweep_refused "the Lane declarations could not all be read")
  else
    run
      ~store:(Store.of_config config)
      ~declarations:snapshot.declarations
