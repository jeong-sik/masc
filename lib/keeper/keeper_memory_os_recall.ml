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

let render_context_exn ~keeper_id ~now () =
  let facts =
    File_lock_eio.with_lock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
      Keeper_memory_os_io.read_facts_all ~keeper_id
      |> List.filter (fact_is_current ~now))
  in
  let n_facts_in_store = List.length facts in
  let episodes =
    Keeper_memory_os_io.read_episodes_all ~keeper_id
    |> List.filter (episode_is_current ~now)
  in
  let injected_fact_keys = List.map (fun f -> claim_identity f) facts in
  let injected_episode_keys =
    List.map
      (fun (e : episode) -> Printf.sprintf "%s:g%d" e.trace_id e.generation)
      episodes
  in
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
