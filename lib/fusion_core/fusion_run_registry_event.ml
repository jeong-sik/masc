(* JSONL event type for fusion run registry persistence (RFC-0266 §7 Phase D).
   Each [register_running] / [mark_completed] appends one line so run history
   survives server restart. The event type is intentionally minimal and stable;
   adding new fields is safe because replay ignores unknown JSON keys. *)

type t =
  | Register of
      { run_id : string
      ; keeper : string
      ; preset : string
      ; started_at : float
      }
  | Complete of
      { run_id : string
      ; ok : bool
      ; failure : string option
      ; failure_code : string option
      }

let to_yojson = function
  | Register { run_id; keeper; preset; started_at } ->
    `Assoc
      [ ("event", `String "register")
      ; ("run_id", `String run_id)
      ; ("keeper", `String keeper)
      ; ("preset", `String preset)
      ; ("started_at", `Float started_at)
      ]
  | Complete { run_id; ok; failure; failure_code } ->
    `Assoc
      (List.filter_map
         (fun (k, v) -> Option.map (fun value -> (k, value)) v)
         [ "event", Some (`String "complete")
         ; "run_id", Some (`String run_id)
         ; "ok", Some (`Bool ok)
         ; "failure", Option.map (fun s -> `String s) failure
         ; "failure_code", Option.map (fun s -> `String s) failure_code
         ])
;;

let object_fields = function
  | `Assoc fields -> Ok fields
  | json -> Error (Printf.sprintf "expected object, got %s" (Yojson.Safe.to_string json))
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some json -> Ok json
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let string_field name fields =
  match field name fields with
  | Error _ as err -> err
  | Ok (`String value) -> Ok value
  | Ok json ->
    Error (Printf.sprintf "field %s expected string, got %s" name (Yojson.Safe.to_string json))
;;

let float_field name fields =
  match field name fields with
  | Error _ as err -> err
  | Ok (`Float value) -> Ok value
  | Ok (`Int value) -> Ok (float_of_int value)
  | Ok json ->
    Error (Printf.sprintf "field %s expected float, got %s" name (Yojson.Safe.to_string json))
;;

let bool_field name fields =
  match field name fields with
  | Error _ as err -> err
  | Ok (`Bool value) -> Ok value
  | Ok json ->
    Error (Printf.sprintf "field %s expected bool, got %s" name (Yojson.Safe.to_string json))
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some json ->
    Error
      (Printf.sprintf "field %s expected optional string, got %s" name
         (Yojson.Safe.to_string json))
;;

let of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = object_fields json in
  let* event = string_field "event" fields in
  match event with
  | "register" ->
    let* run_id = string_field "run_id" fields in
    let* keeper = string_field "keeper" fields in
    let* preset = string_field "preset" fields in
    let* started_at = float_field "started_at" fields in
    Ok (Register { run_id; keeper; preset; started_at })
  | "complete" ->
    let* run_id = string_field "run_id" fields in
    let* ok = bool_field "ok" fields in
    let* failure = optional_string_field "failure" fields in
    let* failure_code = optional_string_field "failure_code" fields in
    Ok (Complete { run_id; ok; failure; failure_code })
  | other -> Error (Printf.sprintf "unknown fusion registry event %S" other)
;;

let to_jsonl t = Yojson.Safe.to_string (to_yojson t) ^ "\n"
