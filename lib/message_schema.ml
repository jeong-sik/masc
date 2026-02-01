(** Message Schema: Structured message validation for MASC

    Based on MAST taxonomy (ICLR 2025) - specification problems account for 41.77%
    of multi-agent system failures. Structured message schemas prevent silent failures
    from format mismatches between agents.

    Design:
    - Variant types for compile-time message type checking
    - Freeform variant for backward compatibility
    - Configurable validation modes (Strict/Warn/Permissive)
*)

(** Validation mode controls how non-conforming messages are handled *)
type validation_mode =
  | Strict     (** Reject non-conforming messages *)
  | Warn       (** Accept but log warning *)
  | Permissive (** Accept all, wrap unknown as Freeform *)
[@@deriving show, eq]

let validation_mode_of_string = function
  | "strict" -> Strict
  | "warn" -> Warn
  | _ -> Permissive

let validation_mode_to_string = function
  | Strict -> "strict"
  | Warn -> "warn"
  | Permissive -> "permissive"

(** Structured message types for inter-agent communication *)
type structured_message =
  | TaskUpdate of {
      task_id: string;
      status: string;
      payload: Yojson.Safe.t option;
    }
  | StatusReport of {
      agent: string;
      progress: float;
      details: string;
    }
  | Request of {
      target: string;
      action: string;
      params: Yojson.Safe.t;
    }
  | Response of {
      request_id: string;
      success: bool;
      result: Yojson.Safe.t;
    }
  | Freeform of string
[@@deriving show, eq]

(** Serialize structured_message to JSON *)
let to_json = function
  | TaskUpdate { task_id; status; payload } ->
      `Assoc ([
        ("type", `String "task_update");
        ("task_id", `String task_id);
        ("status", `String status);
      ] @ match payload with
        | Some p -> [("payload", p)]
        | None -> [])
  | StatusReport { agent; progress; details } ->
      `Assoc [
        ("type", `String "status_report");
        ("agent", `String agent);
        ("progress", `Float progress);
        ("details", `String details);
      ]
  | Request { target; action; params } ->
      `Assoc [
        ("type", `String "request");
        ("target", `String target);
        ("action", `String action);
        ("params", params);
      ]
  | Response { request_id; success; result } ->
      `Assoc [
        ("type", `String "response");
        ("request_id", `String request_id);
        ("success", `Bool success);
        ("result", result);
      ]
  | Freeform text ->
      `Assoc [
        ("type", `String "freeform");
        ("text", `String text);
      ]

let get_string_field key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let get_float_field key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> Some f
       | Some (`Int n) -> Some (Float.of_int n)
       | _ -> None)
  | _ -> None

let get_bool_field key = function
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool b) -> Some b
       | _ -> None)
  | _ -> None

let of_json json =
  match get_string_field "type" json with
  | Some "task_update" ->
      (match get_string_field "task_id" json, get_string_field "status" json with
       | Some task_id, Some status ->
           let payload = match json with
             | `Assoc fields -> List.assoc_opt "payload" fields
             | _ -> None
           in
           Ok (TaskUpdate { task_id; status; payload })
       | _ -> Error "task_update requires 'task_id' and 'status' fields")
  | Some "status_report" ->
      (match get_string_field "agent" json, get_float_field "progress" json, get_string_field "details" json with
       | Some agent, Some progress, Some details ->
           Ok (StatusReport { agent; progress; details })
       | _ -> Error "status_report requires 'agent', 'progress', and 'details' fields")
  | Some "request" ->
      (match get_string_field "target" json, get_string_field "action" json with
       | Some target, Some action ->
           let params = match json with
             | `Assoc fields ->
                 (match List.assoc_opt "params" fields with
                  | Some p -> p
                  | None -> `Null)
             | _ -> `Null
           in
           Ok (Request { target; action; params })
       | _ -> Error "request requires 'target' and 'action' fields")
  | Some "response" ->
      (match get_string_field "request_id" json, get_bool_field "success" json with
       | Some request_id, Some success ->
           let result = match json with
             | `Assoc fields ->
                 (match List.assoc_opt "result" fields with
                  | Some r -> r
                  | None -> `Null)
             | _ -> `Null
           in
           Ok (Response { request_id; success; result })
       | _ -> Error "response requires 'request_id' and 'success' fields")
  | Some "freeform" ->
      (match get_string_field "text" json with
       | Some text -> Ok (Freeform text)
       | None -> Error "freeform requires 'text' field")
  | Some unknown -> Error (Printf.sprintf "unknown message type: %s" unknown)
  | None -> Error "missing 'type' field in message"

let validate ?(mode=Permissive) raw_message =
  match Yojson.Safe.from_string raw_message with
  | json ->
      (match of_json json with
       | Ok msg -> Ok msg
       | Error reason ->
           match mode with
           | Strict -> Error (Printf.sprintf "Schema validation failed: %s" reason)
           | Warn -> Ok (Freeform raw_message)
           | Permissive -> Ok (Freeform raw_message))
  | exception _ ->
      match mode with
      | Strict -> Error "Message must be valid JSON in strict mode"
      | Warn | Permissive -> Ok (Freeform raw_message)

let message_type_string = function
  | TaskUpdate _ -> "task_update"
  | StatusReport _ -> "status_report"
  | Request _ -> "request"
  | Response _ -> "response"
  | Freeform _ -> "freeform"

let is_targeted_at agent = function
  | Request { target; _ } -> String.equal target agent
  | _ -> false

let json_schema =
  `Assoc [
    ("type", `String "object");
    ("oneOf", `List [
      `Assoc [
        ("properties", `Assoc [
          ("type", `Assoc [("const", `String "task_update")]);
          ("task_id", `Assoc [("type", `String "string")]);
          ("status", `Assoc [("type", `String "string")]);
          ("payload", `Assoc [("type", `String "object")]);
        ]);
        ("required", `List [`String "type"; `String "task_id"; `String "status"]);
      ];
      `Assoc [
        ("properties", `Assoc [
          ("type", `Assoc [("const", `String "status_report")]);
          ("agent", `Assoc [("type", `String "string")]);
          ("progress", `Assoc [("type", `String "number"); ("minimum", `Float 0.0); ("maximum", `Float 1.0)]);
          ("details", `Assoc [("type", `String "string")]);
        ]);
        ("required", `List [`String "type"; `String "agent"; `String "progress"; `String "details"]);
      ];
      `Assoc [
        ("properties", `Assoc [
          ("type", `Assoc [("const", `String "request")]);
          ("target", `Assoc [("type", `String "string")]);
          ("action", `Assoc [("type", `String "string")]);
          ("params", `Assoc [("type", `String "object")]);
        ]);
        ("required", `List [`String "type"; `String "target"; `String "action"]);
      ];
      `Assoc [
        ("properties", `Assoc [
          ("type", `Assoc [("const", `String "response")]);
          ("request_id", `Assoc [("type", `String "string")]);
          ("success", `Assoc [("type", `String "boolean")]);
          ("result", `Assoc []);
        ]);
        ("required", `List [`String "type"; `String "request_id"; `String "success"]);
      ];
      `Assoc [
        ("properties", `Assoc [
          ("type", `Assoc [("const", `String "freeform")]);
          ("text", `Assoc [("type", `String "string")]);
        ]);
        ("required", `List [`String "type"; `String "text"]);
      ];
    ]);
  ]

let roundtrip msg =
  let json = to_json msg in
  of_json json
