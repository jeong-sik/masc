(* GET /api/v1/runtime/resolved — single source of truth for "what runtime,
   model, and max-context is actually applied" (bugs #14/#15/#36):

   - #15: max-context previously diverged across three sources (runtime.toml
     override, AGENT_CORE hardcoded defaults, AGENT_CORE capability catalog cap). This
     document reports the one value [Runtime.max_context_of_runtime] resolves,
     plus which of [override]/[capability]/[override_clamped_by_capability]
     produced it ([Runtime.resolve_max_context_of_runtime]).
   - #14: the settings panel previously rendered only explicit
     [\[runtime.assignments\]] entries. [assignments] here joins every
     configured keeper — including ones riding [\[runtime\].default] with no
     explicit entry — so the frontend never has to reconstruct that join.
   - #36: this is the one place an operator can see the resolved
     runtime/model actually in effect. *)

let string_opt_json = Json_util.string_opt_to_json
let int_opt_json = Json_util.int_opt_to_json

let runtime_resolution_json (rt : Runtime.t) : Yojson.Safe.t =
  let effective_max_context, source =
    match Runtime.resolve_max_context_of_runtime rt with
    | Some resolution -> resolution
    | None ->
      failwith
        (Printf.sprintf
           "runtime resolved projection invariant violated: runtime %S has no max-context resolution"
           rt.id)
  in
  (* Life state: the quota window says whether the
     provider side of this runtime is currently refusing work (2026-09-12
     operator ask: the runtime list shows what exists, not what is alive).
     [Until] is a provider-stated reset deadline; [Observed] is a hard-quota
     rejection that claimed no reset -- the next success on the scope clears
     it. A numeric "remaining" is not honest: providers do not expose it,
     and the window's own contract is these two facts. *)
  let quota_scope = Runtime.quota_scope_of_runtime rt in
  let now = Time_compat.now () in
  let quota_exhausted = Runtime_quota_window.is_exhausted ~scope:quota_scope ~now in
  let quota_resets_at = Runtime_quota_window.active_until ~scope:quota_scope ~now in
  let quota_scope_label = Runtime_quota_window.scope_to_string quota_scope in
  `Assoc
    [ "id", `String rt.id
    ; "provider", `String rt.provider.display_name
    ; "model", `String rt.model.api_name
    ; "effective_max_context", `Int effective_max_context
    ; "max_context_source", `String (Runtime.max_context_source_to_string source)
    ; "max_output_tokens", int_opt_json (Runtime.max_output_tokens_of_runtime_id rt.id)
      (* The effort this binding declares. Bindings of one model that differ
         only in effort share provider, model and context, so without it the
         picker draws them as identical rows. [null] is an unset effort, not
         an unknown one.

         Declared, not effective: an official-client turn puts the value
         through the catalog clamp and then the CLI's own vocabulary
         ([Keeper_official_client_host.effective_reasoning_effort],
         [Runtime_claude_code.cli_admitted_reasoning_effort]), which today
         changes only [minimal] on Claude Code and efforts outside a model's
         accepted set. The key says which of the two it is; surfacing the
         other belongs to the detail view, which has room to say both. *)
    ; ( "declared_reasoning_effort"
      , match Runtime.reasoning_effort_of_runtime_id rt.id with
        | Some effort -> `String (Llm_provider.Reasoning_effort.to_string effort)
        | None -> `Null )
    ; "is_local", `Bool (Runtime.is_local_runtime rt)
    ; "is_default", `Bool rt.binding.is_default
    ; "quota_exhausted", `Bool quota_exhausted
    ; "quota_resets_at", (match quota_resets_at with Some t -> `Float t | None -> `Null)
    ; "quota_scope", `String quota_scope_label
    ]
;;

let lane_json (lane : Runtime_lane.t) : Yojson.Safe.t =
  `Assoc
    [ "id", `String (Runtime_lane.id lane)
    ; "runtime_ids", Json_util.json_string_list (Runtime_lane.ordered_candidates lane)
    ]
;;

let resolved_assignment_json
    (resolution : [ `Lane of Runtime_lane.t | `Unavailable of Runtime.missing_catalog_model | `Missing ])
  : Yojson.Safe.t
  =
  match resolution with
  | `Lane lane -> `Assoc [ "kind", `String "lane"; "id", `String (Runtime_lane.id lane) ]
  | `Unavailable missing ->
      `Assoc
        [ "kind", `String "unavailable"
        ; "id", `String missing.runtime_id
        ; "reason", `Assoc
            [ "kind", `String "missing_catalog_model"
            ; "message", `String ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing)
            ; "provider_id", `String missing.provider_id
            ; "provider_label", `String missing.provider_label
            ; "model_id", `String missing.model_id
            ]
        ]
  | `Missing -> `Assoc [ "kind", `String "missing"; "id", `Null ]
;;

(* Mirrors [Keeper_meta_contract.runtime_id_of_meta]: a keeper with no
   [\[runtime.assignments\]] entry (or a blank one) runs on [\[runtime\].default].
   Duplicating that exact fallback here (rather than only reporting explicit
   assignments) is bug #14's fix — the resolved document must match what a
   turn actually dispatches to. *)
let assignment_target (default : Runtime.t option) (keeper_name : string)
  : string * string option
  =
  match Runtime.runtime_id_for_keeper keeper_name with
  | Some id when String.trim id <> "" -> "explicit", Some (String.trim id)
  | Some _ | None -> "default", Option.map (fun (rt : Runtime.t) -> rt.id) default
;;

let assignment_json (default : Runtime.t option) (keeper_name : string) : Yojson.Safe.t =
  let assignment_source, runtime_id = assignment_target default keeper_name in
  let resolved =
    match runtime_id with
    | Some id -> resolved_assignment_json (Runtime.resolve_assignment id)
    | None -> `Assoc [ "kind", `String "missing"; "id", `Null ]
  in
  `Assoc
    [ "keeper", `String keeper_name
    ; "assignment_source", `String assignment_source
    ; "resolved", resolved
    ]
;;

(* Union of explicit [\[runtime.assignments\]] keys and the keeper registry:
   an assignment can name a keeper whose directory has not materialized yet,
   and the registry can list keepers with no assignment at all (the default
   riders bug #14 is about). *)
let all_keeper_names ~(config : Workspace.config) : string list =
  let assigned = List.map fst (Runtime.keeper_assignments ()) in
  let registered = Keeper_meta_store.keeper_names config in
  assigned @ registered |> List.sort_uniq String.compare
;;

(* Declared lanes plus the lanes an assignment resolves to on its own. A keeper
   assigned to a bare runtime id dispatches through a lane that no
   [\[runtime.lanes\]] table declares, and reporting only declared lanes would
   hide that lane's candidates from the document that is supposed to say what
   dispatch will do. *)
let dispatchable_lanes ~(config : Workspace.config) (default : Runtime.t option)
  : Runtime_lane.t list
  =
  let declared = Runtime.lanes () in
  let seen = List.map Runtime_lane.id declared in
  let implicit =
    all_keeper_names ~config
    |> List.filter_map (fun keeper -> snd (assignment_target default keeper))
    |> List.filter_map (fun id ->
      match Runtime.resolve_assignment id with
      | `Lane lane when not (List.mem (Runtime_lane.id lane) seen) -> Some lane
      | `Lane _ | `Missing | `Unavailable _ -> None)
    |> List.sort_uniq (fun a b ->
      String.compare (Runtime_lane.id a) (Runtime_lane.id b))
  in
  declared @ implicit
;;

let build ~generated_at_iso ~(config : Workspace.config) : Yojson.Safe.t =
  let default = Runtime.get_default_runtime () in
  `Assoc
    [ "generated_at_iso", `String generated_at_iso
    ; "source", `String "/api/v1/runtime/resolved"
    ; "config_path", string_opt_json (Runtime.config_path ())
    ; ( "default_runtime"
      , match default with
        | Some rt -> runtime_resolution_json rt
        | None -> `Null )
    ; "runtimes", `List (List.map runtime_resolution_json (Runtime.get_runtimes ()))
      (* [\[runtime\].media_failover] is a route, not a lane: no keeper turn
         dispatches to it, and it has no table of its own. Keep both the active
         fleet and the file's declaration so an operator can distinguish a
         rejected entry without losing its position when rewriting the route. *)
    ; "media_failover", Json_util.json_string_list (Runtime.media_failover ())
    ; ( "media_failover_declared"
      , Json_util.json_string_list (Runtime.declared_media_failover ()) )
    ; "lanes", `List (List.map lane_json (dispatchable_lanes ~config default))
    ; ( "assignments"
      , `List (List.map (assignment_json default) (all_keeper_names ~config)) )
    ]
;;
