(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring.

    Bug1 Fix: Added `stale` field to fact type to track staleness over time.
    Stale is computed by decay_stale in keeper_memory_os_policy.ml based on
    elapsed time since last_accessed.
    
    Bug3 Fix: Added `is_system_event` field to fact type to mark and filter
    system noise events (checkpoint, continuation, heartbeat).
    
    Bug2 Fix: Added `dedup_key` and `similar_fact_ids` fields for semantic
    de-duplication. dedup_key is a normalized hash of the fact content;
    similar_fact_ids tracks IDs of semantically similar facts. *)

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
  ; stale : float  (** Bug1 fix: 0.0=fresh, 1.0=max stale. Updated by decay_stale. *)
  ; valid_until : float option
  ; schema_version : string
  ; verified : bool
  ; is_system_event : bool  (** Bug3 fix: true for checkpoint/continuation/heartbeat noise *)
  ; dedup_key : string  (** Bug2 fix: normalized hash for de-duplication *)
  ; similar_fact_ids : string list  (** Bug2 fix: IDs of semantically similar facts *)
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
  ; verified : bool
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
     ; "stale", `Float f.stale  (** Bug1 fix: persist stale value *)
     ; "schema_version", `String f.schema_version
     ; "verified", `Bool f.verified
     ; "is_system_event", `Bool f.is_system_event  (** Bug3 fix: persist system event flag *)
     ; "dedup_key", `String f.dedup_key  (** Bug2 fix: persist dedup key *)
     ; "similar_fact_ids", `List (List.map (fun s -> `String s) f.similar_fact_ids)  (** Bug2 fix: persist similar IDs *)
     ])
;;

let fact_of_json (json : Yojson.Safe.t) : fact option =
  match json with
  | `Assoc fields ->
    let open Option.Monad_infix in
    let claim = json_string_field "claim" fields in
    let confidence = json_float_field "confidence" fields in
    let category = json_string_field "category" fields in
    let source =
      match json_string_field "source" fields with
      | Some s -> provenance_event_of_json (`String s)
      | None -> None
    in
    let access_count = json_int_field "access_count" fields in
    let first_seen = json_float_field "first_seen" fields in
    let last_accessed = json_float_field "last_accessed" fields in
    let stale = json_float_field "stale" fields in  (** Bug1 fix: read stale value *)
    let schema_version = json_string_field "schema_version" fields in
    let verified = json_bool_field "verified" fields in
    let is_system_event = json_bool_field "is_system_event" fields in  (** Bug3 fix: read system event flag *)
    let dedup_key = json_string_field "dedup_key" fields in  (** Bug2 fix: read dedup key *)
    let similar_fact_ids = json_string_list_field "similar_fact_ids" fields in  (** Bug2 fix: read similar IDs *)
    let valid_until =
      match json_float_field "valid_until" fields with
      | Some v -> Some v
      | None -> None
    in
    match
      claim
      >>= fun claim ->
      confidence >>= fun confidence ->
      category >>= fun category ->
      source >>= fun source ->
      access_count >>= fun access_count ->
      first_seen >>= fun first_seen ->
      last_accessed >>= fun last_accessed ->
      stale >>= fun stale ->
      schema_version >>= fun schema_version ->
      verified >>= fun verified ->
      is_system_event >>= fun is_system_event ->
      dedup_key >>= fun dedup_key ->
      similar_fact_ids >>= fun similar_fact_ids ->
      Some { claim; confidence; category; source; access_count; first_seen; last_accessed; stale; valid_until; schema_version; verified; is_system_event; dedup_key; similar_fact_ids }
    with
    | Some f -> Some f
    | None -> None
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let episode_to_json (e : episode) =
  `Assoc
    ([ "trace_id", `String e.trace_id
     ; "generation", `Int e.generation
     ; "episode_summary", `String e.episode_summary
     ; "claims", `List (List.map fact_to_json e.claims)
     ; "open_items", `List (List.map (fun s -> `String s) e.open_items)
     ; "constraints", `List (List.map (fun s -> `String s) e.constraints)
     ; "preserved_tool_refs", `List (List.map (fun s -> `String s) e.preserved_tool_refs)
     ; "source_turn_range",
       (match e.source_turn_range with
        | Some (lo, hi) -> `List [ `Int lo; `Int hi ]
        | None -> `Null)
     ; "created_at", `Float e.created_at
     ; "schema_version", `String e.schema_version
     ; "verified", `Bool e.verified
     ])
;;

let episode_of_json (json : Yojson.Safe.t) : episode option =
  match json with
  | `Assoc fields ->
    let open Option.Monad_infix in
    let trace_id = json_string_field "trace_id" fields in
    let generation = json_int_field "generation" fields in
    let episode_summary = json_string_field "episode_summary" fields in
    let claims =
      match json_string_list_field "claims" fields with
      | Some _ -> None  (* claims need special handling *)
      | None -> None
    in
    let open_items = json_string_list_field "open_items" fields in
    let constraints = json_string_list_field "constraints" fields in
    let preserved_tool_refs = json_string_list_field "preserved_tool_refs" fields in
    let created_at = json_float_field "created_at" fields in
    let schema_version = json_string_field "schema_version" fields in
    let verified = json_bool_field "verified" fields in
    let source_turn_range =
      match List.assoc_opt "source_turn_range" fields with
      | Some (`List [ `Int lo; `Int hi ]) -> Some (lo, hi)
      | Some (`Null | `List _ | `String _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Assoc _)
      | None -> None
    in
    match
      trace_id >>= fun trace_id ->
      generation >>= fun generation ->
      episode_summary >>= fun episode_summary ->
      (* claims parsing *)
      (match List.assoc_opt "claims" fields with
       | Some (`List items) ->
         let claims =
           List.filter_map
             (function
               | `Assoc _ as j -> fact_of_json j
               | _ -> None)
             items
         in
         Some claims
       | Some (`String _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `Assoc _)
       | None -> None)
      >>= fun claims ->
      open_items >>= fun open_items ->
      constraints >>= fun constraints ->
      preserved_tool_refs >>= fun preserved_tool_refs ->
      created_at >>= fun created_at ->
      schema_version >>= fun schema_version ->
      verified >>= fun verified ->
      Some { trace_id; generation; episode_summary; claims; open_items; constraints; preserved_tool_refs; source_turn_range; created_at; schema_version; verified }
    with
    | Some e -> Some e
    | None -> None
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;