(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring. *)

(* RFC-0259: bumped from "rfc0231-v2" when the volatile [external_ref] field and
   the read-side re-derivation of [valid_until] for referenced claims landed. New
   rows carry this; legacy rows keep their stored version and decode unchanged. *)
let schema_version = "rfc0259-v1"

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

(* RFC-0259 §3.2(b): an external-state reference named by a claim. A claim that
   names a PR/issue/task id is about *volatile* external state — true when
   extracted, false once the world moves on — so [fact_valid_until] gives it a
   finite horizon rather than letting it persist as a durable, immortal fact
   (RFC-0259 §2.2 gap #4). [kind] is a closed sum so the future grounding
   reconciler (RFC-0259 P2/P3) must classify every kind at compile time. *)
type external_ref_kind =
  | Pr
  | Issue
  | Task

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

type external_ref =
  { kind : external_ref_kind
  ; id : string
  }

(* Parse-don't-validate, once, at the producer boundary. CONSERVATIVE: only an
   explicit marker counts — "PR #123", "pull request #123", "pull/123",
   "issue #123", "issues/123", "PK-1234". A bare "#123" with no keyword is prose
   ("step #3"), not a reference, and yields [None] so the claim keeps its normal
   durable path. Over-matching would wrongly give a durable fact a finite TTL, so
   the bar is deliberately high; under-matching only leaves the pre-RFC status quo
   for that one claim. Returns the earliest-positioned reference when a claim
   names several. *)
let external_ref_of_claim claim =
  let lc = String.lowercase_ascii claim in
  let n = String.length lc in
  let is_digit c = c >= '0' && c <= '9' in
  let is_alpha c = c >= 'a' && c <= 'z' in
  let digit_run i =
    let j = ref i in
    while !j < n && is_digit lc.[!j] do
      incr j
    done;
    String.sub lc i (!j - i)
  in
  (* The alphabetic word ending just before [i] (whitespace skipped), with its
     start index, so a two-word keyword ("pull request") can be recognized. *)
  let word_before i =
    let j = ref (i - 1) in
    while !j >= 0 && (lc.[!j] = ' ' || lc.[!j] = '\t') do
      decr j
    done;
    let e = !j + 1 in
    while !j >= 0 && is_alpha lc.[!j] do
      decr j
    done;
    String.sub lc (!j + 1) (e - (!j + 1)), !j + 1
  in
  let at_word_start i = i = 0 || not (is_alpha lc.[i - 1]) in
  let best = ref None in
  let consider pos kind id =
    if String.length id > 0
    then (
      match !best with
      | Some (p, _, _) when p <= pos -> ()
      | Some _ | None -> best := Some (pos, kind, id))
  in
  (* (1) "#<digits>" anchored on a recognized preceding keyword. *)
  for i = 0 to n - 1 do
    if lc.[i] = '#'
    then (
      let id = digit_run (i + 1) in
      if String.length id > 0
      then (
        let w1, w1_start = word_before i in
        match w1 with
        | "pr" | "pull" -> consider w1_start Pr id
        | "issue" | "issues" -> consider w1_start Issue id
        | "request" ->
          let w2, w2_start = word_before w1_start in
          if String.equal w2 "pull" then consider w2_start Pr id
        | _ -> ()))
  done;
  (* (2) slash form "pull/<digits>" / "issues/<digits>" and Jira "pk-<digits>". *)
  let scan_prefix kw sep kind ~keep_key =
    let klen = String.length kw in
    for i = 0 to n - klen - 1 do
      if at_word_start i && String.equal (String.sub lc i klen) kw && lc.[i + klen] = sep
      then (
        let id = digit_run (i + klen + 1) in
        if String.length id > 0
        then (
          let id =
            if keep_key
            then String.uppercase_ascii kw ^ String.make 1 sep ^ id
            else id
          in
          consider i kind id))
    done
  in
  scan_prefix "pull" '/' Pr ~keep_key:false;
  scan_prefix "issues" '/' Issue ~keep_key:false;
  scan_prefix "issue" '/' Issue ~keep_key:false;
  scan_prefix "pk" '-' Task ~keep_key:true;
  match !best with
  | Some (_, kind, id) -> Some { kind; id }
  | None -> None
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

(* RFC-0259 §3.2: a claim that names external state cannot be durable — its truth
   is only as good as its last verification. Until the grounding reconciler (P2)
   re-checks it against GitHub, a finite horizon bounds how long an un-re-observed
   external-state claim survives. Same shape as [ephemeral_ttl_seconds] (a TIME,
   not a score); 1 day matches the ephemeral horizon. *)
let volatile_external_ttl_seconds = 86_400.0

(* RFC-0259 §3.2: the write-side [valid_until] producer. An [external_ref] claim is
   never durable — it gets the volatile horizon regardless of category, so a
   PR-status claim mislabeled [Fact] (the #21363 shape) or [Unknown] still decays.
   [external_ref] is checked first so it takes precedence; otherwise the category
   decides (only [Ephemeral] is finite). *)
let fact_valid_until ~now ~external_ref category =
  match external_ref with
  | Some _ -> Some (now +. volatile_external_ttl_seconds)
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
  ; external_ref : external_ref option
    (* RFC-0259 §3.2(b): set by the producer ([external_ref_of_claim]) when the
       claim names a PR/issue/task id. Orthogonal to [category] (a [Constraint]
       can reference a PR). Drives [fact_valid_until]: a referenced claim is
       volatile, never durable. Omitted from JSON when [None]. *)
  ; source : provenance_event
  ; observed_by : string list
    (* RFC-0244 Tier 2 (shared semantic store) ONLY: the sorted set of distinct
       keeper ids that have corroborated this claim. Empty for Tier-1 per-keeper
       facts — a single keeper's store has no distinct keeper-source to track, so
       it is omitted from their JSON. *)
  ; first_seen : float
  ; valid_until : float option
  ; last_verified_at : float option
  ; schema_version : string
  }

let fact_is_current ~now (fact : fact) =
  match fact.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

(* The time a fact was last known good: [last_verified_at] if set, else
   [first_seen] (a never-re-verified fact is as old as its extraction). The SSOT
   anchor for "how stale is this claim": the reconciler measures the re-ground
   horizon from it, and recall measures staleness/ordering and unverified-volatile
   suppression from it — they share this one definition rather than each inlining
   the match, so a future change to the anchor rule (e.g. a [last_verified_at >=
   first_seen] guard) cannot make those paths drift. *)
let reference_time (f : fact) =
  match f.last_verified_at with
  | Some t -> t
  | None -> f.first_seen
;;

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
    [ "kind", `String (external_ref_kind_to_string r.kind); "id", `String r.id ]
;;

let external_ref_of_json = function
  | Some (`Assoc fields) ->
    (match json_string_field "kind" fields, json_string_field "id" fields with
     | Some kind_s, Some id ->
       (match external_ref_kind_of_string kind_s with
        | Some kind -> Some { kind; id }
        | None -> None)
     | (Some _, None) | (None, Some _) | (None, None) -> None)
  | Some (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
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
    (* Tier-1 facts carry [], which is omitted so per-keeper stores stay
       byte-identical to pre-RFC-0244; only Tier-2 shared facts emit it. *)
    @ (match f.observed_by with
       | [] -> []
       | keepers -> [ "observed_by", `List (List.map (fun k -> `String k) keepers) ])
    (* RFC-0259 §3.2(b): omitted when [None] so claims with no external ref stay
       byte-identical to pre-RFC-0259 rows (no drift). Appended last to keep the
       existing key order stable for the snapshot fingerprint. *)
    @ (match f.external_ref with
       | Some r -> [ "external_ref", external_ref_to_json r ]
       | None -> [])
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
          let last_verified_at = json_float_field "last_verified_at" fields in
          (* RFC-0259 §3.2(b): the external ref is stored once written, but legacy
             rows carry none. Re-derive it from the claim on read (deterministic,
             idempotent) so an already-persisted volatile claim (e.g. a stale
             "PR #N is OPEN") is reclassified without waiting for a rewrite. *)
          let external_ref =
            match external_ref_of_json (List.assoc_opt "external_ref" fields) with
            | Some _ as r -> r
            | None -> external_ref_of_claim claim
          in
          (* When a re-derived volatile row also lacks a [valid_until], anchor the
             horizon to [first_seen] (on disk) so a row extracted days ago is
             already past horizon — the recall TTL filter and GC drop it on the
             next pass, closing RFC-0259 §2.2 gap #4 for existing rows, not just
             new ones. A row that already stores a [valid_until] keeps it. *)
          let valid_until =
            match json_float_field "valid_until" fields, external_ref with
            | None, Some _ -> Some (first_seen +. volatile_external_ttl_seconds)
            | None, None -> None
            | (Some _ as v), _ -> v
          in
          (* DET-OK: absent observed_by defaults to empty (Tier-1 / legacy facts). *)
          let observed_by =
            Option.value (json_string_list_field "observed_by" fields) ~default:[]
          in
          Some
            { claim
            ; (* Parse-once at the read boundary; legacy free-string categories
                 on disk map to their arm or [Unknown] (graceful-degrade). *)
              category = category_of_string category_str
            ; external_ref
            ; source
            ; observed_by
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
