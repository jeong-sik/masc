type reason =
  | Environment_switch_off
  | Recall_not_switched_on
  | Keeper_excluded
  | Lane_disabled
  | No_armed_destination
  | Refused_by_another_gate
[@@deriving enumerate]

type t =
  | Judged
  | Not_judged of reason

(* [Typesafeai_config.lane_destinations] answers only about the lane switch and
   the keys; a reason of any other gate is not an answer of it. *)
let lane_reason_of_unavailable = function
  | Typesafeai_config.Lane_disabled -> Lane_disabled
  | Typesafeai_config.No_armed_destination -> No_armed_destination
  | Typesafeai_config.Absorb_gate_disabled
  | Typesafeai_config.Board_attention_disabled
  | Typesafeai_config.Context_review_disabled
  | Typesafeai_config.Skill_applicability_disabled
  | Typesafeai_config.Librarian_preflight_disabled
  | Typesafeai_config.Workspace_memory_selection_disabled
  | Typesafeai_config.Memory_recall_disabled
  | Typesafeai_config.Keeper_excluded -> Refused_by_another_gate
;;

(* The gate of recall answers with its own switch, the exclusion, or what the
   lane answers. *)
let reason_of_unavailable = function
  | Typesafeai_config.Memory_recall_disabled -> Recall_not_switched_on
  | Typesafeai_config.Keeper_excluded -> Keeper_excluded
  | ( Typesafeai_config.Lane_disabled
    | Typesafeai_config.No_armed_destination
    | Typesafeai_config.Absorb_gate_disabled
    | Typesafeai_config.Board_attention_disabled
    | Typesafeai_config.Context_review_disabled
    | Typesafeai_config.Skill_applicability_disabled
    | Typesafeai_config.Librarian_preflight_disabled
    | Typesafeai_config.Workspace_memory_selection_disabled ) as other ->
    lane_reason_of_unavailable other
;;

let is_lane_reason = function
  | Lane_disabled | No_armed_destination | Refused_by_another_gate -> true
  | Environment_switch_off | Recall_not_switched_on | Keeper_excluded -> false
;;

(* The kill switch of the older recall notice first, then the gate of the
   judgment. With the switch off the notice says recall is disabled and the
   Keeper gets no judged texts either. *)
let of_keeper ~keeper_id =
  if not (Keeper_memory_os_recall.enabled ())
  then Not_judged Environment_switch_off
  else (
    match Typesafeai_config.memory_recall_destinations ~keeper_id with
    | Ok _ -> Judged
    | Error reason -> Not_judged (reason_of_unavailable reason))
;;

let is_judged ~keeper_id =
  match of_keeper ~keeper_id with
  | Judged -> true
  | Not_judged _ -> false
;;

let all_reasons = all_of_reason
let judged_word = "judged"
let lane_armed_word = "armed"

let reason_to_string = function
  | Environment_switch_off -> "environment_switch_off"
  | Recall_not_switched_on ->
    Typesafeai_config.unavailable_reason_to_string Typesafeai_config.Memory_recall_disabled
  | Keeper_excluded ->
    Typesafeai_config.unavailable_reason_to_string Typesafeai_config.Keeper_excluded
  | Lane_disabled ->
    Typesafeai_config.unavailable_reason_to_string Typesafeai_config.Lane_disabled
  | No_armed_destination ->
    Typesafeai_config.unavailable_reason_to_string Typesafeai_config.No_armed_destination
  | Refused_by_another_gate -> "another_gate_refused"
;;

let reason_of_string word =
  List.find_opt (fun reason -> String.equal (reason_to_string reason) word) all_reasons
;;
