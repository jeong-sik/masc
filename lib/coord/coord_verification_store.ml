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

let verifications_dir base_path =
  active_verifications_dir base_path

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
       | other ->
           let got =
             match other with
             | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
             | None -> "field missing"
           in
           Error
             (Printf.sprintf
                "unknown or missing 'verdict' (expected one of: \
                 pass | fail | partial; %s)"
                got))
  | other ->
      Error
        (Printf.sprintf
           "verdict must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

let request_status_of_yojson = function
  | `Assoc fields ->
      (match List.assoc_opt "status" fields with
       | Some (`String "pending") -> Ok `Pending
       | Some (`String "assigned") ->
           (match List.assoc_opt "verifier" fields with
            | Some (`String agent) -> Ok (`Assigned agent)
            | other ->
                let got =
                  match other with
                  | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
                  | None -> "field missing"
                in
                Error
                  (Printf.sprintf
                     "assigned status requires 'verifier' string field \
                      (%s)"
                     got))
       | Some (`String "completed") ->
           (match verdict_of_yojson (`Assoc fields) with
            | Ok verdict -> Ok (`Completed verdict)
            | Error err -> Error err)
       | other ->
           let got =
             match other with
             | Some j -> Printf.sprintf "got %s" (Json_util.excerpt j)
             | None -> "field missing"
           in
           Error
             (Printf.sprintf
                "unknown 'status' (expected one of: pending | assigned \
                 | completed; %s)"
                got))
  | other ->
      Error
        (Printf.sprintf
           "request status must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

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
           let status_result =
             match List.assoc_opt "status" fields with
             | None -> Ok `Pending
             | Some json -> request_status_of_yojson json
           in
           (match status_result with
            | Ok status ->
                Ok { id; task_id; worker; verifier; created_at; status }
            | Error err ->
                Error
                  (Printf.sprintf
                     "verification request '%s' has invalid 'status' field: \
                      %s"
                     id err))
       | id_opt, task_opt, worker_opt ->
           let missing =
             List.filter_map
               (fun (name, opt) -> if Option.is_none opt then Some name else None)
               [ "id", id_opt; "task_id", task_opt; "worker", worker_opt ]
           in
           Error
             (Printf.sprintf
                "verification request missing required string field(s) \
                 [%s] (object had keys: [%s])"
                (String.concat ", " missing)
                (String.concat ", " (List.map fst fields))))
  | other ->
      Error
        (Printf.sprintf
           "verification request must be a JSON object, got %s: %s"
           (Json_util.kind_name other)
           (Json_util.excerpt other))

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
