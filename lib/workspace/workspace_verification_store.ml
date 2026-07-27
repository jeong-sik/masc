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

type evidence_read_failure =
  | Evidence_missing
  | Evidence_not_regular_file
  | Evidence_outside_worker_playground
  | Evidence_read_error of string

type submitted_evidence_item =
  | Evidence_note of string
  | Evidence_artifact of
      { reference : string
      ; content : string
      ; bytes : int
      ; truncated : bool
      }
  | Evidence_artifact_unreadable of
      { reference : string
      ; reason : evidence_read_failure
      }

type submitted_evidence_access =
  | Evidence_available of
      { request : request_header
      ; items : submitted_evidence_item list
      }
  | Evidence_metadata_only of
      { request : request_header
      ; viewer : string
      }
  | Evidence_unavailable of
      { request_id : string
      ; reason : string
      }

let evidence_read_failure_to_string = function
  | Evidence_missing -> "missing"
  | Evidence_not_regular_file -> "not_regular_file"
  | Evidence_outside_worker_playground -> "outside_worker_playground"
  | Evidence_read_error detail -> "read_error:" ^ detail

let project_root_of_base_path base_path =
  if Filename.basename base_path = Common.masc_dirname then
    Filename.dirname base_path
  else
    base_path

let active_verifications_dir base_path =
  let base_path = project_root_of_base_path base_path in
  Filename.concat (Workspace_utils.masc_dir_from_base_path ~base_path) "verifications"

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

let submitted_evidence_of_request_json = function
  | `Assoc fields ->
    (match List.assoc_opt "output" fields with
     | Some (`Assoc output_fields) ->
       (match List.assoc_opt "submitted_evidence" output_fields with
        | Some (`List values) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | `String value :: rest -> collect (value :: acc) rest
            | value :: _ ->
              Error
                (Printf.sprintf
                   "submitted_evidence must contain only strings, got %s"
                   (Json_util.excerpt value))
          in
          collect [] values
        | Some other ->
          Error
            (Printf.sprintf
               "submitted_evidence must be a list, got %s"
               (Json_util.excerpt other))
        | None -> Error "verification request output has no submitted_evidence")
     | Some other ->
       Error
         (Printf.sprintf
            "verification request output must be an object, got %s"
            (Json_util.excerpt other))
     | None -> Error "verification request has no output")
  | other ->
    Error
      (Printf.sprintf
         "verification request must be an object, got %s"
         (Json_util.excerpt other))

let load_request_for_evidence base_path req_id =
  let path = request_path base_path req_id in
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "Verification %s not found" req_id)
  else
    try
      let json = Safe_ops.read_json_eio path in
      match request_header_of_yojson json with
      | Error detail -> Error detail
      | Ok request ->
        (match submitted_evidence_of_request_json json with
         | Error detail -> Error detail
         | Ok evidence -> Ok (request, evidence))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error
        (Printf.sprintf
           "Failed to load verification %s evidence: %s"
           req_id
           (Printexc.to_string exn))

let verification_evidence_max_bytes = 20_000

let read_regular_file_prefix path stat =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let requested = min verification_evidence_max_bytes stat.Unix.st_size in
         let raw = really_input_string ic requested in
         let content = String_util.utf8_prefix ~max_bytes:requested raw in
         Ok
           ( content
           , stat.Unix.st_size
           , stat.Unix.st_size > String.length content ))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Evidence_read_error (Printexc.to_string exn))

let inspect_artifact_reference ~base_path ~worker reference =
  let canonical_base =
    try Ok (Unix.realpath (project_root_of_base_path base_path)) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Evidence_missing
    | exn -> Error (Evidence_read_error (Printexc.to_string exn))
  in
  let canonical_target =
    try Ok (Unix.realpath reference) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Evidence_missing
    | exn -> Error (Evidence_read_error (Printexc.to_string exn))
  in
  match canonical_base, canonical_target with
  | Error reason, _ | _, Error reason ->
    Evidence_artifact_unreadable { reference; reason }
  | Ok canonical_base, Ok canonical_target ->
    (match
       Playground_paths.parse_playground_file_path
         ~base_path:canonical_base
         ~abs_path:canonical_target
     with
     | Some parsed
       when String.equal
              parsed.Playground_paths.keeper_name
              (Playground_paths.sanitize_keeper_name worker) ->
       (try
          let stat = Unix.stat canonical_target in
          if stat.Unix.st_kind <> Unix.S_REG then
            Evidence_artifact_unreadable
              { reference; reason = Evidence_not_regular_file }
          else
            (match read_regular_file_prefix canonical_target stat with
             | Error reason ->
               Evidence_artifact_unreadable { reference; reason }
             | Ok (content, bytes, truncated) ->
               Evidence_artifact { reference; content; bytes; truncated })
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Evidence_artifact_unreadable
            { reference
            ; reason = Evidence_read_error (Printexc.to_string exn)
            })
     | Some _ | None ->
       Evidence_artifact_unreadable
         { reference; reason = Evidence_outside_worker_playground })

let inspect_submitted_evidence ~base_path ~request_id ~viewer =
  match load_request_for_evidence base_path request_id with
  | Error reason -> Evidence_unavailable { request_id; reason }
  | Ok (request, evidence_refs) ->
    (match request.status with
     | `Completed _ ->
       Evidence_unavailable
         { request_id
         ; reason = "verification request is already completed"
         }
     | `Pending | `Assigned _ ->
       (match request.verifier with
        | Some assigned_verifier when String.equal assigned_verifier viewer ->
          let items =
            List.map
              (fun reference ->
                 if Filename.is_relative reference then
                   Evidence_note reference
                 else
                   inspect_artifact_reference
                     ~base_path
                     ~worker:request.worker
                     reference)
              evidence_refs
          in
          Evidence_available { request; items }
        | None | Some _ -> Evidence_metadata_only { request; viewer }))

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
