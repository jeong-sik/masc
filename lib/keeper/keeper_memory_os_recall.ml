(** Keeper_memory_os_recall — render exact stored Memory OS context. *)

open Keeper_memory_os_types

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

(* Recall carries typed context and the exact claim. It does not synthesize an
   age bucket or an UNVERIFIED/stale verdict from timestamps. *)
let render_fact ~now:_ fact =
  let source = fact.source in
  Printf.sprintf
    "- [category=%s turn=%d] %s"
    (category_to_string fact.category)
    source.turn
    fact.claim
;;

let render_episode episode =
  let terminal =
    match episode.terminal_marker with
    | None -> ""
    | Some marker -> Printf.sprintf " terminal=%s" marker
  in
  Printf.sprintf
    "- [%s g%04d%s] %s"
    episode.trace_id
    episode.generation
    terminal
    episode.episode_summary
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

(* RFC-0351 L1: the model cannot manage a store it cannot see. One keeper
   diagnosed "Memory OS dumps 1500+ episodes per turn" when the store held
   268-500, stored that misdiagnosis as a fact, and had it re-injected every
   turn afterwards. The gauge reports what actually reached the model this turn
   against what is stored; the surrounding wording lives in
   config/prompts/keeper.memory_os_recall.context.md. Counts and byte totals
   only — no advice, no threshold, no verdict. *)
let render_gauge_line
      ~facts_injected
      ~facts_stored
      ~episodes_injected
      ~episodes_stored
      ~rendered_bytes
      ~byte_budget
  =
  let budget_part =
    if byte_budget <= 0
    then Printf.sprintf "%dB rendered (no byte budget)" rendered_bytes
    else Printf.sprintf "%dB/%dB rendered" rendered_bytes byte_budget
  in
  Printf.sprintf
    "facts %d/%d injected, episodes %d/%d injected, %s"
    facts_injected
    facts_stored
    episodes_injected
    episodes_stored
    budget_part
;;

let render_recall_context ~gauge_line ~fact_lines ~episode_lines =
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
         [ "gauge_line", gauge_line
         ; "facts_section", facts_section
         ; "episodes_section", episodes_section
         ])
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

(* masc#25052 P1: selection budget. Before this, every current fact/episode
   in the store was injected every turn -- no selection contract existed.
   [select_most_recent ~budget ~key ~recency items] keeps the [budget] most
   recent items (by [recency], descending) and returns them in their
   ORIGINAL relative order (a stable filter over [items], not a reordering)
   alongside the drop count, so turns that fit within budget see byte-for-
   byte the same order they always did -- only the truncation CASE picks
   which items survive, never how the survivors are arranged. [key] must be
   a stable per-item identity (claim_identity for facts, "trace_id:gN" for
   episodes) so membership after sorting can be checked without relying on
   structural/physical equality. *)
let select_most_recent ~budget ~key ~recency items =
  let n = List.length items in
  if n <= budget
  then items, 0
  else (
    let kept_keys =
      items
      |> List.map (fun item -> item, recency item)
      |> List.stable_sort (fun (_, a) (_, b) -> Float.compare b a)
      |> List.filteri (fun i _ -> i < budget)
      |> List.map (fun (item, _) -> key item)
      |> Set_util.StringSet.of_list
    in
    let selected = List.filter (fun item -> Set_util.StringSet.mem (key item) kept_keys) items in
    selected, n - budget)
;;

(* RFC-0351 L3: byte budget on the rendered block.

   The count budgets above bound how many items are injected, not how large
   they render. One keeper sat at 62 facts / 432 episodes -- both under the 500
   count budgets, so neither truncated -- and still rendered 222,499 bytes,
   98.5% of that turn's entire extra_system_context. The byte budget existed but
   was observability-only: it logged "not truncated" and let the block go out in
   full.

   Same selection shape as [select_most_recent]: keep the most recent items that
   fit and return them in their ORIGINAL relative order, so a block within
   budget renders byte-for-byte as before. Arithmetic on lengths only -- no
   importance score, no content inspection, no threshold on meaning. Pairs carry
   their pre-rendered line so a line is rendered once. *)
let select_pairs_within_byte_budget ~budget pairs =
  let rec take kept used dropped = function
    | [] -> kept, dropped
    | ((_, line) as pair) :: older ->
      let cost = String.length line + 1 (* newline joiner *) in
      if used + cost > budget
      then kept, dropped + List.length older + 1
      else take (pair :: kept) (used + cost) dropped older
  in
  (* Walk newest-first so survivors are the most recent; the accumulator
     rebuilds the original order. *)
  take [] 0 0 (List.rev pairs)
;;

let episode_key (e : episode) = Printf.sprintf "%s:g%d" e.trace_id e.generation

let log_truncation ~keeper_id ~kind ~metric ~store_count ~injected_count ~dropped ~budget =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string metric)
    ~labels:[ "keeper", keeper_id ]
    ~delta:(Float.of_int dropped)
    ();
  Log.Keeper.warn
    "memory os recall truncated %s keeper=%s: store=%d injected=%d dropped=%d budget=%d"
    kind
    keeper_id
    store_count
    injected_count
    dropped
    budget
;;

let render_context_exn ~keeper_id ~now () =
  let all_facts =
    File_lock_eio.with_lock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
      Keeper_memory_os_io.read_facts_all ~keeper_id
      |> List.filter (fact_is_current ~now))
  in
  (* Diagnostic: the TOTAL store size, independent of the selection budget
     below -- this is what tells an operator "the store has grown past what
     recall injects" rather than silently equalling whatever got selected. *)
  let n_facts_in_store = List.length all_facts in
  let all_episodes =
    Keeper_memory_os_io.read_episodes_all ~keeper_id
    |> List.filter (episode_is_current ~now)
  in
  let max_facts = Keeper_config.keeper_memory_os_recall_max_facts () in
  let max_episodes = Keeper_config.keeper_memory_os_recall_max_episodes () in
  let facts, facts_dropped =
    select_most_recent ~budget:max_facts ~key:claim_identity ~recency:reference_time all_facts
  in
  let episodes, episodes_dropped =
    select_most_recent
      ~budget:max_episodes
      ~key:episode_key
      ~recency:(fun (e : episode) -> e.created_at)
      all_episodes
  in
  if facts_dropped > 0
  then
    log_truncation
      ~keeper_id
      ~kind:"facts"
      ~metric:Keeper_metrics.MemoryOsRecallFactsTruncated
      ~store_count:n_facts_in_store
      ~injected_count:(List.length facts)
      ~dropped:facts_dropped
      ~budget:max_facts;
  if episodes_dropped > 0
  then
    log_truncation
      ~keeper_id
      ~kind:"episodes"
      ~metric:Keeper_metrics.MemoryOsRecallEpisodesTruncated
      ~store_count:(List.length all_episodes)
      ~injected_count:(List.length episodes)
      ~dropped:episodes_dropped
      ~budget:max_episodes;
  let max_bytes = Keeper_config.keeper_memory_os_recall_max_bytes () in
  let fact_lines = List.map (render_fact ~now) facts in
  let fact_bytes =
    List.fold_left (fun acc line -> acc + String.length line + 1) 0 fact_lines
  in
  (* Facts render an order of magnitude smaller than episodes (14,235B vs
     208,264B on the measured keeper), so facts keep their place and the
     remaining budget goes to episodes. *)
  let episode_pairs, episodes_byte_dropped =
    let pairs = List.map (fun e -> e, render_episode e) episodes in
    if max_bytes <= 0
    then pairs, 0
    else
      select_pairs_within_byte_budget ~budget:(max 0 (max_bytes - fact_bytes)) pairs
  in
  let episodes = List.map fst episode_pairs in
  let episode_lines = List.map snd episode_pairs in
  if episodes_byte_dropped > 0
  then (
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MemoryOsRecallBytesOverBudget)
      ~labels:[ "keeper", keeper_id ]
      ();
    log_truncation
      ~keeper_id
      ~kind:"episodes over byte budget"
      ~metric:Keeper_metrics.MemoryOsRecallEpisodesTruncated
      ~store_count:(List.length all_episodes)
      ~injected_count:(List.length episodes)
      ~dropped:episodes_byte_dropped
      ~budget:max_bytes);
  let injected_fact_keys = List.map (fun f -> claim_identity f) facts in
  let injected_episode_keys = List.map episode_key episodes in
  (* Content bytes, not final block size: the gauge is an input to the render,
     so the wrapper's own fixed text is not counted. It is what the budget
     above actually meters. *)
  let episode_bytes =
    List.fold_left
      (fun acc (_, line) -> acc + String.length line + 1)
      0
      episode_pairs
  in
  let gauge_line =
    render_gauge_line
      ~facts_injected:(List.length facts)
      ~facts_stored:n_facts_in_store
      ~episodes_injected:(List.length episodes)
      ~episodes_stored:(List.length all_episodes)
      ~rendered_bytes:(fact_bytes + episode_bytes)
      ~byte_budget:max_bytes
  in
  let block, injected_fact_keys, injected_episode_keys, failure_reason =
    match facts, episodes with
    | [], [] -> "", [], [], None
    | _ ->
      (match render_recall_context ~gauge_line ~fact_lines ~episode_lines with
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

let render_context ~keeper_id ~now () =
  try (render_context_exn ~keeper_id ~now ()).block with
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
        render_context_exn ~keeper_id ~now ()
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
