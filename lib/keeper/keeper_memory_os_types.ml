(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring. *)

let schema_version = "rfc0231-v2"

(* RFC-0244 Tier 2: the shared semantic store reuses the per-keeper IO/codec
   under a reserved id. A leading underscore is not produced by keeper naming, so
   no real keeper collides with its file (keepers/_shared.facts.jsonl); the
   consolidator additionally filters this id out of its source keeper list. *)
let shared_store_id = "_shared"

type provenance_event =
  { trace_id : string
  ; turn : int
  ; tool_call_id : string option
  }

(* The librarian taxonomy as a closed sum (RFC-0244 §2.3, #21241; RFC-0247 §2.5).
   The LLM emits a free-text category label; [category_of_string] parses it once
   at the producer boundary into this type, with [Unknown] absorbing any label
   outside the taxonomy (drift / typo / a future label) instead of letting a
   free-text string flow downstream. [Ephemeral] (RFC-0247) is the non-promotable
   arm for coordination/lifecycle boilerplate — the structural backstop for the
   #21244 mislabel-and-promote failure: even if the prompt's durability gate is
   imperfect, a claim the LLM recognizes as ephemeral is typed non-promotable and
   forgotten, rather than silently entering the store as a durable fact. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Ephemeral
  | Unknown of string

let category_to_string = function
  | Code_change -> "code_change"
  | Fact -> "fact"
  | Preference -> "preference"
  | Blocker -> "blocker"
  | Goal -> "goal"
  | Constraint -> "constraint"
  | Ephemeral -> "ephemeral"
  | Unknown s -> s
;;

let category_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "code_change" -> Code_change
  | "fact" -> Fact
  | "preference" -> Preference
  | "blocker" -> Blocker
  | "goal" -> Goal
  | "constraint" -> Constraint
  | "ephemeral" -> Ephemeral
  | _ -> Unknown s
;;

(* Exhaustive promotability: only objective, durable claim kinds cross keepers.
   Preserves the prior [Fact; Constraint] whitelist exactly; everything else —
   including [Ephemeral] and any [Unknown] label — stays keeper-local. Exhaustive
   match (not a runtime [category list]) so a future durable kind must be
   classified here at compile time rather than silently defaulting to
   non-promotable, the no-silent-omission property RFC-0247 §2.5 argues for over
   the prompt-suppression approach. *)
let is_promotable = function
  | Fact | Constraint -> true
  | Code_change | Preference | Blocker | Goal | Ephemeral | Unknown _ -> false
;;

(* RFC-0247 §2.3 (forgetting): retention is a property of the category. A
   coordination event ("checkpoint saved") is stale within a day and worthless in
   a later session, so it gets a short hard TTL and a fast truth-decay; durable
   knowledge never hard-expires and decays slowly. These two functions are the
   write-side producers that make [valid_until] and [expected_lifetime_cycles]
   (previously set-once-to-None dead fields) actually reachable. *)

(* A coordination/lifecycle fact is stale within a day. Named, not magic. *)
let ephemeral_ttl_seconds = 86_400.0

(* Ephemeral facts decay over a few retention cycles; with the policy's
   default_cycle_seconds (1h) this is a ~hours half-life vs the ~30-day default,
   so an ephemeral fact loses recall score fast even before its hard TTL. *)
let ephemeral_lifetime_cycles = 3

let category_valid_until ~now = function
  | Ephemeral -> Some (now +. ephemeral_ttl_seconds)
  | Fact | Constraint | Preference | Blocker | Goal | Code_change | Unknown _ -> None
;;

let category_lifetime_cycles = function
  | Ephemeral -> Some ephemeral_lifetime_cycles
  | Fact | Constraint | Preference | Blocker | Goal | Code_change | Unknown _ -> None
;;

type fact =
  { claim : string
  ; confidence : float
  ; category : category
  ; source : provenance_event
  ; observed_by : string list
    (* RFC-0244 Tier 2 (shared semantic store) ONLY: the sorted set of distinct
       keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
       facts — a single keeper's store has no distinct keeper-source to track, so
       it is omitted from their JSON. This is the consolidator-populated field
       that makes cross-keeper confidence live: a shared fact's confidence rises
       only per NEW distinct keeper, never on a same-keeper repeat. *)
  ; access_count : int
  ; first_seen : float
  ; last_accessed : float
  ; valid_until : float option
  ; stale_factor : float
  ; last_verified_at : float option
  ; expected_lifetime_cycles : int option
  ; schema_version : string
  ; content_hash : string
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
  ; valid_until : float option
  ; terminal_marker : string option
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

let clamp01 value =
  Float.max 0.0 (Float.min 1.0 value)
;;

(* Claim identity SSOT: collapse a claim to a normalized fingerprint (lowercase +
   internal-whitespace-collapsed + trailing-space-trimmed) so trivially reworded
   re-confirmations of the same conclusion ("...would end the session" vs "...will
   end the session", or differing case/spacing) share a key. The recall-time dedup
   (Keeper_memory_os_recall.dedup_by_claim) and the write-time upsert
   (Keeper_memory_os_io.merge_and_cap_facts) MUST key on the same function, so it
   lives here in the shared base module rather than in either consumer. *)
let normalize_claim s =
  let b = Buffer.create (String.length s) in
  let prev_space = ref true in
  String.iter
    (fun c ->
      match Char.lowercase_ascii c with
      | ' ' | '\t' | '\r' | '\n' ->
        if not !prev_space then Buffer.add_char b ' ';
        prev_space := true
      | c ->
        Buffer.add_char b c;
        prev_space := false)
    s;
  let r = Buffer.contents b in
  let n = String.length r in
  if n > 0 && r.[n - 1] = ' ' then String.sub r 0 (n - 1) else r
;;

let optional_float_field key = function
  | Some value -> [ key, `Float value ]
  | None -> []
;;

let optional_int_field key = function
  | Some value -> [ key, `Int value ]
  | None -> []
;;

let fact_to_json f =
  let fields =
    [ "claim", `String f.claim
    ; "confidence", `Float f.confidence
    ; "category", `String (category_to_string f.category)
    ; "source", provenance_event_to_json f.source
    ; "access_count", `Int f.access_count
    ; "first_seen", `Float f.first_seen
    ; "last_accessed", `Float f.last_accessed
    ; "stale_factor", `Float f.stale_factor
    ; "schema_version", `String f.schema_version
    ; "content_hash", `String f.content_hash
    ]
    @ optional_float_field "valid_until" f.valid_until
    @ optional_float_field "last_verified_at" f.last_verified_at
    @ optional_int_field "expected_lifetime_cycles" f.expected_lifetime_cycles
    (* Tier-1 facts carry [], which is omitted so per-keeper stores stay
       byte-identical to pre-RFC-0244; only Tier-2 shared facts emit it. *)
    @ (match f.observed_by with
       | [] -> []
       | keepers -> [ "observed_by", `List (List.map (fun k -> `String k) keepers) ])
  in
  `Assoc fields
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
     | Some claim, Some confidence, Some category_str, Some source_json ->
       (match provenance_event_of_json source_json with
        | Some source ->
          (* DET-OK: backward-compatible defaults for optional persisted fields. *)
          let access_count = Option.value (json_int_field "access_count" fields) ~default:0 in
          (* DET-OK: absent first_seen defaults to epoch for migration safety. *)
          let first_seen = Option.value (json_float_field "first_seen" fields) ~default:0.0 in
          (* DET-OK: absent last_accessed inherits first_seen. *)
          let last_accessed = Option.value (json_float_field "last_accessed" fields) ~default:first_seen in
          let valid_until = json_float_field "valid_until" fields in
          let stale_factor =
            match json_float_field "stale_factor" fields with
            | Some value -> clamp01 value
            | None ->
              (* DET-OK: legacy v1 facts had no stale marker, so they start
                 as not-explicitly-stale and are still truth-aged by policy. *)
              0.0
          in
          let last_verified_at = json_float_field "last_verified_at" fields in
          (* DET-OK: absent observed_by defaults to empty (Tier-1 / legacy facts). *)
          let observed_by =
            Option.value (json_string_list_field "observed_by" fields) ~default:[]
          in
          let expected_lifetime_cycles =
            match json_int_field "expected_lifetime_cycles" fields with
            | Some cycles when cycles > 0 -> Some cycles
            | Some _ | None -> None
          in
          Some
            { claim
            ; confidence = clamp01 confidence
            ; (* Parse-once at the read boundary; legacy free-string categories
                 on disk map to their arm or [Unknown] (graceful-degrade). *)
              category = category_of_string category_str
            ; source
            ; observed_by
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
            ; content_hash =
                (* DET-OK: default to empty for backward compat with pre-hash facts. *)
                Option.value (json_string_field "content_hash" fields) ~default:""
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
     @ range_json
     @ optional_float_field "valid_until" e.valid_until
     @ (match e.terminal_marker with
        | Some marker -> [ "terminal_marker", `String marker ]
        | None -> []))
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
       (* DET-OK: legacy episodes had no TTL or terminal marker. *)
       let valid_until = json_float_field "valid_until" fields in
       let terminal_marker = json_string_field "terminal_marker" fields in
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
         ; valid_until
         ; terminal_marker
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
