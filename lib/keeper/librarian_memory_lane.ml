module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry

type target =
  | Http of
      { provider_id : string option
      ; model_id : string
      ; provider_kind :
          (Llm_provider.Provider_kind.t
          [@equal ( = )]
          [@printer Llm_provider.Provider_kind.pp])
      ; endpoint : string
      ; reserve : int
      }
  | Cli of
      { runtime_id : string
      ; api_name : string
      }
[@@deriving eq, show]

type slot_key =
  { id : string
  ; target : target
  ; window : int
  }
[@@deriving eq, show]

type question_side =
  { prompt : string
  ; answer_schema :
      (Yojson.Safe.t
      [@equal Yojson.Safe.equal]
      [@printer fun fmt json -> Format.pp_print_string fmt (Yojson.Safe.to_string json)])
  ; max_output_tokens : int
  ; thinking : bool option
  }
[@@deriving eq, show]

type t =
  { question : question_side
  ; http : slot_key list
  ; cli : slot_key list
  ; unadmitted : string list
  }
[@@deriving eq, show]

type unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Reserve_undeclared
  | Window_unknown of { slot : string }
[@@deriving eq, show]

let lane_id = Standalone_lane.to_id Standalone_lane.Librarian_memory

(* The window the registry froze beside the target, from the same
   materialized runtime. *)
let http_key ~reserve (slot : Registry.selected_slot) =
  match slot.runtime_observation with
  | None | Some { window = None; _ } -> Error (Window_unknown { slot = slot.slot_id })
  | Some { window = Some window; _ } ->
    let binding = Exact.admitted_target_binding slot.admitted_target in
    Ok
      { id = slot.slot_id
      ; target =
          Http
            { provider_id = binding.provider_id
            ; model_id = binding.model_id
            ; provider_kind = binding.provider_kind
            ; endpoint = binding.endpoint
            ; reserve
            }
      ; window
      }
;;

(* One read of the active table: the CLI call looks the runtime up the same
   way when it runs. *)
let cli_key id =
  match Runtime.get_runtime_by_id id with
  | None -> Error (Window_unknown { slot = id })
  | Some (runtime : Runtime_instance.t) ->
    (match Runtime_instance.resolve_max_context_of_runtime runtime with
     | None -> Error (Window_unknown { slot = id })
     | Some (window, _source) ->
       Ok { id; target = Cli { runtime_id = id; api_name = runtime.model.api_name }; window })
;;

(* The first slot that cannot be keyed, in declared order. *)
let rec keys key = function
  | [] -> Ok []
  | slot :: rest -> Result.bind (key slot) (fun first -> Result.map (List.cons first) (keys key rest))
;;

(* The declared slots of this lane that admission left out, in declared
   order. *)
let unadmitted registry =
  Registry.rejected_slots registry
  |> List.filter (fun (slot : Registry.rejected_slot) -> String.equal slot.lane_id lane_id)
  |> List.sort (fun (a : Registry.rejected_slot) (b : Registry.rejected_slot) ->
    Int.compare a.position b.position)
  |> List.map (fun (slot : Registry.rejected_slot) -> slot.slot_id)
;;

let resolve ~prompt ~answer_schema registry =
  match Registry.declared_lane registry ~lane_id with
  | None -> Error Lane_unconfigured
  | Some decl ->
    (* [admit_lanes] turns every declared table into exactly one admitted
       lane of the same immutable registry, so a declared table never reads
       back as unconfigured; that arm is the registry's own answer. *)
    (match Registry.resolve_lane registry ~lane_id, decl.Runtime_schema.max_output_tokens with
     | Error (Registry.Exact_lane_unconfigured _), _ -> Error Lane_unconfigured
     | Error (Registry.Exact_lane_off _), _ -> Error Lane_off
     | (Error (Registry.No_admitted_lane_slots _) | Ok { Registry.selected_slots = []; cli_slots = [] }), _ ->
       Error No_admitted_slots
     | Ok _, None -> Error Reserve_undeclared
     | Ok ({ Registry.selected_slots; cli_slots } as resolved), Some reserve ->
       Result.bind (keys (http_key ~reserve) selected_slots) (fun http ->
         Result.map
           (fun cli ->
              ( { question = { prompt; answer_schema; max_output_tokens = reserve; thinking = decl.thinking }
                ; http
                ; cli
                ; unadmitted = unadmitted registry
                }
              , resolved ))
           (keys cli_key cli_slots)))
;;

let lane_held ~now (lane : Registry.resolved_lane) =
  Option.is_some
    (Runtime_exact_lane_backpressure.held_until
       (Runtime_exact_lane_backpressure.order_at ~now lane)
       ~cli:(Keeper_lane_cli_oneshot.order_slots_at ~now lane.cli_slots))
;;
