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

(* The block carries the selected facts and their source revision without
   adding behavioral policy. *)
let recall_block ~revision ~updated_at ~facts =
  Printf.sprintf
    "--- Memory OS Recall ---\nLLM-selected current memory, revision %d, updated %s.\n%s"
    revision
    updated_at
    facts
;;

(* A turn without recall injects nothing. The reason remains operator-visible
   through [MemoryOsRecallUnavailable] and the warning at each call site. *)
let omit ?reason () =
  Option.iter record_unavailable reason;
  ""
;;

let render_snapshot ~now:_ snapshot =
  let facts = snapshot.Keeper_memory_os_current.facts in
  match facts with
  | [] -> omit ()
  | _ ->
    let max_bytes = Env_config.KeeperMemoryOs.recall_facts_max_bytes () in
    (match Keeper_memory_os_budget.measure ~max_bytes facts with
     | Exceeds { actual_bytes; max_bytes } ->
       Log.Keeper.warn
         "memory os recall fact payload exceeds byte budget actual_bytes=%d max_bytes=%d"
         actual_bytes
         max_bytes;
       omit ~reason:Fact_budget_exceeded ()
     | Fits _ ->
       recall_block
         ~revision:snapshot.revision
         ~updated_at:(Masc_domain.iso8601_of_unix_seconds snapshot.updated_at)
         ~facts:(Keeper_memory_os_budget.render_facts facts))
;;

let render_context_result ~keepers_dir ~keeper_id ~now =
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None -> omit ()
  | Ok (Some snapshot) -> render_snapshot ~now snapshot
  | Error message ->
    Log.Keeper.warn
      "memory os recall unavailable keeper=%s: %s"
      keeper_id
      message;
    omit ~reason:Read_error ()
;;

let render_context ~keepers_dir ~keeper_id ~now () =
  render_context_result ~keepers_dir ~keeper_id ~now
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
        omit ~reason:Read_error ()
    in
    match String.trim result with
    | "" -> None
    | block -> Some block
;;
