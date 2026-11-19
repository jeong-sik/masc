module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry

type slot_key =
  { id : string
  ; target : string
  ; window : int
  ; reserve : int option
  }
[@@deriving eq, show]

type question_side =
  { prompt : string
  ; answer_schema :
      (Yojson.Safe.t
      [@equal Yojson.Safe.equal]
      [@printer fun fmt json -> Format.pp_print_string fmt (Yojson.Safe.to_string json)])
  ; max_output_tokens : int option
  ; thinking : bool option
  }
[@@deriving eq, show]

type t =
  { question : question_side
  ; http : slot_key list
  ; cli : slot_key list
  }
[@@deriving eq, show]

type unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Blank_slot_id
  | Window_unknown of { slot : string }
[@@deriving eq, show]

let lane_id = Standalone_lane.to_id Standalone_lane.Librarian_memory

let window_of id =
  Option.bind (Runtime.get_runtime_by_id id) (fun runtime ->
    Option.map fst (Runtime_instance.resolve_max_context_of_runtime runtime))
;;

let http_key ~reserve (slot : Registry.selected_slot) =
  match Exact.make_flow_candidate ~id:slot.slot_id ~admitted_target:slot.admitted_target with
  | Error Exact.Blank_flow_candidate_id -> Error Blank_slot_id
  | Ok candidate ->
    (* The fingerprint a walk binds this slot's target under, as the lane
       add-on reads it ([Server_lane_addon_exact.slot_target_fingerprint]). *)
    let target =
      Exact.target_identity_fingerprint (Exact.flow_candidate_identity candidate).Exact.target_identity
    in
    (match window_of slot.slot_id with
     | None -> Error (Window_unknown { slot = slot.slot_id })
     | Some window -> Ok { id = slot.slot_id; target; window; reserve })
;;

let cli_key ~reserve id =
  match window_of id with
  | None -> Error (Window_unknown { slot = id })
  | Some window -> Ok { id; target = id; window; reserve }
;;

(* The first slot that cannot be keyed, in declared order. *)
let rec keys key = function
  | [] -> Ok []
  | slot :: rest -> Result.bind (key slot) (fun first -> Result.map (List.cons first) (keys key rest))
;;

let resolve ~prompt ~answer_schema registry =
  match Registry.resolve_lane registry ~lane_id with
  | Error (Registry.Exact_lane_unconfigured _) -> Error Lane_unconfigured
  | Error (Registry.Exact_lane_off _) -> Error Lane_off
  | Error (Registry.No_admitted_lane_slots _) | Ok { Registry.selected_slots = []; cli_slots = [] } ->
    Error No_admitted_slots
  | Ok { Registry.selected_slots; cli_slots } ->
    (match Registry.declared_lane registry ~lane_id with
     (* [resolve_lane] admitted the lane, so the registry holds its table. *)
     | None -> Error Lane_unconfigured
     | Some decl ->
       let reserve = decl.Runtime_schema.max_output_tokens in
       Result.bind (keys (http_key ~reserve) selected_slots) (fun http ->
         Result.map
           (fun cli ->
              { question = { prompt; answer_schema; max_output_tokens = reserve; thinking = decl.thinking }
              ; http
              ; cli
              })
           (keys (cli_key ~reserve) cli_slots)))
;;

let lane_held
      ~(http : Runtime_exact_lane_backpressure.ordered)
      ~(cli : string Runtime_candidate_standing.exact_order)
  =
  match http.lane.Registry.selected_slots, cli.walk, http.held_http, cli.held with
  | [], [], _ :: _, _ | [], [], [], _ :: _ -> true
  | _ :: _, _, _, _ | [], _ :: _, _, _ | [], [], [], [] -> false
;;
