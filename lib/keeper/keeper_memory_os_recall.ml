(** Render the exact LLM-selected current Memory OS snapshot. *)

open Keeper_memory_os_types

type unavailable_reason =
  | Read_error
  | Prompt_render_error
  | Fact_budget_exceeded

let unavailable_reason_to_label = function
  | Read_error -> "read_error"
  | Prompt_render_error -> "prompt_render_error"
  | Fact_budget_exceeded -> "fact_budget_exceeded"
;;

let record_unavailable reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryOsRecallUnavailable)
    ~labels:[ "reason", unavailable_reason_to_label reason ]
    ()
;;

let render_prompt_template key variables =
  match Prompt_registry.render_prompt_template key variables with
  | Ok text -> Ok (String.trim text)
  | Error message -> Error (Printf.sprintf "%s: %s" key message)
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
  | Error message ->
    Log.Keeper.warn
      "memory os recall unavailable prompt unavailable: %s"
      message;
    Printf.sprintf
      "--- Memory OS Recall ---\nMemory recall unavailable (reason=%s)."
      reason
;;

type render_result =
  { block : string
  ; injected_fact_keys : string list
  ; n_facts_in_store : int
  ; failure_reason : unavailable_reason option
  }

let render_snapshot ~now:_ snapshot =
  let facts = snapshot.Keeper_memory_os_current.facts in
  match facts with
  | [] ->
    { block = ""
    ; injected_fact_keys = []
    ; n_facts_in_store = 0
    ; failure_reason = None
    }
  | _ ->
    let max_bytes = Env_config.KeeperMemoryOs.recall_facts_max_bytes () in
    (match Keeper_memory_os_budget.measure ~max_bytes facts with
     | Exceeds { actual_bytes; max_bytes } ->
       Log.Keeper.warn
         "memory os recall fact payload exceeds byte budget actual_bytes=%d max_bytes=%d"
         actual_bytes
         max_bytes;
       { block = render_unavailable_context Fact_budget_exceeded
       ; injected_fact_keys = []
       ; n_facts_in_store = List.length facts
       ; failure_reason = Some Fact_budget_exceeded
       }
     | Fits _ ->
       (match
       render_prompt_template
         Keeper_prompt_names.memory_os_recall_context
         [ "revision", string_of_int snapshot.revision
         ; "updated_at", Masc_domain.iso8601_of_unix_seconds snapshot.updated_at
         ; "facts", Keeper_memory_os_budget.render_facts facts
         ]
     with
     | Ok block ->
       { block
       ; injected_fact_keys = List.map memory_id facts
       ; n_facts_in_store = List.length facts
       ; failure_reason = None
       }
     | Error message ->
       Log.Keeper.warn
         "memory os recall prompt unavailable: %s"
         message;
       { block = render_unavailable_context Prompt_render_error
       ; injected_fact_keys = []
       ; n_facts_in_store = List.length facts
       ; failure_reason = Some Prompt_render_error
       }))
;;

let render_context_result ~keepers_dir ~keeper_id ~now =
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { block = ""
    ; injected_fact_keys = []
    ; n_facts_in_store = 0
    ; failure_reason = None
    }
  | Ok (Some snapshot) -> render_snapshot ~now snapshot
  | Error message ->
    Log.Keeper.warn
      "memory os recall unavailable keeper=%s: %s"
      keeper_id
      message;
    { block = render_unavailable_context Read_error
    ; injected_fact_keys = []
    ; n_facts_in_store = 0
    ; failure_reason = Some Read_error
    }
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
        { block = render_unavailable_context Read_error
        ; injected_fact_keys = []
        ; n_facts_in_store = 0
        ; failure_reason = Some Read_error
        }
    in
    match String.trim result.block with
    | "" -> None
    | block -> Some block
;;
