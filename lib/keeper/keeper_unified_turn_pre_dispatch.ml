(* Keeper_unified_turn_pre_dispatch — RFC-0136 PR-3.

   Extracted from keeper_unified_turn.ml (L166-228) during the
   run_keeper_cycle stage decomposition. Owns the runtime-execution builder. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_runtime

let profile_load_error ~keeper_name error =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "keeper.profile"
       ; detail =
           Printf.sprintf
             "keeper %s profile is invalid: %s"
             keeper_name
             (Keeper_types_profile.keeper_toml_load_error_to_string error)
       })

let load_profile_defaults ~base_path ~keeper_name =
  Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
    ~base_path
    keeper_name
  |> Result.map_error (profile_load_error ~keeper_name)

(* [effective_meta_of_profile_defaults] already names the keeper and the
   allowed values in its message, so this only picks the field the operator
   has to edit. *)
let profile_overlay_error detail =
  Agent_core.Error.Config
    (Agent_core.Error.InvalidConfig
       { field = "keeper.sandbox_profile"; detail })

(* The meta a turn runs with is the registry entry's meta with the keeper TOML
   overlaid. Durable keeper JSON does not carry the config half of
   [keeper_meta] at all -- [Keeper_meta_json_parse] fills those eleven fields
   with placeholders and the store never writes them back -- so
   [entry.meta.sandbox_profile] is always the decoder's [Local] and the TOML
   is the only thing that can say [docker].

   Both turn entry points used to spell the overlay themselves, and
   [Keeper_unified_turn.run_keeper_cycle] spelled only the first half: it
   loaded [profile_defaults] for the runtime builder and then ran the turn on
   the un-overlaid [entry.meta]. Every heartbeat turn therefore dispatched
   [Execute] to the host while its keeper TOML declared [docker] (#30982).
   Returning both halves together is what makes that omission unspellable --
   a caller cannot hold the defaults without the meta they belong to. *)
let turn_profile_and_meta ~base_path ~(entry_meta : keeper_meta) :
    (Keeper_types_profile.keeper_profile_defaults * keeper_meta, Agent_core.Error.t) result =
  match load_profile_defaults ~base_path ~keeper_name:entry_meta.name with
  | Error _ as error -> error
  | Ok profile_defaults ->
    (match
       Keeper_meta_contract.effective_meta_of_profile_defaults
         profile_defaults
         entry_meta
     with
     | Ok meta -> Ok (profile_defaults, meta)
     | Error detail ->
       Error (profile_overlay_error detail))

let build_runtime_execution
      ~(meta : keeper_meta)
      ~(runtime_id : string)
  : ( Keeper_turn_runtime_budget.runtime_execution
    , Agent_core.Error.t )
    result
  =
  let runtime_id = String.trim runtime_id in
  if String.equal runtime_id "" then
    Error (Agent_core.Error.Internal "runtime_id must be non-empty")
  else
  let log_pre_dispatch_error ~site detail =
    Log.Keeper.error
      "%s: pre_dispatch: %s failed for runtime_id=%s: %s"
      meta.name
      site
      runtime_id
      detail
  in
  match
    Keeper_context_runtime.resolve_max_context_resolution_for_runtime_id
      ~requested_override:meta.max_context_override
      ~runtime_id
  with
  | Error error ->
    let detail =
      Keeper_context_runtime.max_context_resolution_error_to_string error
    in
    log_pre_dispatch_error ~site:"resolve_context_window" detail;
    Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig
            { field = "runtime.context_window"; detail }))
  | Ok entry_resolution ->
    (* #28765: the prompt is shaped once per turn, but sticky reordering
       and in-turn failover mean any candidate in the entry point's lane
       can end up serving that same prompt. The only single budget no
       serving candidate can overflow is the minimum across the lane's
       candidates — and a minimum is order-independent, so when the
       sticky reorder runs stops mattering. A runtime outside any lane
       keeps its own resolution. The lane is re-resolved here instead of
       threaded from the driver: both read the same
       [Runtime.resolve_assignment] SSOT, and a deferred lane hint's
       entry point maps back to that same lane. A candidate without a
       resolvable context window is excluded from the minimum with a
       warning — it would serve a prompt shaped without its window
       either way, which is exactly the pre-#28765 behavior. *)
    let max_context_resolution =
      match Runtime.resolve_assignment runtime_id with
      | `Missing -> entry_resolution
      | `Lane lane ->
        List.fold_left
          (fun (smallest : Keeper_context_runtime.max_context_resolution)
            candidate_id ->
            if String.equal candidate_id runtime_id
            then smallest
            else (
              match
                Keeper_context_runtime
                .resolve_max_context_resolution_for_runtime_id
                  ~requested_override:meta.max_context_override
                  ~runtime_id:candidate_id
              with
              | Error error ->
                Log.Keeper.warn
                  "%s: pre_dispatch: lane candidate %s has no resolvable \
                   context window (%s); it does not bound the turn budget"
                  meta.name
                  candidate_id
                  (Keeper_context_runtime.max_context_resolution_error_to_string
                     error);
                smallest
              | Ok resolution ->
                if resolution.effective_budget < smallest.effective_budget
                then resolution
                else smallest))
          entry_resolution
          (Runtime_lane.ordered_candidates lane)
    in
    if max_context_resolution.effective_budget < entry_resolution.effective_budget
    then
      Log.Keeper.info
        "%s: pre_dispatch: lane %s turn budget bound by a smaller sibling \
         window: entry effective=%d lane-min effective=%d"
        meta.name
        runtime_id
        entry_resolution.effective_budget
        max_context_resolution.effective_budget;
    let max_context =
      Keeper_turn_runtime_budget.resolved_max_context_for_turn
        ~meta
        max_context_resolution
    in
    let temperature =
      Runtime_inference.resolve_temperature
        ~runtime_id
        ~fallback:Keeper_config.keeper_unified_temperature
    in
    Ok
      { Keeper_turn_runtime_budget.runtime_id
      ; max_context_resolution
      ; max_context
      ; temperature
      }
