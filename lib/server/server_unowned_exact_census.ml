module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Ids = Set.Make (String)
open Result.Syntax

type report =
  { declarations : int
  ; live_originals : int
  ; exact_records : int
  ; exact_record_bytes : int64
  ; unowned_exact_records : int
  ; unowned_exact_record_bytes : int64
  ; proofs : int
  ; proof_bytes : int64
  ; unowned_proofs : int
  ; unowned_proof_bytes : int64
  }

type error = Census_unavailable of string

let error_to_string (Census_unavailable detail) = "unowned Exact census unavailable: " ^ detail

(* Parser errors can carry snippets of private records, so a refusal names
   only the class of failure. *)
let refuse detail _ = Census_unavailable detail

let original_required (declaration : Lane_addon_config.declaration) =
  Server_workspace_memory_addon_validation.original_required declaration.package
  || Server_librarian_addon_validation.original_required declaration.package

type counted = { files : int; bytes : int64; unowned : int; unowned_bytes : int64 }

let empty = { files = 0; bytes = 0L; unowned = 0; unowned_bytes = 0L }

let add ~owned counted size =
  let counted = { counted with files = counted.files + 1; bytes = Int64.add counted.bytes size } in
  if owned then counted
  else
    { counted with
      unowned = counted.unowned + 1
    ; unowned_bytes = Int64.add counted.unowned_bytes size
    }

type listed = { file_name : string; path : string; size : int64 }

(* A declaration directory holds only <name>.json files. A staging file a
   write left is skipped; any other entry refuses the count. *)
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
             else Error (Census_unavailable "an Exact directory entry is not a JSON file"))
         (Ok [])
  | _ -> Error (Census_unavailable "an Exact directory is not a directory")

let read_json path =
  match Yojson.Safe.from_file path with
  | json -> Ok json
  | exception Yojson.Json_error _ -> Error (Census_unavailable "an execution link is not JSON")

type declaration_files =
  { declaration_id : string
  ; records : listed list
  ; links : (string * int64) list  (** request ID, link size *)
  }

let list_declaration ~root (declaration : Lane_addon_config.declaration) =
  let declaration_id = declaration.id in
  let* records = list_directory ~root (Store.exact_request_directory ~declaration_id) in
  let* links = list_directory ~root (Exact.proof_directory ~declaration_id) in
  let+ links =
    List.fold_left
      (fun acc (link : listed) ->
        let* acc = acc in
        let* json = read_json link.path in
        let+ request_id =
          Exact.proof_request_id ~declaration_id ~file_name:link.file_name json
          |> Result.map_error (refuse "an execution link names no request of its own")
        in
        (request_id, link.size) :: acc)
      (Ok []) links
  in
  { declaration_id; records; links }

let live_ids ~store =
  Store.fold_tool_request_owner_inventory_all store ~init:Ids.empty
    ~f:(fun ids ~directory_name ~file_name json ->
      let+ record = Owner.decode_published ~directory_name ~file_name json in
      Ids.add (Owner.Record.request_id record) ids)
  |> Result.map_error (refuse "a live original could not be read")

let count_declaration ~live (exact, proofs) files =
  let owned_names =
    Ids.map
      (fun request_id ->
        Filename.basename
          (Store.exact_request_path ~declaration_id:files.declaration_id ~request_id))
      live
  in
  ( List.fold_left
      (fun exact (record : listed) -> add ~owned:(Ids.mem record.file_name owned_names) exact record.size)
      exact files.records
  , List.fold_left
      (fun proofs (request_id, size) -> add ~owned:(Ids.mem request_id live) proofs size)
      proofs files.links )

let count ~store ~declarations =
  let root = Store.root store in
  let declarations = List.filter original_required declarations in
  (* Listed first: a record or link whose original is live by now was
     retained before it was written, so the read below sees that original. *)
  let* listed =
    List.fold_left
      (fun acc declaration ->
        let* acc = acc in
        let+ files = list_declaration ~root declaration in
        files :: acc)
      (Ok []) declarations
  in
  let+ live = live_ids ~store in
  let exact, proofs = List.fold_left (count_declaration ~live) (empty, empty) listed in
  { declarations = List.length declarations
  ; live_originals = Ids.cardinal live
  ; exact_records = exact.files
  ; exact_record_bytes = exact.bytes
  ; unowned_exact_records = exact.unowned
  ; unowned_exact_record_bytes = exact.unowned_bytes
  ; proofs = proofs.files
  ; proof_bytes = proofs.bytes
  ; unowned_proofs = proofs.unowned
  ; unowned_proof_bytes = proofs.unowned_bytes
  }

let run ~store ~declarations =
  try count ~store ~declarations with
  | Unix.Unix_error (error, operation, _) ->
    Error (Census_unavailable (operation ^ ": " ^ Unix.error_message error))
  | Sys_error _ -> Error (Census_unavailable "an Exact file could not be read")

let run_for_workspace config =
  let snapshot =
    Lane_addon_config.load ~directory:(Lane_addon_runtime.configuration_directory config)
  in
  if not snapshot.complete then
    Error (Census_unavailable "the Lane declarations could not all be read")
  else
    run
      ~store:(Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons"))
      ~declarations:snapshot.declarations
