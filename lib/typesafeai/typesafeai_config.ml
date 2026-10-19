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
  | Librarian_preflight_disabled
  | Workspace_memory_selection_disabled
  | Keeper_excluded

let unavailable_reason_to_string = function
  | Lane_disabled -> "lane_disabled"
  | No_armed_destination -> "no_armed_destination"
  | Absorb_gate_disabled -> "absorb_gate_disabled"
  | Board_attention_disabled -> "board_attention_disabled"
  | Context_review_disabled -> "context_review_disabled"
  | Skill_applicability_disabled -> "skill_applicability_disabled"
  | Librarian_preflight_disabled -> "librarian_preflight_disabled"
  | Workspace_memory_selection_disabled -> "workspace_memory_selection_disabled"
  | Keeper_excluded -> "keeper_excluded"
;;

let configured_destinations () = (policy ()).Runtime_schema.destinations

(* A destination is armed when it names no variable (a local server that
   authenticates nobody asks with no key) or when the variable it names
   holds a non-blank key. One whose variable holds nothing is left out of
   the walk; the table keeps naming it. *)
let arm (destination : Runtime_schema.typesafeai_destination) =
  match destination.api_key_env with
  | None ->
    Some
      { Typesafeai_client.endpoint = destination.endpoint
      ; model = destination.model
      ; api_key = None
      }
  | Some variable ->
    Env_config_core.raw_value_opt variable
    |> Env_config_core.trim_opt
    |> Option.map (fun api_key ->
           { Typesafeai_client.endpoint = destination.endpoint
           ; model = destination.model
           ; api_key = Some api_key
           })
;;

(* A uniform shuffle (Fisher-Yates). With [selection = random] each
   judgment draws the destination it asks first this way, so N armed
   destinations are each asked first 1/N of the time; the rest stay as
   reserve. [rng] is injected so tests pin the draw. *)
let shuffle_with (rng : unit -> float) (items : 'a list) : 'a list =
  let shuffled = Array.of_list items in
  for i = Array.length shuffled - 1 downto 1 do
    let j = int_of_float (rng () *. float_of_int (i + 1)) in
    let held = shuffled.(i) in
    shuffled.(i) <- shuffled.(j);
    shuffled.(j) <- held
  done;
  Array.to_list shuffled
;;

let armed () =
  let first, rest = configured_destinations () in
  let armed_list = List.filter_map arm (first :: rest) in
  let ordered =
    match (policy ()).Runtime_schema.selection with
    | Runtime_schema.In_order -> armed_list
    | Runtime_schema.Random -> shuffle_with (fun () -> Random.float 1.0) armed_list
  in
  match ordered with
  | [] -> None
  | first :: rest -> Some (first, rest)
;;

(* The destinations the walk leaves out while it still has one to ask: each
   names a variable that holds no key, so a misspelt variable name silently
   turns a reserve route off. With no destination armed the lane is simply
   off, and nothing is singled out. *)
let unarmed_destinations () =
  let first, rest = configured_destinations () in
  match armed () with
  | None -> []
  | Some _ ->
    List.filter (fun destination -> Option.is_none (arm destination)) (first :: rest)
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

module For_testing = struct
  let shuffle_with = shuffle_with
end
;;

let board_attention_confidence_floor () =
  (policy ()).Runtime_schema.board_attention_confidence_floor

(* One switch per gate on top of the lane's, then the exclusion. A key turns
   the lane on; each gate can still be turned off by name, so adding a gate
   does not switch on another one that nobody reviewed with it. The Board
   gate defaults to on, which is what the lane alone meant before the second
   gate existed. The absorb gate defaults to off: it sends the librarian's
   memories to the vendor, which a deployment that set its key for the Board
   gate did not choose. *)
(* The declared reasons come first: a gate the operator switched off, or a
   Keeper the operator excluded, is unavailable by declaration whatever the
   lane's state. Only a gate that is declared on reports the lane's own
   unavailability, so a reader can tell "not asked because told not to"
   from "meant to ask and could not". *)
let gate_destinations ~keeper_id ~switched_on ~off =
  if not switched_on
  then Error off
  else if is_excluded ~keeper_id
  then Error Keeper_excluded
  else lane_destinations ()
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
let librarian_preflight_destinations ~keeper_id =
  gate_destinations ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.librarian_preflight
    ~off:Librarian_preflight_disabled
;;

let workspace_memory_selection_destinations ~keeper_id =
  gate_destinations ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.workspace_memory_selection_enabled
    ~off:Workspace_memory_selection_disabled
;;

let is_absorb_gate_enabled () = is_enabled () && (policy ()).Runtime_schema.absorb_gate

(* The names that exclude nobody: a keeper is excluded by its name, so a
   misspelt name silently excludes nothing. Boot asks this with the keepers
   it found and reports each. *)
let unknown_excluded_keepers ~known =
  List.filter (fun name -> not (List.mem name known)) (policy ()).Runtime_schema.excluded_keepers
;;

type readiness =
  | Off
  | Configured of { destinations : Typesafeai_client.destination_id list }

let readiness () =
  if not (policy ()).Runtime_schema.board_attention
  then Off
  else (
    match lane_destinations () with
    | Error (Lane_disabled | No_armed_destination) -> Off
    | Error
        ( Absorb_gate_disabled | Board_attention_disabled | Context_review_disabled
        | Skill_applicability_disabled | Librarian_preflight_disabled
        | Workspace_memory_selection_disabled | Keeper_excluded ) ->
      (* [lane_destinations] answers only about the lane and its keys. *)
      Off
    | Ok (first, rest) ->
      Configured { destinations = List.map Typesafeai_client.identify (first :: rest) })
;;
