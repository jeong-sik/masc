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

(* RFC-0285 §3.1: producer-emitted origin tag, orthogonal to [category] (a [Lesson]
   can be a self-observation). A closed sum classified ONCE at the librarian write
   boundary — not a read-time string match (the project's workaround signature #2).
   An absent/unrecognized tag yields [None] in [claim_kind_of_string], which routes
   to the durable pre-RFC path (safe), never to wrong-volatile. *)
type claim_kind =
  | Self_observation (* transient first-person agent state: idle, looping, tool-timeout *)
  | External_state (* about the world/PR/issue; verifiable elsewhere *)
  | Durable_knowledge (* timeless rule / lesson independent of transient state *)

let claim_kind_to_string = function
  | Self_observation -> "self_observation"
  | External_state -> "external_state"
  | Durable_knowledge -> "durable_knowledge"
;;

let claim_kind_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "self_observation" -> Some Self_observation
  | "external_state" -> Some External_state
  | "durable_knowledge" -> Some Durable_knowledge
  | _ -> None
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

(* RFC-0285 §3.4: transient first-person self-state (idle/looping/tool-timeout) is
   MORE volatile than external state — a PR's status changes slowly, "am I idle"
   changes every turn — so it gets a horizon SHORTER than the external one to quiet
   the self-observation echo faster. Not so short a legitimate short-lived self-state
   ("waiting on this block") vanishes within the same turn. A TIME, not a score;
   named, not magic; tune in cycles (RFC §7). *)
let self_observation_ttl_seconds = 3_600.0

(* RFC-0259 §3.2 / RFC-0285 §3.4: the write-side [valid_until] producer. Precedence:
   a [Self_observation] claim_kind gets the shortest finite horizon regardless of
   category or external_ref (it is keeper-local transient state); otherwise an
   [external_ref] claim gets the volatile horizon (so a PR-status claim mislabeled
   [Fact] still decays); otherwise the category decides (only [Ephemeral] is finite).
   [External_state]/[Durable_knowledge] tags carry no horizon of their own — the
   external_ref / category arms already cover them. *)
let fact_valid_until ~now ~external_ref ~claim_kind category =
  match claim_kind with
  | Some Self_observation -> Some (now +. self_observation_ttl_seconds)
  | Some External_state | Some Durable_knowledge | None ->
    (match external_ref with
     | Some _ -> Some (now +. volatile_external_ttl_seconds)
     | None -> category_valid_until ~now category)
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

let fact_is_current ~now (fact : fact) =
  match fact.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

(* RFC-0259 §3.6 (P5): split a fact list into (live, expired-at-[now]) on the
   typed [valid_until] boundary. The cap path ([Keeper_memory_os_io.cap_facts] /
   [merge_and_cap_facts]) calls this so it drops expired rows on the SAME
   boundary the GC sweep uses ([Keeper_memory_os_gc.ttl_expired]), instead of
   leaving them on disk until the off-by-default 600s sweep happens to run.
   Durable facts ([valid_until = None]) are always live, so this never evicts
   durable knowledge. This is retention-path determinism (cap and GC agree on
   what [valid_until] means), not a new read-side filter — recall already drops
   expired rows via [fact_is_current]. *)
let partition_expired ~now (facts : fact list) =
  List.partition (fact_is_current ~now) facts
;;

(* The time a fact was last known good: [last_verified_at] if set, else
   [first_seen] (a never-re-verified fact is as old as its extraction). The SSOT
   anchor for "how stale is this claim": the reconciler, recall, and dashboard
   user-model ordering share this one definition rather than each inlining the
   match, so a future change to the anchor rule (e.g. a [last_verified_at >=
   first_seen] guard) cannot make those paths drift. *)
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
let claim_identity (f : fact) =
  match Option.bind f.claim_id normalize_claim_id with
  | Some id -> "id:" ^ id
  | None -> "claim:" ^ normalize_claim f.claim
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
    (* RFC-0259 §3.7 (P6): the producer-emitted conclusion slug. Omitted when
       [None] so legacy / id-less rows stay byte-identical, and appended LAST to
       keep the prior key order stable for the snapshot fingerprint. *)
    @ (match Option.bind f.claim_id normalize_claim_id with
       | Some id -> [ "claim_id", `String id ]
       | None -> [])
    (* RFC-0285 §3.1: the producer-emitted origin tag. Omitted when [None] so legacy
       rows stay byte-identical, appended LAST to keep the prior key order stable for
       the snapshot fingerprint. *)
    @ (match f.claim_kind with
       | Some k -> [ "claim_kind", `String (claim_kind_to_string k) ]
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
          (* RFC-0259 §3.7 (P6): absent on legacy / id-less rows, defaulting to
             [None] so [claim_identity] falls back to [normalize_claim] for them. *)
          let claim_id = Option.bind (json_string_field "claim_id" fields) normalize_claim_id in
          (* RFC-0285 §3.1: absent on legacy rows -> [None] (durable path). Closed sum,
             so an unrecognized string also yields [None] (graceful-degrade). The
             write-side [valid_until] is preserved as-is above; legacy self-observation
             rows are not retrofitted a horizon (RFC §5 non-goal). *)
          let claim_kind = Option.bind (json_string_field "claim_kind" fields) claim_kind_of_string in
          Some
            { claim
            ; (* Parse-once at the read boundary; legacy free-string categories
                 on disk map to their arm or [Unknown] (graceful-degrade). *)
              category = category_of_string category_str
            ; external_ref
            ; claim_kind
            ; source
            ; observed_by
            ; first_seen
            ; valid_until
            ; last_verified_at
            ; schema_version =
                (* DET-OK: default to current schema for forward compatibility. *)
                Option.value (json_string_field "schema_version" fields) ~default:schema_version
            ; claim_id
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
