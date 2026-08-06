(** Render the exact LLM-selected current Memory OS snapshot. *)

open Keeper_memory_os_types

type unavailable_reason =
  | Read_error
  | Fact_budget_exceeded

let unavailable_reason_to_label = function
  | Read_error -> "read_error"
  | Fact_budget_exceeded -> "fact_budget_exceeded"
;;

let record_unavailable reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryOsRecallUnavailable)
    ~labels:[ "reason", unavailable_reason_to_label reason ]
    ()
;;

(* The block frames stored facts for the turn; it states no rule of its own.
   How a Keeper is to treat memory — context rather than instruction, and
   time-sensitive claims verified against live state — is one sentence in
   config/prompts/keeper.md, where the Keeper's other standing rules are.
   Leaving a second asset here meant the same reader was addressed from two
   files, and it could fail to render. *)
let recall_block ~revision ~updated_at ~facts =
  Printf.sprintf
    "--- Memory OS Recall ---\nLLM-selected current memory, revision %d, updated %s.\n%s"
    revision
    updated_at
    facts
;;

type render_result =
  { block : string
  ; injected_fact_keys : string list
  ; n_facts_in_store : int
  ; failure_reason : unavailable_reason option
  }

(* A turn without recall injects nothing, and does so identically whether the
   store is empty or the read failed. The reason reaches the operator through
   the [MemoryOsRecallUnavailable] counter and the warn log at each call site.
   It does not reach the keeper: a paragraph stating that memory is missing
   makes the absence a fact the keeper can reason from, which is what the
   removed keeper.memory_os_recall.unavailable asset did. *)
let omit ?reason ~n_facts_in_store () =
  Option.iter record_unavailable reason;
  { block = ""; injected_fact_keys = []; n_facts_in_store; failure_reason = reason }
;;

let render_snapshot ~now:_ snapshot =
  let facts = snapshot.Keeper_memory_os_current.facts in
  match facts with
  | [] -> omit ~n_facts_in_store:0 ()
  | _ ->
    let max_bytes = Env_config.KeeperMemoryOs.recall_facts_max_bytes () in
    (match Keeper_memory_os_budget.measure ~max_bytes facts with
     | Exceeds { actual_bytes; max_bytes } ->
       Log.Keeper.warn
         "memory os recall fact payload exceeds byte budget actual_bytes=%d max_bytes=%d"
         actual_bytes
         max_bytes;
       omit ~reason:Fact_budget_exceeded ~n_facts_in_store:(List.length facts) ()
     | Fits _ ->
       { block =
           recall_block
             ~revision:snapshot.revision
             ~updated_at:(Masc_domain.iso8601_of_unix_seconds snapshot.updated_at)
             ~facts:(Keeper_memory_os_budget.render_facts facts)
       ; injected_fact_keys = List.map memory_id facts
       ; n_facts_in_store = List.length facts
       ; failure_reason = None
       })
;;

let render_context_result ~keepers_dir ~keeper_id ~now =
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None -> omit ~n_facts_in_store:0 ()
  | Ok (Some snapshot) -> render_snapshot ~now snapshot
  | Error message ->
    Log.Keeper.warn
      "memory os recall unavailable keeper=%s: %s"
      keeper_id
      message;
    omit ~reason:Read_error ~n_facts_in_store:0 ()
;;

let render_context ~keepers_dir ~keeper_id ~now () =
  (render_context_result ~keepers_dir ~keeper_id ~now).block
;;

let enabled () =
  Env_config.KeeperMemoryOs.recall_enabled ()
;;

let render_if_enabled ~keepers_dir ~keeper_id ~now () =
  if not (enabled ())
  then None
  else
    let result =
      try render_context_result ~keepers_dir ~keeper_id ~now with
      | Eio.Cancel.Cancelled _ as error -> raise error
      | exn ->
        Log.Keeper.warn
          "memory os recall unavailable keeper=%s: %s"
          keeper_id
          (Printexc.to_string exn);
        omit ~reason:Read_error ~n_facts_in_store:0 ()
    in
    match String.trim result.block with
    | "" -> None
    | block -> Some block
;;
