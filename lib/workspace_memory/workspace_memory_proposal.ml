type claim = { claim : string; source_ids : string list }
type conflict = { description : string; source_ids : string list }
type exclusion = { source_id : string; reason : string }
type t = { raw : Yojson.Safe.t; claims : claim list;
           conflicts : conflict list; exclusions : exclusion list }
type error = Invalid of string | Unavailable of string
type binding = Fact of string * int | Change of string | Invalidation of string * int
let ( let* ) = Result.bind
let to_json t = t.raw
let claims t = t.claims
let conflicts t = t.conflicts
let exclusions t = t.exclusions
let optional_field k = function
  | `Assoc xs -> Ok (List.assoc_opt k xs)
  | _ -> Error ("Expected object while reading " ^ k)
let field k json =
  let* value = optional_field k json in
  match value with Some value -> Ok value | None -> Error ("Missing field: " ^ k)
let read_field k decode json = let* value = field k json in decode value
let text = function `String s when String.trim s <> "" -> Ok s | _ -> Error "Expected nonblank string"
let array = function `List xs -> Ok xs | _ -> Error "Expected array"
let rec traverse f = function
  | [] -> Ok []
  | x :: xs -> let* y = f x in let* ys = traverse f xs in Ok (y :: ys)
let unique xs = List.length xs = List.length (List.sort_uniq String.compare xs)
let refs json =
  let* xs = array json in let* xs = traverse text xs in
  if xs <> [] && unique xs then Ok xs else Error "Source references must be nonempty and unique"
let exact names = function
  | `Assoc xs when List.sort String.compare (List.map fst xs) = List.sort String.compare names -> Ok ()
  | _ -> Error "Unexpected or missing object fields"
let rec canonical = function
  | `Assoc xs ->
      if not (unique (List.map fst xs)) then Error "Duplicate JSON object keys"
      else let* xs = traverse (fun (k,v) -> let* v = canonical v in Ok (k,v)) xs in
        Ok (`Assoc (List.sort (fun (a,_) (b,_) -> String.compare a b) xs))
  | `List xs -> let* xs = traverse canonical xs in Ok (`List xs)
  | (`String _ | `Int _ | `Intlit _ | `Bool _ | `Null) as x -> Ok x
  | `Float f as x when Float.is_finite f -> Ok x
  | _ -> Error "Unsupported JSON value"
let hash s = Digestif.SHA256.(digest_string s |> to_hex)
let valid_id s = String.length s = 64 && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) s
let id t = hash (Yojson.Safe.to_string t.raw)
let decode raw =
  let* raw = canonical raw in
  let* () = exact ["status"; "context_sha256"; "sources"; "gaps"; "snapshots"; "proposal"] raw in
  let* status = field "status" raw in
  let* () = match status with `String "model_proposed" -> Ok () | _ -> Error "Only model_proposed submissions are supported" in
  let* context_hash = read_field "context_sha256" text raw in
  let* () = if valid_id context_hash then Ok () else Error "Invalid context SHA-256" in
  let* sources = read_field "sources" array raw in
  let* snapshots = read_field "snapshots" array raw in
  let* gaps = read_field "gaps" array raw in
  let* _ = traverse (fun j ->
    let* _ = read_field "keeper_id" text j in
    let* store = field "store" j in
    let* () = match store with `String ("ordinary" | "source_bound") -> Ok () | _ -> Error "Unknown gap store" in
    let* observation = field "observation" j in
    let* status = field "status" observation in
    match status with
    | `String "missing" -> Ok ()
    | `String "unavailable" ->
      let* detail = field "detail" observation in
      (match detail with `String _ -> Ok () | _ -> Error "Unavailable gap must include a detail string")
    | _ -> Error "Gap must record missing or unavailable storage") gaps in
  let* snapshot_entries = traverse (fun j ->
    let* sid = read_field "snapshot_id" text j in
    let* owner = read_field "keeper_id" text j in
    let* store = field "store" j in
    let* () = match store with `String ("ordinary" | "source_bound") -> Ok () | _ -> Error "Unknown memory store" in
    let* digest = read_field "snapshot_sha256" text j in
    let* () = if valid_id digest then Ok () else Error "Invalid snapshot SHA-256" in
    let* metadata = field "metadata" j in
    let* () = match metadata with `Assoc _ -> Ok () | _ -> Error "Snapshot metadata must be an object" in
    Ok (sid, (owner, store, digest, metadata))) snapshots in
  let* () = if unique (List.map fst snapshot_entries) then Ok () else Error "Duplicate snapshot identity" in
  let* source_bindings = traverse (fun j ->
    let* sid = read_field "source_id" text j in
    let* snapshot = read_field "snapshot_id" text j in
    let* owner, store, digest, metadata = match List.assoc_opt snapshot snapshot_entries with
      | None -> Error "Unknown source snapshot" | Some entry -> Ok entry in
    let* fact = optional_field "fact" j in
    let* evidence_path = optional_field "evidence_path" j in
    let* binding = match fact, evidence_path with
      | Some (`Assoc _ as fact), None ->
        let* _ = read_field "claim" text fact in
        let* fact_owner = read_field "keeper_id" text j in
        let* fact_store = field "store" j in
        let* fact_digest = read_field "snapshot_sha256" text j in
        let* () = if fact_owner = owner && fact_store = store && fact_digest = digest
          then Ok () else Error "Source attribution differs from snapshot" in
        let* revision = field "revision" j in
        let* index = field "fact_index" j in
        let* snapshot_revision = field "revision" metadata in
        (match revision, index with
         | `Int revision, `Int index when revision > 0 && index >= 0
             && snapshot_revision = `Int revision -> Ok (Fact (snapshot, index))
         | _ -> Error "Invalid source revision or fact index")
      | None, Some (`List [`String "change"]) ->
        let* change = field "change" metadata in
        (match change with
         | `Assoc _ -> Ok (Change snapshot) | _ -> Error "Missing change evidence")
      | None, Some (`List [`String "invalidations"; `Int index]) ->
        let* invalidations = read_field "invalidations" array metadata in
        if index >= 0 && index < List.length invalidations then Ok (Invalidation (snapshot, index))
        else Error "Invalid invalidation evidence reference"
      | _ -> Error "Source must contain a fact or known metadata evidence path; absent alternatives must be omitted" in
    Ok (sid, binding)) sources in
  let source_ids = List.map fst source_bindings in
  let bindings = List.map snd source_bindings in
  let* () = if List.length bindings = List.length (List.sort_uniq Stdlib.compare bindings)
    then Ok () else Error "Duplicate source evidence binding" in
  let* () = if unique source_ids then Ok () else Error "Duplicate source identity" in
  let* proposal = field "proposal" raw in
  let* () = exact ["shared_claims"; "conflicts"; "excluded"] proposal in
  let* claim_rows = read_field "shared_claims" array proposal in
  let* claims = traverse (fun j ->
    let* () = exact ["claim"; "source_ids"] j in
    let* claim = read_field "claim" text j in let* source_ids = read_field "source_ids" refs j in
    Ok ({ claim; source_ids } : claim)) claim_rows in
  let* conflict_rows = read_field "conflicts" array proposal in
  let* conflicts = traverse (fun j ->
    let* () = exact ["description"; "source_ids"] j in
    let* description = read_field "description" text j in let* source_ids = read_field "source_ids" refs j in
    Ok ({ description; source_ids } : conflict)) conflict_rows in
  let* exclusion_rows = read_field "excluded" array proposal in
  let* exclusions = traverse (fun j ->
    let* () = exact ["source_id"; "reason"] j in
    let* source_id = read_field "source_id" text j in let* reason = read_field "reason" text j in
    Ok { source_id; reason }) exclusion_rows in
  let used = List.concat_map (fun (x:claim) -> x.source_ids) claims @ List.concat_map (fun (x:conflict) -> x.source_ids) conflicts in
  let excluded = List.map (fun x -> x.source_id) exclusions in
  if not (unique excluded) || List.exists (fun x -> List.mem x used) excluded then Error "Source both used and excluded or excluded twice"
  else if List.sort_uniq String.compare (used @ excluded) <> List.sort String.compare source_ids then Error "Source coverage mismatch: unknown or missing references"
  else Ok { raw; claims; conflicts; exclusions }

let directory ~base_path = Filename.concat (Filename.concat base_path Common.masc_dirname) "workspace-memory/proposals"
let file ~base_path id = Filename.concat (directory ~base_path) (id ^ ".json")
let io f = try f () with
  | Unix.Unix_error (e,fn,arg) -> Error (Unavailable (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message e)))
  | Sys_error detail -> Error (Unavailable detail)
  | Eio.Io _ as exn -> Error (Unavailable (Printexc.to_string exn))
let read ~base_path ~id:expected =
  if not (valid_id expected) then Error (Invalid "Invalid proposal id") else io (fun () ->
    let path = file ~base_path expected in
    let kind = try Some (Unix.lstat path).Unix.st_kind with Unix.Unix_error (Unix.ENOENT,_,_) -> None in
    match kind with
    | None -> Ok None
    | Some Unix.S_REG ->
      let bytes = Fs_compat.load_file path in
      let decoded = try decode (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail in
      (match decoded with
       | Error detail -> Error (Unavailable (path ^ ": " ^ detail))
       | Ok t when id t = expected -> Ok (Some t)
       | Ok _ -> Error (Unavailable (path ^ ": content hash mismatch")))
    | Some _ -> Error (Unavailable (path ^ ": not a regular file")))
let submit ~base_path json =
  let* t = Result.map_error (fun detail -> Invalid detail) (decode json) in
  let proposal_id = id t in
  let* existing = read ~base_path ~id:proposal_id in
  match existing with Some t -> Ok (proposal_id,t) | None -> io (fun () ->
    Fs_compat.mkdir_p (directory ~base_path);
    let* () = Fs_compat.save_file_atomic_strict_staged (file ~base_path proposal_id) (Yojson.Safe.to_string t.raw)
      |> Result.map_error (fun e -> Unavailable (Fs_compat.atomic_replace_failure_to_string e)) in
    let* saved = read ~base_path ~id:proposal_id in
    match saved with Some t -> Ok (proposal_id,t) | None -> Error (Unavailable "Proposal disappeared after persistence"))
let list ~base_path = io (fun () ->
  let dir = directory ~base_path in
  let kind = try Some (Unix.lstat dir).Unix.st_kind with Unix.Unix_error (Unix.ENOENT,_,_) -> None in
  match kind with
  | None -> Ok []
  | Some Unix.S_DIR ->
    let names = Fs_compat.read_dir dir |> List.filter (fun name -> Filename.check_suffix name ".json") |> List.sort String.compare in
    traverse (fun name ->
      let proposal_id = Filename.remove_extension name in
      let* t = read ~base_path ~id:proposal_id |> Result.map_error (function Invalid s -> Unavailable s | e -> e) in
      match t with Some t -> Ok (proposal_id,t) | None -> Error (Unavailable (name ^ ": disappeared during listing"))) names
  | Some _ -> Error (Unavailable (dir ^ ": not a directory")))
