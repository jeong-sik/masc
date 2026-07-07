(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files. *)

open Keeper_memory_os_types

let default_max_facts = Keeper_memory_os_policy.recall_default_max_facts
let default_max_episodes = Keeper_memory_os_policy.recall_default_max_episodes

(* RFC-0244 Tier 2: how many shared-semantic facts to append after the keeper's
   own (private-precedence) facts. Kept small so the communal tier informs
   without crowding out keeper-local memory. *)
let default_max_shared_facts = Keeper_memory_os_policy.recall_default_max_shared_facts
let episode_tail_scan = Keeper_memory_os_policy.recall_episode_tail_scan
let max_fact_text_len = 260
let max_episode_text_len = 360
let max_atom_len = 48

let rec take n xs =
  if n <= 0
  then []
  else (
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest)
;;

let truncate ~max_len s =
  if max_len <= 0
  then ""
  else if String.length s <= max_len
  then s
  else String.sub s 0 (max 0 (max_len - 3)) ^ "..."
;;

let sanitize_text ~max_len text =
  match Keeper_run_prompt.safe_memory_fragment text with
  | None -> ""
  | Some safe ->
    safe
    |> String.split_on_char '\n'
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
    |> String.concat " "
    |> truncate ~max_len
;;

let sanitize_atom text =
  sanitize_text ~max_len:max_atom_len text
  |> String.map (function
    | '\t' | '\r' | '\n' -> ' '
    | c -> c)
;;

type unavailable_reason =
  | Read_error
  | Prompt_render_error

let unavailable_reason_to_label = function
  | Read_error -> "read_error"
  | Prompt_render_error -> "prompt_render_error"
;;

let record_unavailable reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryOsRecallUnavailable)
    ~labels:[ "reason", unavailable_reason_to_label reason ]
    ()
;;

let episode_is_current ~now (episode : episode) =
  match episode.valid_until with
  | None -> true
  | Some ts -> ts >= now
;;

(* Staleness horizon: a fact whose truth anchor is older than this is annotated
   so the reader re-verifies before asserting it as live. One day mirrors the
   ephemeral TTL horizon in [Keeper_memory_os_types]. *)
let staleness_note_seconds = 86_400.0

(* Coarse natural-language age. The prior recall line printed [stale=%.2f] from
   the [stale_factor] field, but no keeper producer ever writes a non-zero
   stale_factor (RFC-0244 staleness lives in [last_verified_at] / truth-recency),
   so it rendered a constant [stale=0.00] that falsely signalled "fresh" on facts
   of any age. A raw float also fails to trigger an LLM's staleness reasoning the
   way a worded age does — the reader skips [stale=0.00] but reads "unverified
   12d". So derive age from the truth anchor and render it in words. *)
let humanize_age seconds =
  let seconds = Float.max 0.0 seconds in
  if seconds >= 86_400.0
  then Printf.sprintf "%dd" (int_of_float (seconds /. 86_400.0))
  else if seconds >= 3_600.0
  then Printf.sprintf "%dh" (int_of_float (seconds /. 3_600.0))
  else Printf.sprintf "%dm" (int_of_float (seconds /. 60.0))
;;

(* "" when the fact is recent enough that an age note would be noise (the
   claude-code memoryAge insight: warn only past a threshold). Otherwise a
   self-delimited bracket distinguishing never-verified facts (anchored on
   [first_seen]) from facts confirmed long ago (anchored on [last_verified_at]). *)
let staleness_marker ~now (fact : fact) =
  let age = now -. reference_time fact in
  if age < staleness_note_seconds
  then ""
  else (
    let age_text = humanize_age age in
    match fact.last_verified_at with
    | Some _ -> Printf.sprintf " [stale: last verified %s ago — verify]" age_text
    | None -> Printf.sprintf " [stale: unverified, seen %s ago — verify]" age_text)
;;

(* RFC-0247 (purge): the recall line carries the fact's *structure* — category
   (a typed decision), provenance turn, and the worded staleness marker — but no
   number. The prior line printed [confidence=%.2f score=%.3f]; both were score
   machinery. The reader (an LLM) judges relevance and freshness from the claim
   text and the staleness marker, not from a rank the producer can't justify. *)
let render_fact ~now fact =
  let source = fact.source in
  Printf.sprintf
    "- [category=%s turn=%d]%s %s"
    (sanitize_atom (category_to_string fact.category))
    source.turn
    (staleness_marker ~now fact)
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;

(* RFC-0244 Tier 2: a shared fact is rendered with its provenance (the distinct
   keepers that corroborated it) so it is never silently merged into the keeper's
   own knowledge — the reader can see it is cross-keeper consensus. *)
let render_shared_fact ~now fact =
  let provenance =
    match fact.observed_by with
    | [] -> "shared"
    | keepers -> "shared via " ^ String.concat "," (List.map sanitize_atom keepers)
  in
  Printf.sprintf
    "- [%s category=%s]%s %s"
    provenance
    (sanitize_atom (category_to_string fact.category))
    (staleness_marker ~now fact)
    (sanitize_text ~max_len:max_fact_text_len fact.claim)
;;

let render_episode episode =
  let terminal =
    match episode.terminal_marker with
    | None -> ""
    | Some marker -> Printf.sprintf " terminal=%s" (sanitize_atom marker)
  in
  Printf.sprintf
    "- [%s g%04d%s] %s"
    (sanitize_atom episode.trace_id)
    episode.generation
    terminal
    (sanitize_text ~max_len:max_episode_text_len episode.episode_summary)
;;

let render_prompt_template key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text -> Ok (String.trim text)
  | Error msg -> Error (Printf.sprintf "%s: %s" key msg)
;;

let render_unavailable_context reason =
  record_unavailable reason;
  let reason = unavailable_reason_to_label reason in
  match
    render_prompt_template
      Keeper_prompt_names.memory_os_recall_unavailable
      [ "reason", reason ]
  with
  | Ok text -> text
  | Error msg ->
    Log.Keeper.warn "memory os recall unavailable prompt unavailable: %s" msg;
    Printf.sprintf
      "--- Memory OS Recall ---\nMemory recall unavailable (reason=%s)."
      reason
;;

let render_nonempty_section key variable lines =
  match lines with
  | [] -> Ok ""
  | _ -> render_prompt_template key [ variable, String.concat "\n" lines ]
;;

let render_recall_context ~fact_lines ~episode_lines =
  match
    render_nonempty_section
      Keeper_prompt_names.memory_os_recall_facts_section
      "facts"
      fact_lines
  with
  | Error msg -> Error msg
  | Ok facts_section ->
    (match
       render_nonempty_section
         Keeper_prompt_names.memory_os_recall_episodes_section
         "episodes"
         episode_lines
     with
     | Error msg -> Error msg
     | Ok episodes_section ->
       render_prompt_template
         Keeper_prompt_names.memory_os_recall_context
         [ "facts_section", facts_section; "episodes_section", episodes_section ])
;;

(* RFC-0239 R2 / RFC-0243 / RFC-0259 §3.7: recall-time dedup keys on the shared
   [Keeper_memory_os_types.claim_identity] SSOT (was a [normalize_claim] copy;
   RFC-0243 lifted it so the write-time upsert keys identically, RFC-0259 §3.7
   re-pointed it at the typed producer-identity key). Since RFC-0243 makes the
   librarian write path upsert-by-claim, the store no longer accumulates fresh
   duplicates; this read-time dedup remains as defense-in-depth for legacy rows
   written before the upsert landed. *)
let dedup_by_claim facts =
  let seen = Hashtbl.create 32 in
  List.filter
    (fun fact ->
      let key = claim_identity fact in
      if Hashtbl.mem seen key then false else (Hashtbl.add seen key (); true))
    facts
;;

(* RFC-0247 (purge): the truth anchor used as the structural recall order
   (most-recently-verified first). It is the type-level {!reference_time} SSOT, so
   "kept" ([retention_rank]), "ranked" (here), and "marked stale"
   ([staleness_marker]) all read the same timestamp by construction. *)
let truth_anchor (fact : fact) = reference_time fact

(* Filter to current, order by structural recency (the truth anchor), dedup, and
   exclude first-person self-observations. Self-observations ("I am idle",
   "I am looping") are transient agent-state notes, not verifiable external state
   or durable knowledge, so they must not leak into the recall context shown to
   the model. RFC-0285 §3.1 classifies them at the producer boundary; this is the
   read-side enforcement.

   RFC-0247 replaced the composite [score_fact] order with this single typed
   timestamp: recall ordering is structural, never a learned number. The prior
   pipeline also ran spreading-activation reranking ([activate]) and lexical
   seed-rerank ([seed_tokens]); both added a numeric boost to decide order and
   were removed in the purge. The association edge store and its spreading-activation
   organ were removed entirely (RFC-0251); recall depends only on the deterministic
   timestamp order above. *)
let facts_recency_ranked ~now facts =
  facts
  |> List.filter (fact_is_current ~now)
  |> List.filter fact_prompt_recallable
  |> List.filter (fun (fact : fact) ->
    match fact.claim_kind with
    | Some Keeper_memory_os_types.Self_observation -> false
    | _ -> true)
  |> List.sort (fun a b -> compare (truth_anchor b) (truth_anchor a))
  |> dedup_by_claim
;;

let episode_prompt_recallable (episode : episode) =
  match episode.claims with
  | [] -> false
  | claims -> List.exists fact_prompt_recallable claims
;;

(* RFC-0264 P2: render_context_exn returns the rendered block alongside the
   claim_identity keys it injected, so [render_if_enabled] can append a
   deterministic recall-injection record (the join key for outcome eval). The
   keys are a by-product already computed for shared-store dedup
   ([private_keys]); surfacing them costs nothing extra on the hot path. *)
type render_result =
  { block : string
  ; injected_fact_keys : string list
  ; injected_episode_keys : string list
  ; n_facts_in_store : int
  ; failure_reason : unavailable_reason option
  }

let with_fact_store_locks keeper_ids f =
  let paths =
    keeper_ids
    |> List.map (fun keeper_id -> Keeper_memory_os_io.facts_path ~keeper_id)
    |> List.sort_uniq String.compare
  in
  let rec loop = function
    | [] -> f ()
    | path :: rest -> File_lock_eio.with_lock path (fun () -> loop rest)
  in
  loop paths
;;

let render_context_exn ~keeper_id ~now ~max_facts ~max_episodes () =
  let max_facts = max 0 max_facts in
  let max_episodes = max 0 max_episodes in
  (* RFC-0239 Q4: scan the whole bounded store, not a [fact_recall_window]-sized
     tail. The store holds up to [fact_store_max] facts between caps, and a fresh
     cap rewrites it in rank order — so the highest-ranked durable rows sit at
     the file head while new appends land at the tail. Scanning only
     [fact_recall_window] tail rows would exclude exactly those head rows in the
     [fact_recall_window]..[fact_store_max] band; scanning [fact_store_max]
     covers the entire bounded store so recency ranking selects the globally best
     facts. RFC-0247: order by the structural truth anchor (most-recently-verified
     first); the composite score, lexical seed-rerank, and spreading-activation
     reranking were all removed in the purge. *)
  let facts, private_keys, shared_facts, n_facts_in_store =
    let fact_store_ids =
      if String.equal keeper_id shared_store_id
      then [ keeper_id ]
      else [ keeper_id; shared_store_id ]
    in
    with_fact_store_locks fact_store_ids (fun () ->
      let all_facts =
        Keeper_memory_os_io.read_facts_tail
          ~keeper_id
          ~n:Keeper_memory_os_io.fact_store_max
      in
      let n_facts_in_store = List.length all_facts in
      let facts = all_facts |> facts_recency_ranked ~now |> take max_facts in
      (* RFC-0244 Tier 2: append shared-semantic facts after the keeper's own,
         with private precedence — a claim already surfaced from this keeper's
         store is not repeated from the shared store. Both stores are read under
         their facts locks in deterministic path order, so the private dedup keys
         and shared slice come from one serialized snapshot boundary. Unlike
         per-keeper stores, the consolidator rewrites the shared tier directly
         and does not apply [fact_store_max], so recall must scan every shared
         fact before ranking and taking the small communal slice. *)
      let private_keys = List.map (fun f -> claim_identity f) facts in
      let shared_facts =
        if String.equal keeper_id shared_store_id
        then []
        else
          Keeper_memory_os_io.read_facts_all ~keeper_id:shared_store_id
          |> facts_recency_ranked ~now
          |> List.filter (fun f -> not (List.mem (claim_identity f) private_keys))
          |> take default_max_shared_facts
      in
      facts, private_keys, shared_facts, n_facts_in_store)
  in
  let episodes =
    Keeper_memory_os_io.read_episodes_tail
      ~keeper_id
      ~n:(max max_episodes episode_tail_scan)
    |> List.filter (episode_is_current ~now)
    |> List.filter episode_prompt_recallable
    |> take max_episodes
  in
  let injected_fact_keys =
    private_keys @ List.map (fun f -> claim_identity f) shared_facts
  in
  let injected_episode_keys =
    List.map
      (fun (e : episode) -> Printf.sprintf "%s:g%d" e.trace_id e.generation)
      episodes
  in
  let block, injected_fact_keys, injected_episode_keys, failure_reason =
    match facts, shared_facts, episodes with
    | [], [], [] -> "", [], [], None
    | _ ->
      let fact_lines =
        List.map (render_fact ~now) facts
        @ List.map (render_shared_fact ~now) shared_facts
      in
      let episode_lines = List.map render_episode episodes in
      (match render_recall_context ~fact_lines ~episode_lines with
       | Ok context -> context, injected_fact_keys, injected_episode_keys, None
       | Error msg ->
         Log.Keeper.warn "memory os recall prompt unavailable keeper=%s: %s" keeper_id msg;
         ( render_unavailable_context Prompt_render_error
         , []
         , []
         , Some Prompt_render_error ))
  in
  { block; injected_fact_keys; injected_episode_keys; n_facts_in_store; failure_reason }
;;

let render_context
      ~keeper_id
      ~now
      ?(max_facts = default_max_facts)
      ?(max_episodes = default_max_episodes)
      ()
  =
  try (render_context_exn ~keeper_id ~now ~max_facts ~max_episodes ()).block with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "memory os recall unavailable keeper=%s: %s"
      keeper_id
      (Printexc.to_string exn);
    render_unavailable_context Read_error
;;

let enabled () =
  (* Default on, mirroring the librarian (write side): persisted memory
     that never reaches a prompt is dead weight. Env var = kill switch. *)
  Env_config.KeeperMemoryOs.recall_enabled ()
;;

let render_if_enabled ~keeper_id ~now ~trace_id ~turn ~masc_root () =
  if not (enabled ())
  then None
  else (
    (* RFC-0264 P2: render once, then append a recall-injection record keyed by
       trace_id/turn so outcome eval can join "what recall showed this trace" to
       the execution_receipt + forge outcome. The ledger write is best-effort
       and never affects the returned block. *)
    let result =
      try
        render_context_exn
          ~keeper_id
          ~now
          ~max_facts:default_max_facts
          ~max_episodes:default_max_episodes
          ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Keeper.warn
          "memory os recall unavailable keeper=%s: %s"
          keeper_id
          (Printexc.to_string exn);
        { block = render_unavailable_context Read_error
        ; injected_fact_keys = []
        ; injected_episode_keys = []
        ; n_facts_in_store = 0
        ; failure_reason = Some Read_error
        }
    in
    match String.trim result.block with
    | "" -> None
    | block ->
      (* RFC-0285 §8: record what this turn's prompt actually contains so the
         librarian write path can tell a recalled echo from an independent
         re-observation. This in-memory window is the load-bearing counterpart
         of the append-only ledger below (which stays telemetry-only). *)
      Keeper_recall_injection_window.note
        ~keeper_id
        ~turn
        ~keys:result.injected_fact_keys;
      Keeper_recall_injection_ledger.append
        ?failure_reason:(Option.map unavailable_reason_to_label result.failure_reason)
        ~masc_root
        ~keeper_id
        ~trace_id
        ~turn
        ~injected_fact_keys:result.injected_fact_keys
        ~injected_episode_keys:result.injected_episode_keys
        ~n_facts_in_store:result.n_facts_in_store
        ~now
        ();
      Some block)
;;
