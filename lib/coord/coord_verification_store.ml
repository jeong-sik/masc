type verdict =
  [ `Pass
  | `Fail of string
  | `Partial of float * string ]

type request_status =
  [ `Pending
  | `Assigned of string
  | `Completed of verdict ]

type request_header = {
  id : string;
  task_id : string;
  worker : string;
  verifier : string option;
  created_at : float;
  status : request_status;
}

let project_root_of_base_path base_path =
  if Filename.basename base_path = Common.masc_dirname then
    Filename.dirname base_path
  else
    base_path

let active_verifications_dir base_path =
  let base_path = project_root_of_base_path base_path in
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path) "verifications"

let legacy_verifications_dir base_path =
  Filename.concat (project_root_of_base_path base_path) "verifications"

let warned_legacy_dirs : (string, unit) Hashtbl.t = Hashtbl.create 8
let warned_legacy_dirs_mutex = Stdlib.Mutex.create ()

let dir_exists path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false

let warn_if_legacy_verifications_dir_present ~base_path ~active_dir =
  let legacy_dir = legacy_verifications_dir base_path in
  if dir_exists legacy_dir then (
    Stdlib.Mutex.lock warned_legacy_dirs_mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock warned_legacy_dirs_mutex)
      (fun () ->
        if not (Hashtbl.mem warned_legacy_dirs legacy_dir) then (
          Hashtbl.add warned_legacy_dirs legacy_dir ();
          Log.Task.warn
            "Ignoring legacy verification directory %s; active store is %s"
            legacy_dir active_dir)))

let verifications_dir base_path =
  let dir = active_verifications_dir base_path in
  warn_if_legacy_verifications_dir_present ~base_path ~active_dir:dir;
  dir

let request_path base_path req_id =
  Filename.concat (verifications_dir base_path) (req_id ^ ".json")

let verdict_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "verdict" fields with
       | Some (`String "pass") -> Ok `Pass
       | Some (`String "fail") ->
           let reason =
             match List.assoc_opt "reason" fields with
             | Some (`String s) -> s
             | _ -> "no reason given"
           in
           Ok (`Fail reason)
       | Some (`String "partial") ->
           let score =
             match List.assoc_opt "score" fields with
             | Some (`Float f) -> f
             | Some (`Int n) -> Float.of_int n
             | _ -> 0.0
           in
           let reason =
             match List.assoc_opt "reason" fields with
             | Some (`String s) -> s
             | _ -> "no reason given"
           in
           Ok (`Partial (score, reason))
       | _ -> Error "unknown or missing verdict")
  | _ -> Error "verdict must be a JSON object"

let request_status_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String "pending") -> Ok `Pending
       | Some (`String "assigned") ->
           (match List.assoc_opt "verifier" fields with
            | Some (`String agent) -> Ok (`Assigned agent)
            | _ -> Error "assigned requires 'verifier' field")
       | Some (`String "completed") ->
           (match verdict_of_yojson (`Assoc fields) with
            | Ok verdict -> Ok (`Completed verdict)
            | Error err -> Error err)
       | _ -> Error "unknown request status")
  | _ -> Error "request status must be a JSON object"

let request_header_of_yojson = function
  | `Assoc fields ->
      let get_string key =
        match List.assoc_opt key fields with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let get_float key =
        match List.assoc_opt key fields with
        | Some (`Float f) -> Some f
        | Some (`Int n) -> Some (Float.of_int n)
        | _ -> None
      in
      (match get_string "id", get_string "task_id", get_string "worker" with
       | Some id, Some task_id, Some worker ->
           let verifier =
             match List.assoc_opt "verifier" fields with
             | Some (`String s) -> Some s
             | _ -> None
           in
           let created_at =
             match get_float "created_at" with
             | Some f -> f
             | None -> Time_compat.now ()
           in
           let status =
             match List.assoc_opt "status" fields with
             | Some json -> (
                 match request_status_of_yojson json with
                 | Ok s -> s
                 | Error _ -> `Pending)
             | None -> `Pending
           in
           Ok { id; task_id; worker; verifier; created_at; status }
       | _ -> Error "verification request requires 'id', 'task_id', 'worker' fields")
  | _ -> Error "verification request must be a JSON object"

let load_request_header base_path req_id =
  let path = request_path base_path req_id in
  if Sys.file_exists path then
    try
      let json = Safe_ops.read_json_eio path in
      request_header_of_yojson json
    with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Error
             (Printf.sprintf "Failed to load verification %s: %s" req_id
                (Printexc.to_string exn))
  else
    Error (Printf.sprintf "Verification %s not found" req_id)

let list_request_headers base_path =
  let surface = "verification" in
  let report_drop ~reason ~path ~detail =
    Safe_ops.report_persistence_read_drop
      ~on_drop:ignore
      ~surface
      ~reason
      ~path
      ~detail
  in
  let dir = verifications_dir base_path in
  if not (Sys.file_exists dir) then
    []
  else
    match Safe_ops.list_dir_safe dir with
    | Error detail ->
        report_drop
          ~reason:Safe_ops.persistence_read_drop_reason_list_dir_error
          ~path:dir ~detail;
        []
    | Ok files ->
        files
        |> List.filter (fun f -> Filename.check_suffix f ".json")
        |> List.filter_map (fun f ->
               let id = Filename.chop_suffix f ".json" in
               Safe_ops.result_to_option_logged
                 ~on_drop:(fun () -> ())
                 ~surface
                 ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
                 ~path:(Filename.concat dir f)
                 (load_request_header base_path id))
