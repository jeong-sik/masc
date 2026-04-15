(** Gate_protocol -- wire-level types for the Channel Gate HTTP API.
    See [gate_protocol.mli] for the full contract. *)

(* ── Wire Types ──────────────────────────────────────────────── *)

type inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
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

type outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
  turn_stats : turn_stats option;
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
  | Reply of { content : string; structured : Yojson.Safe.t option; stats : turn_stats option }
  | Keeper_error_result of string
  | Unavailable_result

(* ── JSON Codecs ─────────────────────────────────────────────── *)

let inbound_of_json json =
  let open Yojson.Safe.Util in
  try
    let str key =
      json |> member key |> to_string_option
      |> Option.value ~default:""
    in
    let channel =
      let raw = str "channel" in
      String.lowercase_ascii (String.trim raw)
    in
    (* Read priority for the keeper-routing field: accept the new
       [destination_id] key first and fall back to the legacy [keeper_name]
       key. Both map onto the same record field for now; emit-side is still
       [keeper_name] only (B2 Phase 1 — parse-both / emit-legacy). The
       emit-side rotation happens in Phase 2. *)
    let keeper_name =
      let destination = str "destination_id" in
      if destination <> "" then destination
      else str "keeper_name"
    in
    let metadata =
      match json |> member "metadata" with
      | `Assoc pairs ->
          List.filter_map (fun (k, v) ->
            match v with `String s -> Some (k, s) | _ -> None
          ) pairs
      | _ -> []
    in
    Ok {
      channel;
      channel_user_id = str "channel_user_id";
      channel_user_name = str "channel_user_name";
      channel_room_id = str "channel_room_id";
      keeper_name;
      content = str "content";
      idempotency_key = str "idempotency_key";
      metadata;
    }
  with
  | Yojson.Json_error e -> Error ("invalid json: " ^ e)
  | exn -> Error ("parse error: " ^ Printexc.to_string exn)

let outbound_to_json out =
  let stats_json = match out.turn_stats with
    | None -> `Null
    | Some s ->
        `Assoc [
          ("model_used", `String s.model_used);
          ("duration_ms", `Int s.duration_ms);
          ("tokens_used", `Int s.tokens_used);
        ]
  in
  let base = [
    ("ok", `Bool true);
    ("keeper_name", `String out.keeper_name);
    ("reply", `String out.content);
    ("turn_stats", stats_json);
  ] in
  let with_structured = match out.structured with
    | None -> base
    | Some json -> base @ [ ("structured", json) ]
  in
  `Assoc with_structured

let error_json msg =
  `Assoc [ ("ok", `Bool false); ("error", `String msg) ]
