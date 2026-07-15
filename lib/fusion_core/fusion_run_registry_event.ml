(* JSONL event type for fusion run registry persistence (RFC-0266 §7 Phase D).
   Each lifecycle transition appends one line so run history
   survives server restart. [Register] contains the complete canonical operation;
   replay never reconstructs an execution request from metadata or defaults. *)

module Claim_id = struct
  type t = Claim_id of string [@@deriving yojson, show, eq]

  let create () =
    (* NDT-OK: entropy is identity only; decisions never inspect its contents. *)
    Claim_id
      (Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string)
  ;;

  let to_string (Claim_id value) = value
end

type t =
  | Register of
      { operation : Fusion_types.fusion_operation
      ; started_at : float
      }
  | Claim of
      { operation_id : string
      ; claim_id : Claim_id.t
      }
  | Start of
      { operation_id : string
      ; claim_id : Claim_id.t
      }
  | Complete of
      { operation_id : string
      ; ok : bool
      ; failure : string option
      ; failure_code : string option
      }

let to_yojson = function
  | Register { operation; started_at } ->
    `Assoc
      [ ("event", `String "register")
      ; ("operation", Fusion_types.fusion_operation_to_yojson operation)
      ; ("started_at", `Float started_at)
      ]
  | Claim { operation_id; claim_id } ->
    `Assoc
      [ ("event", `String "claim")
      ; ("operation_id", `String operation_id)
      ; ("claim_id", Claim_id.to_yojson claim_id)
      ]
  | Start { operation_id; claim_id } ->
    `Assoc
      [ ("event", `String "start")
      ; ("operation_id", `String operation_id)
      ; ("claim_id", Claim_id.to_yojson claim_id)
      ]
  | Complete { operation_id; ok; failure; failure_code } ->
    `Assoc
      (List.filter_map
         (fun (k, v) -> Option.map (fun value -> (k, value)) v)
         [ "event", Some (`String "complete")
         ; "operation_id", Some (`String operation_id)
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

let operation_field fields =
  let ( let* ) = Result.bind in
  let* json = field "operation" fields in
  Fusion_types.fusion_operation_of_yojson json
;;

let claim_id_field fields =
  let ( let* ) = Result.bind in
  let* json = field "claim_id" fields in
  Claim_id.of_yojson json
;;

let of_yojson json =
  let ( let* ) = Result.bind in
  let* fields = object_fields json in
  let* event = string_field "event" fields in
  match event with
  | "register" ->
    let* operation = operation_field fields in
    let* started_at = float_field "started_at" fields in
    Ok (Register { operation; started_at })
  | "claim" ->
    let* operation_id = string_field "operation_id" fields in
    let* claim_id = claim_id_field fields in
    Ok (Claim { operation_id; claim_id })
  | "start" ->
    let* operation_id = string_field "operation_id" fields in
    let* claim_id = claim_id_field fields in
    Ok (Start { operation_id; claim_id })
  | "complete" ->
    let* operation_id = string_field "operation_id" fields in
    let* ok = bool_field "ok" fields in
    let* failure = optional_string_field "failure" fields in
    let* failure_code = optional_string_field "failure_code" fields in
    Ok (Complete { operation_id; ok; failure; failure_code })
  | other -> Error (Printf.sprintf "unknown fusion registry event %S" other)
;;

let to_jsonl t = Yojson.Safe.to_string (to_yojson t) ^ "\n"
