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
   forgotten, rather than silently entering the store as a durable fact.

   [Validated_approach] and [Lesson] (RFC-0247 §6) are the two outcome-derived
   kinds the redesign exists to capture: a [Validated_approach] is something that
   worked, confirmed by its result ("remember successes well"); a [Lesson] is a
   failure distilled into how to do it better next time ("record failures as the
   way to improve them" — mirrors the Why/How-to-apply shape of a Claude-Code
   feedback note). Both are durable, cross-keeper knowledge, so both promote. *)
type category =
  | Code_change
  | Fact
  | Preference
  | Blocker
  | Goal
  | Constraint
  | Ephemeral
  | Validated_approach
  | Lesson
  | Unknown of string

let category_to_string = function
  | Code_change -> "code_change"
  | Fact -> "fact"
  | Preference -> "preference"
  | Blocker -> "blocker"
  | Goal -> "goal"
  | Constraint -> "constraint"
  | Ephemeral -> "ephemeral"
  | Validated_approach -> "validated_approach"
  | Lesson -> "lesson"
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
  | "validated_approach" -> Validated_approach
  | "lesson" -> Lesson
  | _ -> Unknown s
;;

(* Exhaustive promotability: only objective, durable claim kinds cross keepers.
   Extends the prior [Fact; Constraint] whitelist with the two outcome-derived
   kinds [Validated_approach] and [Lesson] — a validated approach and a hard-won
   lesson are exactly the knowledge worth sharing fleet-wide. Everything else —
   including [Ephemeral] and any [Unknown] label — stays keeper-local. Exhaustive
   match (not a runtime [category list]) so a future durable kind must be
   classified here at compile time rather than silently defaulting to
   non-promotable, the no-silent-omission property RFC-0247 §2.5 argues for over
   the prompt-suppression approach. *)
let is_promotable = function
  | Fact | Constraint | Validated_approach | Lesson -> true
  | Code_change | Preference | Blocker | Goal | Ephemeral | Unknown _ -> false
;;

(* RFC-0247 §2.3 (forgetting): retention is a property of the category. A
   coordination event ("checkpoint saved") is stale within a day and worthless in
   a later session, so it gets a short hard TTL; durable knowledge never
   hard-expires. [category_valid_until] is the write-side producer that makes
   [valid_until] reachable. The companion [category_lifetime_cycles] (truth-decay
   rate) was deleted with the score it fed. *)

(* A coordination/lifecycle fact is stale within a day. Named, not magic. *)
let ephemeral_ttl_seconds = 86_400.0

let category_valid_until ~now = function
  | Ephemeral -> Some (now +. ephemeral_ttl_seconds)
  | Fact | Constraint | Preference | Blocker | Goal | Code_change
  | Validated_approach | Lesson | Unknown _ -> None
;;

(* ---------- External reference (RFC-0259 §3.2) ----------

   A claim about volatile external state ("PR #X is merged", "issue #Y blocked")
   was true when extracted and goes false when the world moves on. RFC-0259
   classifies such a claim at the producer boundary so it can be (a) given a
   finite decay horizon now, and (b) re-grounded against the source of truth by
   the P2 reconciler later. The kind selects which source of truth to check. *)
type external_ref_kind =
  | Pr
  | Issue
  | Task

(* [id] is the bare number ("21515"); [kind] selects the source of truth. *)
type external_ref =
  { kind : external_ref_kind
  ; id : string
  }

let external_ref_kind_to_string = function
  | Pr -> "pr"
  | Issue -> "issue"
  | Task -> "task"
;;

let external_ref_kind_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "pr" -> Some Pr
  | "issue" -> Some Issue
  | "task" -> Some Task
  | _ -> None
;;

(* First index >= [from] at which [needle] occurs in [haystack], else None. Naive
   scan — claims are short, so O(n*m) is fine and avoids a regex dependency. *)
let substring_index ~haystack ~needle ~from =
  let hl = String.length haystack
  and nl = String.length needle in
  if nl = 0
  then Some from
  else (
    let rec loop i =
      if i + nl > hl
      then None
      else if String.equal (String.sub haystack i nl) needle
      then Some i
      else loop (i + 1)
    in
    loop (max 0 from))
;;

(* Read a bare id at [start] in [s]: skip a leading '#'/space run, then take the
   ASCII-digit run. None when no digits follow the marker. *)
let read_ref_id s start =
  let n = String.length s in
  let rec skip i =
    if i < n && (Char.equal s.[i] ' ' || Char.equal s.[i] '#') then skip (i + 1) else i
  in
  let j = skip start in
  let rec digits k = if k < n && s.[k] >= '0' && s.[k] <= '9' then digits (k + 1) else k in
  let e = digits j in
  if e > j then Some (String.sub s j (e - j)) else None
;;

(* Explicit markers only (parse-don't-validate): a bare "#123" is left
   unclassified because PR vs issue is ambiguous and the reconciler needs the
   kind. Longest/most-specific markers first so "pull request #" wins over a
   spurious "pr #" prefix match. *)
let ref_markers =
  [ "pull request #", Pr
  ; "pr #", Pr
  ; "pr#", Pr
  ; "issue #", Issue
  ; "issue#", Issue
  ; "task-", Task
  ]
;;

(* RFC-0259 §3.2: parse the first external reference a claim names. Deterministic;
   None when the claim names no id. Run once at the producer boundary. *)
let parse_external_ref claim =
  let lower = String.lowercase_ascii claim in
  let candidates =
    List.filter_map
      (fun (marker, kind) ->
        match substring_index ~haystack:lower ~needle:marker ~from:0 with
        | None -> None
        | Some pos ->
          (match read_ref_id lower (pos + String.length marker) with
           | Some id -> Some (pos, { kind; id })
           | None -> None))
      ref_markers
  in
  match List.sort (fun (a, _) (b, _) -> compare (a : int) b) candidates with
  | (_, r) :: _ -> Some r
  | [] -> None
;;

(* RFC-0259 §3.2: an externally-referenced claim is volatile and must never be
   durable. It is born with a finite horizon shorter than [ephemeral_ttl] —
   external status (open/merged/blocked) moves faster than coordination
   boilerplate. Trade-off: a still-true ref may be re-extracted after the horizon
   (cheap), versus a stale ref driving action for ~30 turns (the RFC-0259 §2 bug).
   When the P2 reconciler lands it advances [last_verified_at] for confirmed refs;
   until then this TTL is the sole backstop against immortal volatile facts. *)
let volatile_ref_ttl_seconds = 21_600.0

(* The fact-level retention horizon: an external reference forces a finite TTL
   (closing gap #4) and otherwise the category decides (RFC-0247). *)
let fact_valid_until ~now ~external_ref category =
  match external_ref with
  | Some _ -> Some (now +. volatile_ref_ttl_seconds)
  | None -> category_valid_until ~now category
;;

(* RFC-0247 (purge): the fact carries only structure — the claim, its typed
   category, provenance, the distinct-keeper corroboration set, and three
   timestamps (first_seen, optional last_verified_at, optional Ephemeral
   valid_until). The deleted fields (confidence, access_count, last_accessed,
   stale_factor, expected_lifetime_cycles) were inputs to the removed composite
   score; a fact's value is the librarian's judgment, not a number on the row. *)
type fact =
  { claim : string
  ; category : category
  ; source : provenance_event
  ; observed_by : string list
    (* RFC-0244 Tier 2 (shared semantic store) ONLY: the sorted set of distinct
       keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
       facts — a single keeper's store has no distinct keeper-source to track, so
       it is omitted from their JSON. *)
  ; external_ref : external_ref option
    (* RFC-0259 §3.2: [Some] when the claim names verifiable external state
       (PR/issue/task id). Such a fact is volatile — never durable — so it is
       born with a finite [valid_until]; [None] for claims with no external
       referent (those follow the category's retention). *)
  ; first_seen : float
  ; valid_until : float option
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

let external_ref_to_json (r : external_ref) =
  `Assoc
    [ "kind", `String (external_ref_kind_to_string r.kind)
    ; "id", `String r.id
    ]
;;

let external_ref_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match json_string_field "kind" fields, json_string_field "id" fields with
     | Some kind_str, Some id ->
       (match external_ref_kind_of_string kind_str with
        | Some kind -> Some { kind; id }
        | None -> None)
     | (Some _, None) | (None, Some _) | (None, None) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
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

let fact_to_json f =
  let fields =
    [ "claim", `String f.claim
    ; "category", `String (category_to_string f.category)
    ; "source", provenance_event_to_json f.source
    ; "first_seen", `Float f.first_seen

    ; "schema_version", `String f.schema_version
    ]
    @ optional_float_field "valid_until" f.valid_until
    @ optional_float_field "last_verified_at" f.last_verified_at
    (* Omitted when [None] so facts with no external referent stay byte-identical
       to pre-RFC-0259 rows; only externally-referenced claims emit it. *)
    @ (match f.external_ref with
       | Some r -> [ "external_ref", external_ref_to_json r ]
       | None -> [])
    (* Tier-1 facts carry [], which is omitted so per-keeper stores stay
       byte-identical to pre-RFC-0244; only Tier-2 shared facts emit it. *)
    @ (match f.observed_by with
       | [] -> []
       | keepers -> [ "observed_by", `List (List.map (fun k -> `String k) keepers) ])
  in
  `Assoc fields
;;

(* RFC-0247 (purge): a fact decodes from [claim], [category], and [source] only.
   [confidence] is no longer required — it was in the required tuple, so any
   legacy row missing it was DROPPED (the R5 row-loss). Removing it both deletes
   the dead field and stops dropping confidence-less rows. The dead JSON keys
   (confidence/access_count/last_accessed/stale_factor/expected_lifetime_cycles)
   that legacy v3 rows still carry are simply ignored — Yojson decoders skip
   unknown keys, so old rows round-trip to the slim shape on the next rewrite. *)
let fact_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field "claim" fields
       , json_string_field "category" fields
       , List.assoc_opt "source" fields )
     with
     | Some claim, Some category_str, Some source_json ->
       (match provenance_event_of_json source_json with
        | Some source ->
          (* DET-OK: absent first_seen defaults to epoch for migration safety. *)
          let first_seen = Option.value (json_float_field "first_seen" fields) ~default:0.0 in
          let valid_until = json_float_field "valid_until" fields in
          let last_verified_at = json_float_field "last_verified_at" fields in
          (* DET-OK: absent observed_by defaults to empty (Tier-1 / legacy facts). *)
          let observed_by =
            Option.value (json_string_list_field "observed_by" fields) ~default:[]
          in
          (* Round-trip only: classification happens once at the producer boundary
             (Keeper_librarian.fact_of_json), so a legacy row with no key reads as
             [None] here rather than being re-parsed — keeps the
             external_ref=Some ⟹ valid_until=Some invariant a producer property. *)
          let external_ref =
            match List.assoc_opt "external_ref" fields with
            | Some json -> external_ref_of_json json
            | None -> None
          in
          Some
            { claim
            ; (* Parse-once at the read boundary; legacy free-string categories
                 on disk map to their arm or [Unknown] (graceful-degrade). *)
              category = category_of_string category_str
            ; source
            ; observed_by
            ; external_ref
            ; first_seen
            ; valid_until
            ; last_verified_at
            ; schema_version =
                (* DET-OK: default to current schema for forward compatibility. *)
                Option.value (json_string_field "schema_version" fields) ~default:schema_version
            }
        | None -> None)
     | (Some _, Some _, None)
     | (Some _, None, _)
     | (None, _, _) -> None)
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
