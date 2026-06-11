(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring. *)

let schema_version = "rfc0231-v1"

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

let json_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | _ -> None
;;

let json_int_field key fields =
  match List.assoc_opt key fields with
  | Some (`Int i) -> Some i
  | _ -> None
;;

let json_float_field key fields =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | _ -> None
;;

let json_bool_field key fields =
  match List.assoc_opt key fields with
  | Some (`Bool b) -> Some b
  | _ -> None
;;

let json_string_list_field key fields =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let strings = List.filter_map (function `String s -> Some s | _ -> None) items in
    if List.length strings = List.length items then Some strings else None
  | _ -> None
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

let provenance_event_of_json = function
  | `Assoc fields ->
    (match json_string_field "trace_id" fields, json_int_field "turn" fields with
     | Some trace_id, Some turn ->
       let tool_call_id = json_string_field "tool_call_id" fields in
       Some { trace_id; turn; tool_call_id }
     | _ -> None)
  | _ -> None
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
     ]
     @
     match f.valid_until with
     | Some ts -> [ "valid_until", `Float ts ]
     | None -> [])
;;

let fact_of_json = function
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
          let access_count = Option.value (json_int_field "access_count" fields) ~default:0 in
          let first_seen = Option.value (json_float_field "first_seen" fields) ~default:0.0 in
          let last_accessed = Option.value (json_float_field "last_accessed" fields) ~default:first_seen in
          let valid_until = json_float_field "valid_until" fields in
          Some
            { claim
            ; confidence = Float.max 0.0 (Float.min 1.0 confidence)
            ; category
            ; source
            ; access_count
            ; first_seen
            ; last_accessed
            ; valid_until
            ; schema_version =
                Option.value (json_string_field "schema_version" fields) ~default:schema_version
            }
        | None -> None)
     | _ -> None)
  | _ -> None
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

let episode_of_json = function
  | `Assoc fields ->
    (match
       ( json_string_field "trace_id" fields
       , json_int_field "generation" fields
       , json_string_field "episode_summary" fields
       , List.assoc_opt "claims" fields )
     with
     | Some trace_id, Some generation, Some episode_summary, Some (`List claim_items) ->
       let claims = List.filter_map fact_of_json claim_items in
       let open_items = Option.value (json_string_list_field "open_items" fields) ~default:[] in
       let constraints = Option.value (json_string_list_field "constraints" fields) ~default:[] in
       let preserved_tool_refs =
         Option.value (json_string_list_field "preserved_tool_refs" fields) ~default:[]
       in
       let source_turn_range =
         match List.assoc_opt "source_turn_range" fields with
         | Some (`Assoc r) ->
           (match json_int_field "lo" r, json_int_field "hi" r with
            | Some lo, Some hi -> Some (lo, hi)
            | _ -> None)
         | _ -> None
       in
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
             Option.value (json_string_field "schema_version" fields) ~default:schema_version
         }
     | _ -> None)
  | _ -> None
;;
