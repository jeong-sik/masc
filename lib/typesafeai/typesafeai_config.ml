(* The lane's settings are the [typesafeai] table of runtime.toml, published
   on load by [Runtime.set_loaded] into [Runtime_typesafeai_policy]; only the
   keys are read from the environment, because they are secrets, and each
   destination names the variable holding its own. *)

let policy () = Runtime_typesafeai_policy.current ()

type destinations = Typesafeai_client.destination * Typesafeai_client.destination list

type unavailable_reason =
  | Lane_disabled
  | No_armed_destination
  | Absorb_gate_disabled
  | Board_attention_disabled
  | Context_review_disabled
  | Skill_applicability_disabled
  | Keeper_excluded

let unavailable_reason_to_string = function
  | Lane_disabled -> "lane_disabled"
  | No_armed_destination -> "no_armed_destination"
  | Absorb_gate_disabled -> "absorb_gate_disabled"
  | Board_attention_disabled -> "board_attention_disabled"
  | Context_review_disabled -> "context_review_disabled"
  | Skill_applicability_disabled -> "skill_applicability_disabled"
  | Keeper_excluded -> "keeper_excluded"
;;

let configured_destinations () = (policy ()).Runtime_schema.destinations

(* A destination is armed when the variable it names holds a non-blank key.
   One that does not is left out of the walk; the table keeps naming it. *)
let arm (destination : Runtime_schema.typesafeai_destination) =
  Env_config_core.raw_value_opt destination.api_key_env
  |> Env_config_core.trim_opt
  |> Option.map (fun api_key ->
    { Typesafeai_client.endpoint = destination.endpoint; model = destination.model; api_key })
;;

let armed () =
  let first, rest = configured_destinations () in
  match List.filter_map arm (first :: rest) with
  | [] -> None
  | first :: rest -> Some (first, rest)
;;

(* The table turns the lane off; it cannot turn it on without a key, and a
   key in one named variable with the default table is enough to opt in. *)
let lane_destinations () =
  if not (policy ()).Runtime_schema.lane_enabled
  then Error Lane_disabled
  else (
    match armed () with
    | Some destinations -> Ok destinations
    | None -> Error No_armed_destination)
;;

let is_enabled () = Result.is_ok (lane_destinations ())

(* One exclusion for all reviews: they reach the same destinations, so a
   keeper whose content must not leave is excluded whichever gate asks. *)
let is_excluded ~keeper_id = List.mem keeper_id (policy ()).Runtime_schema.excluded_keepers

(* One switch per gate on top of the lane's, then the exclusion. A key turns
   the lane on; each gate can still be turned off by name, so adding a gate
   does not switch on another one that nobody reviewed with it. The Board
   gate defaults to on, which is what the lane alone meant before the second
   gate existed. The absorb gate defaults to off: it sends the librarian's
   memories to the vendor, which a deployment that set its key for the Board
   gate did not choose. *)
let gate_destinations ~keeper_id ~switched_on ~off =
  match lane_destinations () with
  | Error reason -> Error reason
  | Ok destinations ->
    if not switched_on
    then Error off
    else if is_excluded ~keeper_id
    then Error Keeper_excluded
    else Ok destinations
;;

let absorb_gate_destinations ~keeper_id =
  gate_destinations
    ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.absorb_gate
    ~off:Absorb_gate_disabled
;;

let board_attention_destinations ~keeper_id =
  gate_destinations
    ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.board_attention
    ~off:Board_attention_disabled
;;

let context_review_destinations ~keeper_id =
  gate_destinations
    ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.context_review
    ~off:Context_review_disabled
;;

let skill_applicability_destinations ~keeper_id =
  gate_destinations
    ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.skill_applicability
    ~off:Skill_applicability_disabled
;;

let is_board_attention_enabled () = is_enabled () && (policy ()).Runtime_schema.board_attention
let is_absorb_gate_enabled () = is_enabled () && (policy ()).Runtime_schema.absorb_gate

(* The names that exclude nobody: a keeper is excluded by its name, so a
   misspelt name silently excludes nothing. Boot asks this with the keepers
   it found and reports each. *)
let unknown_excluded_keepers ~known =
  List.filter (fun name -> not (List.mem name known)) (policy ()).Runtime_schema.excluded_keepers
;;

type readiness =
  | Off
  | Configured of { models : string list }

let readiness () =
  if not (policy ()).Runtime_schema.board_attention
  then Off
  else (
    match lane_destinations () with
    | Error (Lane_disabled | No_armed_destination) -> Off
    | Error
        ( Absorb_gate_disabled | Board_attention_disabled | Context_review_disabled
        | Skill_applicability_disabled | Keeper_excluded ) ->
      (* [lane_destinations] answers only about the lane and its keys. *)
      Off
    | Ok (first, rest) ->
      Configured
        { models = List.map (fun d -> d.Typesafeai_client.model) (first :: rest) })
;;
