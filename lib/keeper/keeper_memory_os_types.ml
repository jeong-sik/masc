(** Keeper_memory_os_types — typed schema for the tiered Memory OS.

    Facts are immutable, versioned claims extracted by the librarian.
    Episodes group related facts with a short summary and metadata for
    downstream retention scoring. *)

(* Kept at the RFC-0259 schema label for on-disk compatibility. The forced
   external-ref classifier from that rollout is retired: current decoders ignore
   stored [external_ref] and never re-derive it from claim prose. *)
let schema_version = "rfc0259-v1"

(* RFC-0244 Tier 2: the shared semantic store reuses the per-keeper IO/codec
   under a reserved id. A leading underscore is not produced by keeper naming, so
   no real keeper collides with its file (keepers/_shared.facts.jsonl); the
   consolidator additionally filters this id out of its source keeper list. *)
let shared_store_id = "_shared"

(* Canonical JSON wire keys for Memory OS persistence and librarian ingestion.
   The schema module owns these strings so the parser, retry prompt, persistence
   codec, and tests cannot drift by maintaining parallel literal sets. *)
let wire_field_trace_id = "trace_id"
let wire_field_turn = "turn"
let wire_field_tool_call_id = "tool_call_id"
let wire_field_claim = "claim"
let wire_field_category = "category"
let wire_field_source = "source"
let wire_field_first_seen = "first_seen"
let wire_field_valid_until = "valid_until"
let wire_field_last_verified_at = "last_verified_at"
let wire_field_observed_by = "observed_by"
let wire_field_claim_id = "claim_id"
let wire_field_claim_kind = "claim_kind"
let wire_field_schema_version = "schema_version"
let wire_field_generation = "generation"
let wire_field_episode_summary = "episode_summary"
let wire_field_claims = "claims"
let wire_field_open_items = "open_items"
let wire_field_constraints = "constraints"
let wire_field_preserved_tool_refs = "preserved_tool_refs"
let wire_field_source_turn = "source_turn"
let wire_field_source_tool_call_id = "source_tool_call_id"
let wire_field_source_turn_range = "source_turn_range"
let wire_field_lo = "lo"
let wire_field_hi = "hi"
let wire_field_created_at = "created_at"
let wire_field_terminal_marker = "terminal_marker"

let wire_librarian_episode_fields =
  [ wire_field_episode_summary
  ; wire_field_claims
  ; wire_field_open_items
  ; wire_field_constraints
  ; wire_field_preserved_tool_refs
  ]
;;

let wire_librarian_claim_fields =
  [ wire_field_claim
  ; wire_field_category
  ; wire_field_source_turn
  ; wire_field_source_tool_call_id
  ; wire_field_claim_id
  ; wire_field_claim_kind
  ]
;;

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

let all_categories =
  (* Prompt-significant order: keep durable/common tokens first so retry nudges
     bias toward normal memory facts before narrower bookkeeping categories. *)
  [ Fact
  ; Preference
  ; Blocker
  ; Goal
  ; Constraint
  ; Ephemeral
  ; Validated_approach
  ; Lesson
  ; Code_change
  ]
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

(* RFC-0285 §3.1: producer-emitted origin tag, orthogonal to [category] (a [Lesson]
   can be a self-observation). A closed sum classified ONCE at the librarian write
   boundary — not a read-time string match (the project's workaround signature #2).
   An absent/unrecognized tag yields [None] in [claim_kind_of_string]. For normal
   categories that routes to the durable pre-RFC path (safe), never to
   wrong-volatile; legacy category migrations may reject invalid structured tags
   instead of guessing. *)
type claim_kind =
  | Self_observation (* transient first-person agent state: idle, looping, tool-timeout *)
  | External_state (* about the world/PR/issue; verifiable elsewhere *)
  | Durable_knowledge (* timeless rule / lesson independent of transient state *)
  | Diagnostic (* system-authored diagnostic artifact; not prompt-recallable knowledge *)

let claim_kind_to_string = function
  | Self_observation -> "self_observation"
  | External_state -> "external_state"
  | Durable_knowledge -> "durable_knowledge"
  | Diagnostic -> "diagnostic"
;;

let all_claim_kinds =
  [ Self_observation; External_state; Durable_knowledge; Diagnostic ]
;;

let librarian_claim_kinds =
  [ Self_observation; External_state; Durable_knowledge ]
;;

let claim_kind_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "self_observation" -> Some Self_observation
  | "external_state" -> Some External_state
  | "durable_knowledge" -> Some Durable_knowledge
  | "diagnostic" -> Some Diagnostic
  | _ -> None
;;

type persisted_claim_kind =
  | Persisted_claim_kind_absent
  | Persisted_claim_kind_valid of claim_kind
  | Persisted_claim_kind_invalid

let persisted_claim_kind_of_json fields =
  match List.assoc_opt wire_field_claim_kind fields with
  | None -> Persisted_claim_kind_absent
  | Some (`String raw) ->
    (match claim_kind_of_string raw with
     | Some claim_kind -> Persisted_claim_kind_valid claim_kind
     | None -> Persisted_claim_kind_invalid)
  | Some _ -> Persisted_claim_kind_invalid
;;

let legacy_external_state_category = claim_kind_to_string External_state

let category_and_claim_kind_of_persisted_row ~category_str ~claim_kind =
  match category_str with
  | s when String.equal s legacy_external_state_category ->
    (match claim_kind with
     | Persisted_claim_kind_absent
     | Persisted_claim_kind_valid External_state
     | Persisted_claim_kind_valid Self_observation
     | Persisted_claim_kind_valid Durable_knowledge
     | Persisted_claim_kind_valid Diagnostic -> Some (Fact, Some External_state)
     | Persisted_claim_kind_invalid -> None)
  | _ ->
    let claim_kind =
      match claim_kind with
      | Persisted_claim_kind_absent | Persisted_claim_kind_invalid -> None
      | Persisted_claim_kind_valid claim_kind -> Some claim_kind
    in
    Some (category_of_string category_str, claim_kind)
;;

(* Exhaustive category promotability. This is a necessary category whitelist for
   durable promotion decisions, not the complete `_shared` gate. The consolidator
   additionally requires [is_outcome_positive_for_shared_promotion] so repeated
   plain [Fact]/[Constraint] rows remain keeper-local until outcome evaluation
   upgrades them. Exhaustive match (not a runtime [category list]) so a future
   durable kind must be classified here at compile time rather than silently
   defaulting to non-promotable, the no-silent-omission property RFC-0247 §2.5
   argues for over the prompt-suppression approach. *)
let is_promotable = function
  | Fact | Constraint | Validated_approach | Lesson -> true
  | Code_change | Preference | Blocker | Goal | Ephemeral | Unknown _ -> false
;;

(* Shared Tier-2 promotion is stricter than generic category promotability:
   repeated plain facts/constraints stay keeper-local until outcome evaluation
   turns them into a validated approach or lesson.
   TODO(#22447): replace this category proxy with explicit recall-outcome
   metadata once the local outcome evaluator is joined into fact metadata. *)
let is_outcome_positive_for_shared_promotion = function
  | Validated_approach | Lesson -> true
  | Code_change | Fact | Preference | Blocker | Goal | Constraint | Ephemeral | Unknown _ ->
    false
;;

(* RFC-0259 §3.2(b): an explicitly structured reference to verifiable external
   state. This is deliberately NOT inferred from claim prose: a claim may mention
   "PR #123" as history, context, or durable lesson text, and code cannot reliably
   decide that it is asserting current external state. *)
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

(* RFC-0285 §3.4: transient first-person self-state (idle/looping/tool-timeout) is
   short-lived and noisy, so it gets a tighter horizon than ordinary
   coordination boilerplate. Not so short a legitimate short-lived self-state
   ("waiting on this block") vanishes within the same turn. A TIME, not a score;
   named, not magic; tune in cycles (RFC §7). *)
let self_observation_ttl_seconds = 3_600.0

(* RFC-0259 P7 (2026-06-30): [External_state] claims describe volatile external
   reality (a task's status, a blocker, a PR state) that becomes false when the
   world moves on. Without a finite horizon they never expire (the category arm
   below returns [None] for Fact/Constraint/...) and [reobserve_fact] keeps
   refreshing [last_verified_at] on mere LLM re-assertion, so a claim about a
   cancelled task is re-injected into recall indefinitely. A horizon keyed on the
   producer-emitted [claim_kind] tag — NOT on claim prose; prose-inferred
   external_ref grounding stays superseded per the 2026-06-25 note — bounds how
   long such a claim can outlive its truth. Longer than a self-observation:
   external facts change on a slower cadence than a keeper's moment-to-moment
   state. A TIME, not a score; named, not magic; tune in cycles (RFC §7). *)
let external_state_ttl_seconds = 6.0 *. 3_600.0

let external_state_valid_until_from_first_seen ~first_seen =
  first_seen +. external_state_ttl_seconds
;;

(* RFC-0285 §3.4: the write-side [valid_until] producer. A [Self_observation]
   claim_kind gets the shortest finite horizon regardless of category; an
   [External_state] claim gets a longer finite horizon (RFC-0259 P7). Otherwise
   the category decides (only [Ephemeral] is finite). [external_ref] is accepted for
   call-site compatibility but does not affect retention; Memory OS provides refs
   as context, not as a code-enforced status classifier. *)
let fact_valid_until ~now ~external_ref:_ ~claim_kind category =
  match claim_kind with
  | Some Self_observation -> Some (now +. self_observation_ttl_seconds)
  | Some External_state -> Some (external_state_valid_until_from_first_seen ~first_seen:now)
  | Some Durable_knowledge | Some Diagnostic | None ->
    category_valid_until ~now category
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
    (* Historical RFC-0259 field retained for source compatibility. Current Memory
       OS writes/reads/dashboard projection do not serialize it: claim text is
       model context, not a machine-readable status assertion. *)
  ; claim_kind : claim_kind option
    (* RFC-0285 §3.1: producer ([librarian]) -emitted origin tag, parallel to
       [external_ref] and orthogonal to [category]. Drives [fact_valid_until]
       ([Self_observation] gets a short finite horizon) and gates promotion
       ([Self_observation] never crosses keepers — consolidator [eligible]). Omitted
       from JSON when [None]; a missing tag degrades to the durable pre-RFC path. *)
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
  ; claim_id : string option
    (* RFC-0259 §3.7 (P6): a producer (librarian) -emitted stable slug for the
       claim's CONCLUSION (not its wording), so a reworded re-extraction of the
       same conclusion reuses the id and UPSERTs, while a changed conclusion gets
       a new id and stays a distinct row. Omitted from JSON when [None]; legacy
       rows and id-less claims fall back to [normalize_claim] in [claim_identity].
       Keyed by the librarian's judgment, not a classifier we author. *)
  }

let fact_effective_valid_until (fact : fact) =
  match fact.valid_until, fact.claim_kind with
  | Some _ as valid_until, _ -> valid_until
  | None, Some External_state ->
    Some (external_state_valid_until_from_first_seen ~first_seen:fact.first_seen)
  | None, _ -> None
;;

(* Staleness ceiling (seconds) for facts without an explicit valid_until
   horizon. Tied to [Keeper_memory_os_policy.max_consensus_staleness] so that
   read-path ([fact_is_current]) and write-path ([not_stale]) agree on when
   unbounded facts expire. *)
let fact_staleness_ceiling = 86400.

let fact_is_current ~now (fact : fact) =
  match fact_effective_valid_until fact with
  | Some ts -> ts >= now
  | None ->
    (* Mirror [not_stale] in consolidator.ml: use last_verified_at when
       available (shared facts), fall back to first_seen + ceiling. *)
    let deadline =
      match fact.last_verified_at with
      | Some t -> t +. fact_staleness_ceiling
      | None -> fact.first_seen +. fact_staleness_ceiling
    in
    now <= deadline
;;

let librarian_unstructured_fallback_claim_prefix =
  "unstructured_note: librarian parse fallback"
;;

let librarian_unstructured_fallback_terminal_marker =
  "librarian_unstructured_fallback"
;;

let fact_prompt_recallable (fact : fact) =
  (* [claim_kind] is the sole recall-eligibility signal: current librarian
     extraction rejects unparseable structured output before persistence, while
     historical fallback diagnostics were tagged [Diagnostic]. Recall excludes
     diagnostics by type without string-matching [claim]. Rows lacking
     [claim_kind] are ordinary recallable facts; their [valid_until] horizon
     ([fact_is_current]) bounds any stale pre-[Diagnostic] rows still on disk. *)
  match fact.claim_kind with
  | Some Diagnostic -> false
  | Some Self_observation | Some External_state | Some Durable_knowledge -> true
  | None -> true
;;

(* RFC-0259 §3.6 (P5): split a fact list into (live, expired-at-[now]) on the
   effective-horizon boundary ([fact_is_current], i.e.
   [fact_effective_valid_until]). The cap path ([Keeper_memory_os_io.cap_facts]
   / [merge_and_cap_facts]) calls this so it drops expired rows on the SAME
   boundary the GC sweep uses ([Keeper_memory_os_gc.ttl_expired]), instead of
   leaving them on disk until the off-by-default 600s sweep happens to run.
   Facts with no effective horizon ([valid_until = None] and not a legacy
   [External_state] claim, RFC-0259 P7) are always live, so durable knowledge
   is never evicted here. This is retention-path determinism (cap and GC agree
   on the expiry boundary), not a new read-side filter — recall already drops
   expired rows via [fact_is_current]. *)
let partition_expired ~now (facts : fact list) =
  List.partition (fact_is_current ~now) facts
;;

(* The time a fact was last known good: [last_verified_at] if set, else
   [first_seen] (a never-re-verified fact is as old as its extraction). The SSOT
   anchor for "how stale is this claim": recall and dashboard user-model ordering
   share this one definition rather than each inlining the match, so a future
   change to the anchor rule (e.g. a [last_verified_at >= first_seen] guard)
   cannot make those paths drift. *)
let reference_time (f : fact) =
  match f.last_verified_at with
  | Some t -> t
  | None -> f.first_seen
;;

let fact_is_user_model (fact : fact) =
  match fact.category with
  | Preference | Constraint -> true
  | Blocker
  | Code_change
  | Ephemeral
  | Fact
  | Goal
  | Lesson
  | Validated_approach
  | Unknown _ -> false
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

let provenance_event_to_json (e : provenance_event) =
  let base =
    [ wire_field_trace_id, `String e.trace_id
    ; wire_field_turn, `Int e.turn
    ]
  in
  let tool =
    match e.tool_call_id with
    | Some id -> [ wire_field_tool_call_id, `String id ]
    | None -> []
  in
  `Assoc (base @ tool)
;;

let provenance_event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       json_string_field wire_field_trace_id fields, json_int_field wire_field_turn fields
     with
     | Some trace_id, Some turn ->
       let tool_call_id = json_string_field wire_field_tool_call_id fields in
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

let normalize_claim_id raw =
  let b = Buffer.create (String.length raw) in
  let pending_sep = ref false in
  let add_sep () =
    if Buffer.length b > 0 then pending_sep := true
  in
  let flush_sep () =
    if !pending_sep && Buffer.length b > 0 then Buffer.add_char b '-';
    pending_sep := false
  in
  String.iter
    (fun c ->
       match c with
       | 'A' .. 'Z' ->
         flush_sep ();
         Buffer.add_char b (Char.lowercase_ascii c)
       | 'a' .. 'z' | '0' .. '9' ->
         flush_sep ();
         Buffer.add_char b c
       | '-' | '_' | ' ' | '\t' | '\r' | '\n' -> add_sep ()
       | _ -> add_sep ())
    (String.trim raw);
  match Buffer.contents b with
  | "" -> None
  | id -> Some id
;;

(* RFC-0259 §3.7 (P6): the producer-identity dedup key. When the librarian emits a
   [claim_id] — a stable slug for the claim's CONCLUSION (not its wording) — that id
   is the key, so a reworded re-extraction of the same conclusion UPSERTs the one
   row (defect E) and inherits its [first_seen] anchor instead of resetting the
   volatile TTL (defect F), while a changed conclusion (e.g. "PR #N open" ->
   "PR #N merged") carries a different id and stays a distinct row. A claim with no
   [claim_id] (legacy row, or the model omitting it) falls back to the exact-text
   [normalize_claim] key = pre-P6 append behavior, so the degrade never over-merges.
   This is NOT a fuzzy / embedding / substring classifier: the id is the librarian's
   own judgment "is this the same conclusion?", surfaced as a typed key, not one we
   author here (RFC-0259 §3.7 and RFC-0247 §3 reject deriving it in code). This is
   the single dedup SSOT: the write upsert, recall dedup, GC dedup, and Tier-2
   consolidation MUST all key on this one function. *)
let claim_identity_of_claim_text claim = "claim:" ^ normalize_claim claim

let claim_identity (f : fact) =
  match Option.bind f.claim_id normalize_claim_id with
  | Some id -> "id:" ^ id
  | None -> claim_identity_of_claim_text f.claim
;;

let optional_float_field key = function
  | Some value -> [ key, `Float value ]
  | None -> []
;;

let fact_to_json f =
  let fields =
    [ wire_field_claim, `String f.claim
    ; wire_field_category, `String (category_to_string f.category)
    ; wire_field_source, provenance_event_to_json f.source
    ; wire_field_first_seen, `Float f.first_seen

    ; wire_field_schema_version, `String f.schema_version
    ]
    @ optional_float_field wire_field_valid_until f.valid_until
    @ optional_float_field wire_field_last_verified_at f.last_verified_at
    (* Tier-1 facts carry [], which is omitted so per-keeper stores stay
       byte-identical to pre-RFC-0244; only Tier-2 shared facts emit it. *)
    @ (match f.observed_by with
       | [] -> []
       | keepers ->
         [ wire_field_observed_by, `List (List.map (fun k -> `String k) keepers) ])
    (* RFC-0259 §3.7 (P6): the producer-emitted conclusion slug. Omitted when
       [None] so legacy / id-less rows stay byte-identical, and appended LAST to
       keep the prior key order stable for the snapshot fingerprint. *)
    @ (match Option.bind f.claim_id normalize_claim_id with
       | Some id -> [ wire_field_claim_id, `String id ]
       | None -> [])
    (* RFC-0285 §3.1: the producer-emitted origin tag. Omitted when [None] so legacy
       rows stay byte-identical, appended LAST to keep the prior key order stable for
       the snapshot fingerprint. *)
    @ (match f.claim_kind with
       | Some k -> [ wire_field_claim_kind, `String (claim_kind_to_string k) ]
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
       ( json_string_field wire_field_claim fields
       , json_string_field wire_field_category fields
       , List.assoc_opt wire_field_source fields )
     with
     | Some claim, Some category_str, Some source_json ->
       (match provenance_event_of_json source_json with
        | Some source ->
          (* DET-OK: absent first_seen defaults to epoch for migration safety. *)
          let first_seen =
            Option.value (json_float_field wire_field_first_seen fields) ~default:0.0
          in
          let last_verified_at = json_float_field wire_field_last_verified_at fields in
          (* Ignore persisted external_ref metadata. Older rows may carry refs that
             were inferred from prose; preserving them would keep the old forced
             classifier alive. The claim remains model context. *)
          let external_ref = None in
          let valid_until = json_float_field wire_field_valid_until fields in
          (* DET-OK: absent observed_by defaults to empty (Tier-1 / legacy facts). *)
          let observed_by =
            Option.value (json_string_list_field wire_field_observed_by fields) ~default:[]
          in
          (* RFC-0259 §3.7 (P6): absent on legacy / id-less rows, defaulting to
             [None] so [claim_identity] falls back to [normalize_claim] for them. *)
          let claim_id =
            Option.bind (json_string_field wire_field_claim_id fields) normalize_claim_id
          in
          let claim_kind = persisted_claim_kind_of_json fields in
          (match category_and_claim_kind_of_persisted_row ~category_str ~claim_kind with
           | None -> None
           | Some (category, claim_kind) ->
             Some
               { claim
               ; (* Parse-once at the read boundary; legacy free-string categories
                    on disk map to their arm or [Unknown] (graceful-degrade). The
                    legacy [external_state] category is an exact structured token,
                    so decode it into the modern [Fact] + [claim_kind=External_state]
                    shape rather than inferring from claim prose. *)
                 category
               ; external_ref
               ; claim_kind
               ; source
               ; observed_by
               ; first_seen
               ; valid_until
               ; last_verified_at
               ; schema_version =
                   (* DET-OK: default to current schema for forward compatibility. *)
                   Option.value
                     (json_string_field wire_field_schema_version fields)
                     ~default:schema_version
               ; claim_id
               })
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
      [ wire_field_source_turn_range
      , `Assoc [ wire_field_lo, `Int lo; wire_field_hi, `Int hi ]
      ]
    | None -> []
  in
  `Assoc
    ([ wire_field_trace_id, `String e.trace_id
     ; wire_field_generation, `Int e.generation
     ; wire_field_episode_summary, `String e.episode_summary
     ; wire_field_claims, `List (List.map fact_to_json e.claims)
     ; wire_field_open_items, `List (List.map (fun s -> `String s) e.open_items)
     ; wire_field_constraints, `List (List.map (fun s -> `String s) e.constraints)
     ; ( wire_field_preserved_tool_refs
       , `List (List.map (fun s -> `String s) e.preserved_tool_refs) )
     ; wire_field_created_at, `Float e.created_at
     ; wire_field_schema_version, `String e.schema_version
     ]
     @ range_json
     @ optional_float_field wire_field_valid_until e.valid_until
     @ (match e.terminal_marker with
        | Some marker -> [ wire_field_terminal_marker, `String marker ]
        | None -> []))
;;

let episode_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field wire_field_trace_id fields
       , json_int_field wire_field_generation fields
       , json_string_field wire_field_episode_summary fields
       , List.assoc_opt wire_field_claims fields )
     with
     | Some trace_id, Some generation, Some episode_summary, Some (`List claim_items) ->
       let claims = List.filter_map fact_of_json claim_items in
       (* DET-OK: optional list fields default to empty. *)
       let open_items =
         Option.value (json_string_list_field wire_field_open_items fields) ~default:[]
       in
       (* DET-OK: optional list fields default to empty. *)
       let constraints =
         Option.value (json_string_list_field wire_field_constraints fields) ~default:[]
       in
       (* DET-OK: optional list fields default to empty. *)
       let preserved_tool_refs =
         Option.value
           (json_string_list_field wire_field_preserved_tool_refs fields)
           ~default:[]
       in
       let source_turn_range =
         match List.assoc_opt wire_field_source_turn_range fields with
         | Some (`Assoc r) ->
           (match json_int_field wire_field_lo r, json_int_field wire_field_hi r with
            | Some lo, Some hi -> Some (lo, hi)
            | (Some _, None) | (None, Some _) | (None, None) -> None)
         | Some (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _)
         | None ->
           None
       in
       (* DET-OK: absent created_at defaults to epoch for migration safety. *)
       let created_at =
         Option.value (json_float_field wire_field_created_at fields) ~default:0.0
       in
       (* DET-OK: legacy episodes had no TTL or terminal marker. *)
       let valid_until = json_float_field wire_field_valid_until fields in
       let terminal_marker = json_string_field wire_field_terminal_marker fields in
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
             Option.value
               (json_string_field wire_field_schema_version fields)
               ~default:schema_version
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
