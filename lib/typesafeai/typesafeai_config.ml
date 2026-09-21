(* The lane's settings are the [typesafeai] table of runtime.toml, published
   on load by [Runtime.set_loaded] into [Runtime_typesafeai_policy]; only
   the key is read from the environment, because it is a secret. *)

let policy () = Runtime_typesafeai_policy.current ()
let default_endpoint = Runtime_schema.default_typesafeai.Runtime_schema.lane_endpoint
let default_model = Runtime_schema.default_typesafeai.Runtime_schema.lane_model

let api_key () = Env_config_core.trim_opt (Env_config_core.raw_value_opt "TYPESAFEAI_API_KEY")
let endpoint () = (policy ()).Runtime_schema.lane_endpoint
let model () = (policy ()).Runtime_schema.lane_model

type unavailable_reason =
  | Lane_disabled
  | Missing_api_key
  | Absorb_gate_disabled
  | Board_attention_disabled
  | Context_review_disabled
  | Keeper_excluded

let unavailable_reason_to_string = function
  | Lane_disabled -> "lane_disabled"
  | Missing_api_key -> "missing_api_key"
  | Absorb_gate_disabled -> "absorb_gate_disabled"
  | Board_attention_disabled -> "board_attention_disabled"
  | Context_review_disabled -> "context_review_disabled"
  | Keeper_excluded -> "keeper_excluded"
;;

(* The table turns the lane off; it cannot turn it on without a key, and a
   key with the default table is enough to opt in. *)
let lane_api_key () =
  if not (policy ()).Runtime_schema.lane_enabled
  then Error Lane_disabled
  else (
    match api_key () with
    | Some key -> Ok key
    | None -> Error Missing_api_key)
;;

let is_enabled () = Result.is_ok (lane_api_key ())

(* One exclusion for all reviews: they reach the same endpoint, so a keeper
   whose content must not leave is excluded whichever gate asks. *)
let is_excluded ~keeper_id = List.mem keeper_id (policy ()).Runtime_schema.excluded_keepers

(* One switch per gate on top of the lane's, then the exclusion. A key turns
   the lane on; each gate can still be turned off by name, so adding a gate
   does not switch on another one that nobody reviewed with it. The Board
   gate defaults to on, which is what the lane alone meant before the second
   gate existed. The absorb gate defaults to off: it sends the librarian's
   memories to the vendor, which a deployment that set its key for the Board
   gate did not choose. *)
let gate_api_key ~keeper_id ~switched_on ~off =
  match lane_api_key () with
  | Error reason -> Error reason
  | Ok key ->
    if not switched_on
    then Error off
    else if is_excluded ~keeper_id
    then Error Keeper_excluded
    else Ok key
;;

let absorb_gate_api_key ~keeper_id =
  gate_api_key ~keeper_id ~switched_on:(policy ()).Runtime_schema.absorb_gate ~off:Absorb_gate_disabled
;;

let board_attention_api_key ~keeper_id =
  gate_api_key
    ~keeper_id
    ~switched_on:(policy ()).Runtime_schema.board_attention
    ~off:Board_attention_disabled
;;

let context_review_api_key ~keeper_id =
  gate_api_key ~keeper_id ~switched_on:(policy ()).Runtime_schema.context_review
    ~off:Context_review_disabled
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
  | Configured of { model : string }

let readiness () =
  if is_board_attention_enabled () then Configured { model = model () } else Off
;;
