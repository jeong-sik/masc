(** Verification - Cross-agent task output verification for MASC

    Based on MAST taxonomy (Cemri et al., 2025, arXiv:2503.13657).
    Task verification is one of the three failure categories in multi-agent
    systems. Independent verification ensures Worker Agent ≠ Verifier Agent.

    Design:
    - File-based storage under .masc/verifications/
    - Exact operator-authored completion criteria
    - Cross-agent enforcement (worker cannot verify own output)
    - Integration with existing task lifecycle
*)

open Result.Syntax

type criterion = string
[@@deriving eq]

let criterion_to_yojson criterion = `String criterion

let criterion_of_yojson = function
  | `String criterion when not (String.equal (String.trim criterion) "") ->
    Ok criterion
  | `String _ -> Error "criterion must be a non-empty string"
  | _ -> Error "criterion must be a string"

(** A stored file the current schema cannot read.

    Kept as a value rather than collapsed into a failure. A request that cannot
    be parsed says nothing about the requests beside it, so it must not decide
    their fate: [list_requests] returns these alongside the ones it did read,
    and the caller reports both. Nothing here is shaped to accept a superseded
    schema — an unreadable file stays unreadable, it just stops being fatal. *)
type unreadable_request = {
  unreadable_path: string;
  unreadable_detail: string;
}

(** Verification request *)
type verification_request = {
  id: string;
  task_id: string;
  output: Yojson.Safe.t;
  criteria: criterion list;
  worker: string;           (** Agent who produced the output *)
  created_at: float;
}

(** What one pass over the request directory found.

    Both fields are reported. Returning only [readable] would drop the rest
    silently; returning an error for the whole scan lets one file decide for
    every other. The directory being unenumerable is still an error, because
    then neither list is known. *)
type request_scan = {
  readable: verification_request list;
  unreadable: unreadable_request list;
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

type verification_directory =
  | Missing_directory
  | Present_directory

let verification_directory dir =
  try
    let (_ : Unix.stats) = Unix.stat dir in
    Ok Present_directory
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Missing_directory
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Keeper_fd_pressure.note_exception ~site:"verification.list_requests.stat" exn;
    Error
      (Printf.sprintf
         "verification request directory unavailable at %s: %s"
         dir
         (Printexc.to_string exn))

let save_request base_path req =
  try
    let json = request_to_yojson req in
    let* _validated = request_of_yojson json in
    let dir = verifications_dir base_path in
    Fs_compat.mkdir_p dir;
    let path = request_path base_path req.id in
    let* () = Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) in
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

let unreadable_to_yojson { unreadable_path; unreadable_detail } =
  `Assoc
    [ ("path", `String unreadable_path);
      ("detail", `String unreadable_detail);
    ]

let list_requests_uncached base_path =
  let surface = "verification" in
  let observe_drop ~reason =
    Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
      ~labels:[("surface", surface); ("reason", reason)] ()
  in
  let report_drop ~reason ~path ~detail =
    let reason_wire = Read_drop_reason.to_wire reason in
    Safe_ops.report_persistence_read_drop
      ~on_drop:(fun () -> observe_drop ~reason:reason_wire)
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = verifications_dir base_path in
  match Safe_ops.list_dir_safe dir with
  | Error detail ->
    report_drop ~reason:Read_drop_reason.List_dir_error ~path:dir ~detail;
    Error (Printf.sprintf "verification request directory unreadable: %s" detail)
  | Ok files ->
    let files = List.filter (fun f -> Filename.check_suffix f ".json") files in
    let rec load readable unreadable = function
      | [] -> Ok { readable = List.rev readable; unreadable = List.rev unreadable }
      | file :: rest ->
        let id = Filename.chop_suffix file ".json" in
        (match load_request base_path id with
         | Ok request -> load (request :: readable) unreadable rest
         | Error detail ->
           let path = Filename.concat dir file in
           report_drop
             ~reason:Read_drop_reason.Entry_load_error
             ~path
             ~detail;
           load
             readable
             ({ unreadable_path = path; unreadable_detail = detail } :: unreadable)
             rest)
    in
    load [] [] files

let empty_scan = { readable = []; unreadable = [] }

(* Public entry: read the current directory and every current-schema request.
   Content identity is not inferred from filesystem timestamps. *)
let list_requests base_path =
  let dir = verifications_dir base_path in
  match verification_directory dir with
  | Error detail -> Error detail
  | Ok Missing_directory -> Ok empty_scan
  | Ok Present_directory -> list_requests_uncached base_path

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
