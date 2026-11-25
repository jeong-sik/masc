let schema_version = 1

let ok ?(now = Time_compat.now ()) ?(instance_id = Build_identity.runtime_instance_id) data =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "instance_id", `String instance_id
    ; "generated_at_unix", `Float now
    ; "data", data
    ]
;;

type error_code =
  | Invalid_param
  | Unauthorized
  | Not_found
  | Sandbox_telemetry_missing
  | Conflict_cas
  | Workspace_mismatch
  | Validation_failed
  | Store_unavailable

let error_code_to_string = function
  | Invalid_param -> "invalid_param"
  | Unauthorized -> "unauthorized"
  | Not_found -> "not_found"
  | Sandbox_telemetry_missing -> "sandbox_telemetry_missing"
  | Conflict_cas -> "conflict_cas"
  | Workspace_mismatch -> "workspace_mismatch"
  | Validation_failed -> "validation_failed"
  | Store_unavailable -> "store_unavailable"
;;

let error_status : error_code -> Httpun.Status.t = function
  | Invalid_param -> `Bad_request
  | Unauthorized -> `Forbidden
  | Not_found | Sandbox_telemetry_missing -> `Not_found
  | Conflict_cas -> `Conflict
  | Workspace_mismatch -> `Conflict
  | Validation_failed -> `Code 422
  | Store_unavailable -> `Service_unavailable
;;

let error_json ?field ?(extra = []) ~code message =
  let field_member =
    match field with
    | Some f -> [ "field", `String f ]
    | None -> []
  in
  let error_obj =
    `Assoc
      ([ "code", `String (error_code_to_string code); "message", `String message ]
       @ field_member)
  in
  `Assoc (("error", error_obj) :: extra)
;;

let sha256_hex text = Auth.sha256_hash text

let announce_v2_dataset ~base_path ~dataset ?(extra = []) () =
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        ([ "type", `String "tui_v2_dataset_changed"
         ; "dataset", `String dataset
         ]
         @ extra
         @ [ "ts_unix", `Float (Time_compat.now ()) ]))
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Server.warn
      "tui_v2_dataset_changed (%s) broadcast skipped: %s"
      dataset
      (Printexc.to_string exn)
;;
