(** Gate_protocol -- wire-level types for the Channel Gate HTTP API.
    See [gate_protocol.mli] for the full contract. *)

(* ── Wire Types ──────────────────────────────────────────────── *)

type inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

type turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

type message_request_tracking =
  | Keeper_run of
      { run_ref : Keeper_invocation_types.run_ref
      ; result_contract : Keeper_invocation_types.result_contract
      }
  | Chat_receipt of { receipt_id : string }

type message_request = {
  tracking : message_request_tracking;
  destination_type : string;
  destination_id : string;
  channel : string;
  actor_id : string option;
  modalities : string list;
  transport : string option;
  metadata : (string * string) list;
}

let string_list_json values =
  `List (List.map (fun value -> `String value) values)

let string_assoc_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

let message_request_to_json request =
  let optional_string = function
    | None -> `Null
    | Some value -> `String value
  in
  let tracking =
    match request.tracking with
    | Keeper_run { run_ref; result_contract } ->
      `Assoc
        [ "kind", `String "keeper_run"
        ; "run_ref", Keeper_invocation_types.run_ref_to_json run_ref
        ; ( "result_contract"
          , `String
              (Keeper_invocation_types.result_contract_to_string result_contract) )
        ]
    | Chat_receipt { receipt_id } ->
      `Assoc
        [ "kind", `String "chat_receipt"
        ; "receipt_id", `String receipt_id
        ; "state", `String "queued"
        ]
  in
  `Assoc
    [
      ("tracking", tracking);
      ("destination_type", `String request.destination_type);
      ("destination_id", `String request.destination_id);
      ("channel", `String request.channel);
      ("actor_id", optional_string request.actor_id);
      ("modalities", string_list_json request.modalities);
      ("transport", optional_string request.transport);
      ("metadata", string_assoc_json request.metadata);
    ]

type outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
  turn_stats : turn_stats option;
  message_request : message_request option;
}

(* ── Validation ──────────────────────────────────────────────── *)

type validation_error =
  | Empty_content
  | Content_too_long of int
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key
  | Duplicate_message of string

let validation_error_to_string = function
  | Empty_content -> "content is required"
  | Content_too_long len ->
      Printf.sprintf "content too long: %d chars" len
  | Empty_keeper_name -> "keeper_name is required"
  | Empty_channel_user_id -> "channel_user_id is required"
  | Empty_idempotency_key -> "idempotency_key is required"
  | Duplicate_message key ->
      Printf.sprintf "duplicate message (idempotency_key=%s)" key

let validate ~max_content_length ~dedup_check (msg : inbound_message) =
  let name = String.trim msg.keeper_name in
  if name = "" then Error Empty_keeper_name
  else if String.trim msg.channel_user_id = "" then Error Empty_channel_user_id
  else if String.trim msg.idempotency_key = "" then Error Empty_idempotency_key
  else
    let content = String.trim msg.content in
    if content = "" then Error Empty_content
    else
      let len = String.length content in
      if len > max_content_length then Error (Content_too_long len)
      else if dedup_check msg.idempotency_key then
        Error (Duplicate_message msg.idempotency_key)
      else Ok ()

(* ── Errors ──────────────────────────────────────────────────── *)

type gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

let gate_error_to_string = function
  | Validation e -> validation_error_to_string e
  | Keeper_error msg -> Printf.sprintf "keeper error: %s" msg
  | Dispatch_unavailable -> "keeper dispatch unavailable"
  | Internal _ -> "internal error"

(* ── Dispatch Result ─────────────────────────────────────────── *)

type dispatch_result =
  | Reply of
      { content : string
      ; structured : Yojson.Safe.t option
      ; stats : turn_stats option
      ; message_request : message_request option
      }
  | Keeper_error_result of string
  | Unavailable_result

(* ── JSON Codecs ─────────────────────────────────────────────── *)

let inbound_of_json json =
  try
    let () =
      match json with
      | `Assoc _ -> ()
      | _ -> invalid_arg "expected object"
    in
    let str key =
      Json_util.get_string json key
      |> Option.value ~default:""
    in
    let channel =
      let raw = str "channel" in
      String.lowercase_ascii (String.trim raw)
    in
    let keeper_name = str "destination_id" in
    let metadata =
      match Json_util.assoc_member_opt "metadata" json with
      | Some (`Assoc pairs) ->
          List.filter_map (fun (k, v) ->
            match v with `String s -> Some (k, s) | _ -> None
          ) pairs
      | _ -> []
    in
    Ok {
      channel;
      channel_user_id = str "channel_user_id";
      channel_user_name = str "channel_user_name";
      channel_workspace_id = str "channel_workspace_id";
      keeper_name;
      content = str "content";
      idempotency_key = str "idempotency_key";
      metadata;
    }
  with
  | Yojson.Json_error e -> Error ("invalid json: " ^ e)
  (* RFC-0106 — cancellation MUST propagate; the catch-all here
     would otherwise classify a fiber cancel as a "parse error". *)
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error ("parse error: " ^ Printexc.to_string exn)

let outbound_to_json out =
  let stats_json = match out.turn_stats with
    | None -> `Null
    | Some s ->
        `Assoc [
          ("model_used", `Null);
          ("duration_ms", `Int s.duration_ms);
          ("tokens_used", `Int s.tokens_used);
        ]
  in
  let base = [
    ("ok", `Bool true);
    ("destination_id", `String out.keeper_name);
    ("reply", `String out.content);
    ("turn_stats", stats_json);
  ] in
  let with_structured = match out.structured with
    | None -> base
    | Some json -> base @ [ ("structured", json) ]
  in
  let with_message_request =
    match out.message_request with
    | None -> with_structured
    | Some request ->
        with_structured @ [ ("message_request", message_request_to_json request) ]
  in
  `Assoc with_message_request

let error_json msg =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]
