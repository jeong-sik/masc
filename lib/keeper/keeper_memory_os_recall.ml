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
  let injected_fact_keys = List.map (fun f -> claim_identity f) facts in
  let injected_episode_keys = List.map episode_key episodes in
  let block, injected_fact_keys, injected_episode_keys, failure_reason =
    match facts, episodes with
    | [], [] -> "", [], [], None
    | _ ->
      let fact_lines = List.map (render_fact ~now) facts in
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
  let max_bytes = Keeper_config.keeper_memory_os_recall_max_bytes () in
  if max_bytes > 0 && String.length block > max_bytes
  then (
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MemoryOsRecallBytesOverBudget)
      ~labels:[ "keeper", keeper_id ]
      ();
    Log.Keeper.warn
      "memory os recall block over byte budget keeper=%s: bytes=%d budget=%d (not truncated; \
       raise keeper.memory_os.recall.max_bytes or lower max_facts/max_episodes)"
      keeper_id
      (String.length block)
      max_bytes);
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
