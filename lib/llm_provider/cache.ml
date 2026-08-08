(** Response cache interface for LLM completions. *)

type t =
  { get : key:string -> Yojson.Safe.t option
  ; set : key:string -> ttl_sec:int -> Yojson.Safe.t -> unit
  }

(* ── Fingerprint ────────────────────────────────────── *)

let message_fingerprint (m : Types.message) : Yojson.Safe.t =
  `Assoc
    [ "role", `String (Types.role_to_string m.role)
    ; "content", `List (List.map Api_common.content_block_to_json m.content)
    ]
;;

let request_fingerprint
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ?(tools = [])
      ()
  =
  let json =
    `Assoc
      [ "model_id", `String config.model_id
      ; "messages", `List (List.map message_fingerprint messages)
      ; "tools", `List tools
      ]
  in
  let canonical = Yojson.Safe.to_string json in
  Digest.string canonical |> Digest.to_hex
;;

(* ── Serialization ──────────────────────────────────── *)

let schema_version = "1"

(* stop_reason wire serialization is the SSOT [Types.stop_reason_to_string]
   (this module's former local copy was byte-identical). Cache schema_version
   "1" is preserved because the emitted strings are unchanged. *)

(* Cache replay routes through [Types.stop_reason_of_string] so that a cached
   response parses identically to a live one. A local copy here previously
   diverged from the canonical parser (it never learned pause_turn/refusal/
   compaction/model_context_window_exceeded), so a cached PauseTurn replayed as
   [Unknown "pause_turn"]. *)
let response_to_json (resp : Types.api_response) : Yojson.Safe.t =
  let usage_json =
    match resp.usage with
    | Some u ->
      `Assoc
        [ "input_tokens", `Int u.input_tokens
        ; "output_tokens", `Int u.output_tokens
        ; "cache_creation_input_tokens", `Int u.cache_creation_input_tokens
        ; "cache_read_input_tokens", `Int u.cache_read_input_tokens
        ; ( "cost_usd"
          , match u.cost_usd with
            | Some cost -> `Float cost
            | None -> `Null )
        ]
    | None -> `Null
  in
  `Assoc
    [ "v", `String schema_version
    ; "id", `String resp.id
    ; "model", `String resp.model
    ; "stop_reason", `String (Types.stop_reason_to_string resp.stop_reason)
    ; "content", `List (List.map Api_common.content_block_to_json resp.content)
    ; "usage", usage_json
    ]
;;

let response_of_json (json : Yojson.Safe.t) : Types.api_response option =
  let open Yojson.Safe.Util in
  try
    let v = json |> member "v" |> to_string in
    if v <> schema_version
    then None
    else (
      let usage =
        match json |> member "usage" with
        | `Null -> None
        | u ->
          Some
            { Types.input_tokens = u |> member "input_tokens" |> to_int
            ; output_tokens = u |> member "output_tokens" |> to_int
            ; cache_creation_input_tokens =
                u |> member "cache_creation_input_tokens" |> to_int
            ; cache_read_input_tokens = u |> member "cache_read_input_tokens" |> to_int
            ; cost_usd = u |> member "cost_usd" |> to_float_option
            }
      in
      let content =
        json
        |> member "content"
        |> to_list
        |> List.filter_map Api_common.content_block_of_json
      in
      Some
        { Types.id = json |> member "id" |> to_string
        ; model = json |> member "model" |> to_string
        ; stop_reason =
            json |> member "stop_reason" |> to_string |> Types.stop_reason_of_string
        ; content
        ; usage
        ; telemetry = None
        })
  with
  | Yojson.Safe.Util.Type_error _ | Not_found | Yojson.Json_error _ -> None
;;
