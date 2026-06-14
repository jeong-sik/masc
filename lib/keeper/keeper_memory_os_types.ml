(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring. *)

let schema_version = "rfc0231-v2"

type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

type fact =
  { claim : string
  ; confidence : float
  ; category : string
  ; source : provenance_event
  ; access_count : int
  ; first_seen : float
  ; last_accessed : float
  ; valid_until : float option
  ; stale_factor : float
  ; expected_lifetime_cycles : int option
  ; last_verified_at : float option
  ; schema_version : string
  }

type episode =
  { trace_id : string
  ; generation : int
  ; episode_summary : string
  ; claims : fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  ; source_turn_range : (int * int) option
  ; created_at : float
  ; schema_version : string
  }

(* ---------- JSON codecs ---------- *)

let json_string_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let json_int_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | Some (`Assoc _ | `Bool _ | `Float _ | `Intlit _ | `List _ | `Null | `String _)
  | None -> None
;;

let json_float_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Assoc _ | `Bool _ | `Intlit _ | `List _ | `Null | `String _) | None -> None
;;

let json_bool_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Bool b) -> Some b
  | Some (`Assoc _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
  | None -> None
;;

let json_string_list_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let strings =
      List.filter_map
        (function
          | `String s -> Some s
          | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null -> None)
        items
    in
    if List.length strings = List.length items then Some strings else None
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _)
  | None -> None
;;

let provenance_event_to_json (e : provenance_event) =
  let base =
    [ "trace_id", `String e.trace_id
    ; "turn", `Int e.turn
    ]
  in
  let tool =
    match e.tool_call_id with
    | Some id -> [ "tool_call_id", `String id ]
    | None -> []
  in
  `Assoc (base @ tool)
;;

let provenance_event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match json_string_field "trace_id" fields, json_int_field "turn" fields with
     | Some trace_id, Some turn ->
       let tool_call_id = json_string_field "tool_call_id" fields in
       Some { trace_id; turn; tool_call_id }
     | (Some _, None) | (None, Some _) | (None, None) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let fact_to_json f =
  `Assoc
    ([ "claim", `String f.claim
     ; "confidence", `Float f.confidence
     ; "category", `String f.category
     ; "source", provenance_event_to_json f.source
     ; "access_count", `Int f.access_count
     ; "first_seen", `Float f.first_seen
     ; "last_accessed", `Float f.last_accessed
     ; "schema_version", `String f.schema_version
     ; "stale_factor", `Float f.stale_factor
     ]
     @
     match f.valid_until with
     | Some ts -> [ "valid_until", `Float ts ]
     | None -> [])
     @ (match f.last_verified_at with
     | Some ts -> [ "last_verified_at", `Float ts ]
     | None -> [])
     @ (match f.expected_lifetime_cycles with
     | Some cycles -> [ "expected_lifetime_cycles", `Int cycles ]
     | None -> [])
;;

let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field "claim" fields
       , json_float_field "confidence" fields
       , json_string_field "category" fields
       , List.assoc_opt "source" fields )
     with
     | Some claim, Some confidence, Some category, Some source_json ->
       (match provenance_event_of_json source_json with
        | Some source ->
          (* DET-OK: backward-compatible defaults for optional persisted fields. *)
          let access_count = Option.value (json_int_field "access_count" fields) ~default:0 in
          (* DET-OK: absent first_seen defaults to epoch for migration safety. *)
          let first_seen = Option.value (json_float_field "first_seen" fields) ~default:0.0 in
          (* DET-OK: absent last_accessed inherits first_seen. *)
          let last_accessed = Option.value (json_float_field "last_accessed" fields) ~default:first_seen in
          let valid_until = json_float_field "valid_until" fields in
          let stale_factor = Option.value (json_float_field "stale_factor" fields) ~default:0.0 in
          let last_verified_at = json_float_field "last_verified_at" fields in
          let expected_lifetime_cycles = json_int_field "expected_lifetime_cycles" fields in
          Some
            { claim
            ; confidence = Float.max 0.0 (Float.min 1.0 confidence)
            ; category
            ; source
            ; access_count
            ; first_seen
            ; last_accessed
            ; valid_until
            ; stale_factor
            ; last_verified_at
            ; expected_lifetime_cycles
            ; schema_version =
                (* DET-OK: default to current schema for forward compatibility. *)
                Option.value (json_string_field "schema_version" fields) ~default:schema_version
            }
        | None -> None)
     | (Some _, Some _, Some _, None)
     | (Some _, Some _, None, _)
     | (Some _, None, _, _)
     | (None, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let episode_to_json e =
  let range_json =
    match e.source_turn_range with
    | Some (lo, hi) ->
      [ "source_turn_range", `Assoc [ "lo", `Int lo; "hi", `Int hi ] ]
    | None -> []
  in
  `Assoc
    ([ "trace_id", `String e.trace_id
     ; "generation", `Int e.generation
     ; "episode_summary", `String e.episode_summary
     ; "claims", `List (List.map fact_to_json e.claims)
     ; "open_items", `List (List.map (fun s -> `String s) e.open_items)
     ; "constraints", `List (List.map (fun s -> `String s) e.constraints)
     ; "preserved_tool_refs", `List (List.map (fun s -> `String s) e.preserved_tool_refs)
     ; "created_at", `Float e.created_at
     ; "schema_version", `String e.schema_version
     ]
     @ range_json)
;;

let episode_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field "trace_id" fields
       , json_int_field "generation" fields
       , json_string_field "episode_summary" fields
       , List.assoc_opt "claims" fields )
     with
     | Some trace_id, Some generation, Some episode_summary, Some (`List claim_items) ->
       let claims = List.filter_map fact_of_json claim_items in
       (* DET-OK: optional list fields default to empty. *)
       let open_items = Option.value (json_string_list_field "open_items" fields) ~default:[] in
       (* DET-OK: optional list fields default to empty. *)
       let constraints = Option.value (json_string_list_field "constraints" fields) ~default:[] in
       (* DET-OK: optional list fields default to empty. *)
       let preserved_tool_refs =
         Option.value (json_string_list_field "preserved_tool_refs" fields) ~default:[]
       in
       let source_turn_range =
         match List.assoc_opt "source_turn_range" fields with
         | Some (`Assoc r) ->
           (match json_int_field "lo" r, json_int_field "hi" r with
            | Some lo, Some hi -> Some (lo, hi)
            | (Some _, None) | (None, Some _) | (None, None) -> None)
         | Some (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
         | None ->
           None
       in
       (* DET-OK: absent created_at defaults to epoch for migration safety. *)
       let created_at = Option.value (json_float_field "created_at" fields) ~default:0.0 in
       Some
         { trace_id
         ; generation
         ; episode_summary
         ; claims
         ; open_items
         ; constraints
         ; preserved_tool_refs
         ; source_turn_range
         ; created_at
         ; schema_version =
             (* DET-OK: default to current schema for forward compatibility. *)
             Option.value (json_string_field "schema_version" fields) ~default:schema_version
         }
     | ( Some _
       , Some _
       , Some _
       , Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _) )
     | (Some _, Some _, Some _, None)
     | (Some _, Some _, None, _)
     | (Some _, None, _, _)
     | (None, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;
