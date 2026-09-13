type store = Ordinary | Source_bound
type snapshot =
  | Ordinary_snapshot of Keeper_memory_os_current.t
  | Source_snapshot of Keeper_memory_source_current.t
type observation = Missing | Unavailable of string | Available of snapshot
type keeper = { keeper_id : string; ordinary : observation; source_bound : observation }
type t =
  { observed_at : float
  ; keepers : keeper list
  ; input : Yojson.Safe.t
  ; identity : string
  ; sources : Yojson.Safe.t list
  ; gaps : Yojson.Safe.t list
  ; snapshots : Yojson.Safe.t list
  }

let ( let* ) = Result.bind
let store_name = function Ordinary -> "ordinary" | Source_bound -> "source_bound"
let snapshot_json = function
  | Ordinary_snapshot value -> Keeper_memory_os_current.to_json value
  | Source_snapshot value -> Keeper_memory_source_current.to_json value

let rec canonical = function
  | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, canonical value) fields
      |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List values -> `List (List.map canonical values)
  | value -> value

let hash value = Digestif.SHA256.(digest_string (Yojson.Safe.to_string (canonical value)) |> to_hex)
let observation_json = function
  | Missing -> `Assoc ["status", `String "missing"]
  | Unavailable detail -> `Assoc ["status", `String "unavailable"; "detail", `String detail]
  | Available snapshot -> `Assoc ["status", `String "available"; "snapshot", snapshot_json snapshot]

let keeper_json keeper = `Assoc
  [ "keeper_id", `String keeper.keeper_id
  ; "ordinary", observation_json keeper.ordinary
  ; "source_bound", observation_json keeper.source_bound ]

let read_snapshot path read wrap =
  try
    match Unix.stat path with
    | { Unix.st_kind = Unix.S_REG; _ } ->
      (try match read () with
       | Ok (Some snapshot) -> Available (wrap snapshot)
       | Ok None -> Unavailable (path ^ ": snapshot became unavailable during read")
       | Error detail -> Unavailable detail
       with
       | Unix.Unix_error (error, operation, failed_path) ->
         Unavailable (Printf.sprintf "%s: %s: %s" operation failed_path (Unix.error_message error))
       | Sys_error detail -> Unavailable detail)
    | _ -> Unavailable (path ^ ": snapshot is not a regular file")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Missing
  | Unix.Unix_error (error, operation, path) ->
    Unavailable (Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error))
  | Sys_error detail -> Unavailable detail

let discover ~keepers_dir =
  let failure error operation path =
    Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)
  in
  try
    match Unix.stat keepers_dir with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      (* Enumerate once, after observing a real directory. A vanished or
         unreadable directory is a failed inventory, never a fresh empty one. *)
      (try
         let files = Sys.readdir keepers_dir |> Array.to_list in
         let configured = List.filter_map (fun file ->
           match Filename.chop_suffix_opt ~suffix:".toml" file with
           | None -> None
           | Some basename ->
             Some (match Keeper_types_profile.load_keeper_toml (Filename.concat keepers_dir file) with
               | Ok (keeper_name, _) -> keeper_name
               | Error _ -> basename)) files in
         let ids = List.sort_uniq String.compare
           (configured
            @ List.filter_map Keeper_memory_os_current.keeper_id_of_filename files
            @ List.filter_map Keeper_memory_source_current.keeper_id_of_filename files) in
         if List.exists (fun id -> String.trim id = "") ids
         then Error "Keeper inventory contains a blank identity"
         else Ok ids
       with
       | Unix.Unix_error (error, operation, path) -> Error (failure error operation path)
       | Sys_error detail -> Error detail)
    | _ -> Error "Keeper memory directory is not a directory"
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | Unix.Unix_error (error, operation, path) -> Error (failure error operation path)
  | Sys_error detail -> Error detail

let read_keeper ~keepers_dir keeper_id =
  { keeper_id
  ; ordinary = read_snapshot
      (Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun () -> Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun snapshot -> Ordinary_snapshot snapshot)
  ; source_bound = read_snapshot
      (Keeper_memory_source_current.path_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun () -> Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
      (fun snapshot -> Source_snapshot snapshot)
  }

(* Preserve original fact positions and metadata evidence, using the same
   proposal contract as the standalone importer. IDs are inventory-local. *)
let project keepers =
  let sources = ref [] and gaps = ref [] and snapshots = ref [] in
  let source_count = ref 0 and snapshot_count = ref 0 in
  let add_source fields =
    incr source_count;
    sources := `Assoc (("source_id", `String ("s" ^ string_of_int !source_count)) :: fields) :: !sources
  in
  let add_store keeper_id store observation =
    let store = store_name store in
    match observation with
    | Missing | Unavailable _ ->
      gaps := `Assoc ["keeper_id", `String keeper_id; "store", `String store;
        "observation", observation_json observation] :: !gaps;
      Ok ()
    | Available snapshot ->
      let raw = snapshot_json snapshot in
      let* fields, facts, revision = match raw with
        | `Assoc fields ->
          (match List.assoc_opt "facts" fields, List.assoc_opt "revision" fields with
           | Some (`List facts), Some (`Int revision) when revision > 0 -> Ok (fields, facts, revision)
           | _ -> Error "Memory snapshot serialization has invalid facts or revision")
        | _ -> Error "Memory snapshot serialization is not an object"
      in
      incr snapshot_count;
      let sid = "snapshot" ^ string_of_int !snapshot_count in
      let digest = hash raw in
      snapshots := `Assoc ["snapshot_id", `String sid; "keeper_id", `String keeper_id;
        "store", `String store; "snapshot_sha256", `String digest;
        "metadata", `Assoc (List.filter (fun (key, _) -> key <> "facts") fields)] :: !snapshots;
      List.iteri (fun index fact -> add_source
        ["snapshot_id", `String sid; "keeper_id", `String keeper_id; "store", `String store;
         "revision", `Int revision; "snapshot_sha256", `String digest;
         "fact_index", `Int index; "fact", fact]) facts;
      (match List.assoc_opt "change" fields with
       | Some (`Assoc change) when List.exists (fun key -> match List.assoc_opt key change with
           | Some (`List (_ :: _)) -> true | _ -> false) ["added"; "removed"; "invalidated"] ->
         add_source ["snapshot_id", `String sid; "evidence_path", `List [`String "change"]]
       | _ -> ());
      (match List.assoc_opt "invalidations" fields with
       | Some (`List values) -> List.iteri (fun index _ -> add_source
           ["snapshot_id", `String sid; "evidence_path", `List [`String "invalidations"; `Int index]]) values
       | _ -> ());
      Ok ()
  in
  let rec loop = function
    | [] -> Ok (List.rev !sources, List.rev !gaps, List.rev !snapshots)
    | keeper :: rest ->
      let* () = add_store keeper.keeper_id Ordinary keeper.ordinary in
      let* () = add_store keeper.keeper_id Source_bound keeper.source_bound in
      loop rest
  in
  loop keepers

let collect ~base_path =
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* ids = discover ~keepers_dir in
  let keepers = List.map (read_keeper ~keepers_dir) ids in
  let* sources, gaps, snapshots = project keepers in
  let input = `Assoc ["sources", `List sources; "gaps", `List gaps; "snapshots", `List snapshots] in
  Ok { observed_at = Time_compat.now (); keepers; input; sources; gaps; snapshots;
       identity = hash (`List (List.map keeper_json keepers)) }

let fingerprint t = t.identity
let source_count t = List.length t.sources
let to_json t = t.input
let proposal_json t proposal = `Assoc
  ["status", `String "model_proposed"; "context_sha256", `String t.identity;
   "sources", `List t.sources; "gaps", `List t.gaps; "snapshots", `List t.snapshots;
   "proposal", proposal]

let http_json ~base_path =
  let captured = collect ~base_path in
  let observed_at = match captured with Ok t -> t.observed_at | Error _ -> Time_compat.now () in
  `Assoc (["schema", `String "workspace.memory.context.v1"; "generated_at", `Float observed_at;
    "source_validation", `String "stored_bindings_not_revalidated";
    "consistency", `String "individual_store_snapshots"] @ match captured with
    | Ok t -> ["discovery", `Assoc ["status", `String "available"];
               "keepers", `List (List.map keeper_json t.keepers)]
    | Error detail -> ["discovery", `Assoc ["status", `String "unavailable"; "detail", `String detail];
                      "keepers", `List []])
