(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories in multi-agent
    systems. Independent verification ensures Worker Agent ≠ Verifier Agent.

    Design:
    - File-based storage under .masc/verifications/
    - Criteria-based checking (schema, contains, custom)
    - Cross-agent enforcement (worker cannot verify own output)
    - Integration with existing task lifecycle
*)

open Result.Syntax

(** Verification criteria *)
type criterion =
  | Schema_match of Yojson.Safe.t   (** Output matches JSON schema *)
  | Contains of string              (** Output must contain string *)
  | Not_contains of string          (** Output must not contain string *)
  | Custom of string                (** Natural language criterion for verifier *)
[@@deriving show, eq]

let criterion_to_yojson = function
  | Schema_match schema ->
      `Assoc [("type", `String "schema_match"); ("schema", schema)]
  | Contains s ->
      `Assoc [("type", `String "contains"); ("value", `String s)]
  | Not_contains s ->
      `Assoc [("type", `String "not_contains"); ("value", `String s)]
  | Custom s ->
      `Assoc [("type", `String "custom"); ("description", `String s)]

let criterion_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "type" fields with
       | Some (`String "schema_match") ->
           (match List.assoc_opt "schema" fields with
            | Some schema -> Ok (Schema_match schema)
            | None -> Error "schema_match requires 'schema' field")
       | Some (`String "contains") ->
           let* value =
             match List.assoc_opt "value" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "contains requires 'value' string field"
           in
           Ok (Contains value)
       | Some (`String "not_contains") ->
           let* value =
             match List.assoc_opt "value" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "not_contains requires 'value' string field"
           in
           Ok (Not_contains value)
       | Some (`String "custom") ->
           let* description =
             match List.assoc_opt "description" fields with
             | Some (`String s) -> Ok s
             | _ -> Error "custom requires 'description' string field"
           in
           Ok (Custom description)
       | Some (`String t) -> Error (Printf.sprintf "unknown criterion type: %s" t)
       | _ -> Error "criterion requires 'type' field")
  | _ -> Error "criterion must be a JSON object"

(** Verification request *)
type verification_request = {
  id: string;
  task_id: string;
  output: Yojson.Safe.t;
  criteria: criterion list;
  worker: string;           (** Agent who produced the output *)
  created_at: float;
}

(** Serialization *)

let request_to_yojson req =
  `Assoc [
    ("id", `String req.id);
    ("task_id", `String req.task_id);
    ("output", req.output);
    ("criteria", `List (List.map criterion_to_yojson req.criteria));
    ("worker", `String req.worker);
    ("created_at", `Float req.created_at);
  ]

let request_of_yojson = function
  | `Assoc fields ->
      let* header =
        Workspace_verification_store.request_header_of_yojson (`Assoc fields)
      in
      let required_field key =
        match List.assoc_opt key fields with
        | Some value -> Ok value
        | None ->
          Error
            (Printf.sprintf
               "verification request missing required field %s (object had keys: [%s])"
               key
               (String.concat ", " (List.map fst fields)))
      in
      let required_criteria () =
        let* value = required_field "criteria" in
        match value with
        | `List values ->
          let rec parse index = function
            | [] -> Ok []
            | value :: rest ->
              let* criterion =
                criterion_of_yojson value
                |> Result.map_error (fun detail ->
                       Printf.sprintf "criteria[%d]: %s" index detail)
              in
              let* criteria = parse (index + 1) rest in
              Ok (criterion :: criteria)
          in
          (match parse 0 values with
           | Ok criteria -> Ok criteria
           | Error detail ->
             Error (Printf.sprintf "verification request criteria: %s" detail))
        | other ->
          Error
            (Printf.sprintf
               "verification request field criteria must be a JSON array, got %s"
               (Json_util.excerpt other))
      in
      let* output = required_field "output" in
      let* criteria = required_criteria () in
      Ok
        { id = header.id
        ; task_id = header.task_id
        ; output
        ; criteria
        ; worker = header.worker
        ; created_at = header.created_at
        }
  | other ->
      Error
        (Printf.sprintf
           "verification request must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

let generate_id () =
  Random_id.prefixed ~prefix:"vrf-" ~bytes:16

(** File-based storage *)

let verifications_dir = Workspace_verification_store.verifications_dir

let request_path base_path req_id =
  Workspace_verification_store.request_path base_path req_id

(* [list_requests] used to walk [verifications/*.json] on every dashboard
   refresh: one [Safe_ops.list_dir_safe] for the directory followed by
   [Safe_ops.read_json_eio] per file (the per-file [load_request] in the
   filter_map below).  Dashboard layers — [Dashboard_verification.proof_compose],
   [summary_json], [requests_json] — and verification HTTP routes all funnel
   into this scan.  PR #19015 collapsed two scans into one within the proof
   compose, but each cache miss still pays N+1 disk reads.

   This storage-level cache keeps the most-recent parsed list addressed by
   [(base_path, dir mtime)].  When the directory has not changed since the
   last scan, the cache returns the previously-parsed list — a single
   [Unix.stat] syscall — and skips the readdir + per-file open chain.

   Single-entry [Atomic.t] is sufficient because production deployments run
   a single [base_path] per MASC server instance.  Multi-tenant workloads
   would alternate cache misses but never serve stale data — the mtime guard
   detects directory churn from any source (file create/update/delete all
   bump [st_mtime]).  Write paths below ([save_request]) additionally
   invalidate the cache explicitly to close the sub-second mtime resolution
   race on fast filesystems. *)
type list_requests_cache_entry = {
  cache_base_path : string;
  dir_mtime : float;
  results : verification_request list;
}

let list_requests_cache : list_requests_cache_entry option Atomic.t =
  Atomic.make None

let invalidate_list_requests_cache () =
  Atomic.set list_requests_cache None

let dir_mtime_opt dir =
  try Some (Unix.stat dir).Unix.st_mtime with
  | Unix.Unix_error _ | Sys_error _ -> None

let save_request base_path req =
  try
    let dir = verifications_dir base_path in
    Fs_compat.mkdir_p dir;
    let json = request_to_yojson req in
    let path = request_path base_path req.id in
    let* () = Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) in
    invalidate_list_requests_cache ();
    Ok req.id
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf
           "save_request %s: %s"
           req.id
           (Printexc.to_string exn))

(* RFC-0221 §3.1: compensation for atomic submit. Remove a verification record
   when the status commit it was written for did not land, so the record store
   and [task_status] are never left disagreeing. A missing file is success
   (idempotent), so the caller can compensate without first checking existence. *)
let delete_request base_path req_id =
  try
    let path = request_path base_path req_id in
    if Sys.file_exists path then Sys.remove path;
    invalidate_list_requests_cache ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf "delete_request %s: %s" req_id (Printexc.to_string exn))

let load_request base_path req_id =
  let path = request_path base_path req_id in
  if Sys.file_exists path then
    try
      let json = Safe_ops.read_json_eio path in
      request_of_yojson json
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Error (Printf.sprintf "Failed to load verification %s: %s" req_id (Printexc.to_string exn))
  else
    Error (Printf.sprintf "Verification %s not found" req_id)

let list_requests_uncached base_path =
  let surface = "verification" in
  let observe_drop ~reason =
    Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
      ~labels:[("surface", surface); ("reason", reason)] ()
  in
  let report_drop ~reason ~path ~detail =
    Safe_ops.report_persistence_read_drop
      ~on_drop:(fun () -> observe_drop ~reason)
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = verifications_dir base_path in
  let dir_exists =
    try Sys.file_exists dir with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Keeper_fd_pressure.note_exception ~site:"verification.list_requests.exists" exn;
      report_drop
        ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error
        ~path:dir
        ~detail:(Printexc.to_string exn);
      false
  in
  if not dir_exists then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
      report_drop ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error ~path:dir ~detail;
      []
    | Ok files ->
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.filter_map (fun f ->
          let id = Filename.chop_suffix f ".json" in
          Safe_ops.result_to_option_logged
            ~on_drop:(fun () ->
              observe_drop ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error)
            ~surface
            ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
            ~path:(Filename.concat dir f)
            (load_request base_path id))

(* Public entry: check the mtime-keyed cache before the readdir + N+1 open
   chain.  A cache hit returns the previously-parsed list after a single
   [Unix.stat] syscall; cache miss falls through to [list_requests_uncached]
   and refreshes the entry.  See [list_requests_cache] above for the design. *)
let list_requests base_path =
  let dir = verifications_dir base_path in
  match dir_mtime_opt dir with
  | None ->
      (* Directory missing or stat failed — defer to the uncached path so
         the existing directory check and explicit error reporting run. *)
      list_requests_uncached base_path
  | Some mtime -> (
      match Atomic.get list_requests_cache with
      | Some entry
        when String.equal entry.cache_base_path base_path
             && Float.equal entry.dir_mtime mtime ->
          entry.results
      | _ ->
          let results = list_requests_uncached base_path in
          Atomic.set list_requests_cache
            (Some { cache_base_path = base_path; dir_mtime = mtime; results });
          results)

(** High-level API *)

let create_request ~base_path ~task_id ~output ~criteria ~worker ?request_id () =
  let id = match request_id with Some rid -> rid | None -> generate_id () in
  let req = {
    id;
    task_id;
    output;
    criteria;
    worker;
    created_at = Time_compat.now ();
  } in
  let* _req_id = save_request base_path req in
  Ok req
