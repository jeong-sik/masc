type goal_ref =
  { goal_id : string
  ; goal_title : string
  }
[@@deriving yojson, show, eq]

type t =
  | Keeper_turn_capture_v1 of
      { keeper_name : string
      ; agent_name : string
      ; network_mode : string
      ; active_goal_ids : string list
      ; current_task_id : string option
      }
  | Contract_catalog_invariants of
      { contract_name : string
      ; description : string
      ; invariants : string list
      }
  | Verification_request of
      { goal_id : string
      ; request_id : string
      }
  | Persona_probe of
      { persona_id : string
      ; trace_id : string
      }
  | Free of Yojson.Safe.t
[@@deriving show, eq]

let criteria_kind = function
  | Keeper_turn_capture_v1 _ -> "keeper_turn_capture_v1"
  | Contract_catalog_invariants _ -> "contract_catalog_invariants"
  | Verification_request _ -> "verification_request"
  | Persona_probe _ -> "persona_probe"
  | Free _ -> "free"


(* Wire-byte-exact encoding for the two pre-RFC-0109 producer shapes
   (Keeper_turn_capture_v1, Contract_catalog_invariants). Adding a
   [criteria_kind] field to those shapes would change [Risk_contract.
   contract_id] (content-addressed md5 of canonical JSON), invalidating
   every existing proof_store entry. Field-shape detection in [of_yojson]
   recovers the variant for these legacy-shaped encodings. New variants
   (Verification_request, Persona_probe) carry [criteria_kind] because
   they have no installed-base wire format to preserve. *)
let to_yojson (t : t) : Yojson.Safe.t =
  match t with
  | Keeper_turn_capture_v1 r ->
    `Assoc
      [ "kind", `String "keeper_turn_capture_v1"
      ; "keeper_name", `String r.keeper_name
      ; "agent_name", `String r.agent_name
      ; "network_mode", `String r.network_mode
      ; "active_goal_ids", Json_util.json_string_list r.active_goal_ids
      ; "current_task_id_at_start", Json_util.string_opt_to_json r.current_task_id
      ]
  | Contract_catalog_invariants r ->
    `Assoc
      [ "contract_name", `String r.contract_name
      ; "description", `String r.description
      ; "invariants", Json_util.json_string_list r.invariants
      ]
  | Verification_request r ->
    `Assoc
      [ "criteria_kind", `String "verification_request"
      ; "goal_id", `String r.goal_id
      ; "request_id", `String r.request_id
      ]
  | Persona_probe r ->
    `Assoc
      [ "criteria_kind", `String "persona_probe"
      ; "persona_id", `String r.persona_id
      ; "trace_id", `String r.trace_id
      ]
  | Free j -> j

let assoc_lookup pairs key =
  List.assoc_opt key pairs

let as_string = function
  | `String s -> Ok s
  | other ->
    Error (Printf.sprintf "expected string, got %s" (Yojson.Safe.to_string other))

let as_string_opt = function
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
    Error (Printf.sprintf "expected string or null, got %s" (Yojson.Safe.to_string other))

let as_string_list = function
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> loop (s :: acc) rest
      | other :: _ ->
        Error (Printf.sprintf "expected string in list, got %s" (Yojson.Safe.to_string other))
    in
    loop [] items
  | other ->
    Error (Printf.sprintf "expected string list, got %s" (Yojson.Safe.to_string other))

let ( let* ) = Result.bind

let require pairs key =
  match assoc_lookup pairs key with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing field %s" key)

let optional pairs key =
  match assoc_lookup pairs key with
  | Some v -> v
  | None -> `Null

let decode_keeper_turn_capture_v1 pairs =
  let* keeper_name = require pairs "keeper_name" |> Result.map (fun x -> x) in
  let* keeper_name = as_string keeper_name in
  let* agent_name = require pairs "agent_name" in
  let* agent_name = as_string agent_name in
  let* network_mode = require pairs "network_mode" in
  let* network_mode = as_string network_mode in
  let* active_goal_ids =
    match assoc_lookup pairs "active_goal_ids" with
    | None -> Ok []
    | Some v -> as_string_list v
  in
  let* current_task_id =
    as_string_opt (optional pairs "current_task_id_at_start")
  in
  Ok
    (Keeper_turn_capture_v1
       { keeper_name
       ; agent_name
       ; network_mode
       ; active_goal_ids
       ; current_task_id
       })

let decode_contract_catalog_invariants pairs =
  let* contract_name = require pairs "contract_name" in
  let* contract_name = as_string contract_name in
  let* description = require pairs "description" in
  let* description = as_string description in
  let* invariants_v = require pairs "invariants" in
  let* invariants = as_string_list invariants_v in
  Ok (Contract_catalog_invariants { contract_name; description; invariants })

let decode_verification_request pairs =
  let* goal_id = require pairs "goal_id" in
  let* goal_id = as_string goal_id in
  let* request_id = require pairs "request_id" in
  let* request_id = as_string request_id in
  Ok (Verification_request { goal_id; request_id })

let decode_persona_probe pairs =
  let* persona_id = require pairs "persona_id" in
  let* persona_id = as_string persona_id in
  let* trace_id = require pairs "trace_id" in
  let* trace_id = as_string trace_id in
  Ok (Persona_probe { persona_id; trace_id })

let of_yojson (j : Yojson.Safe.t) : (t, string) result =
  match j with
  | `Assoc pairs ->
    let tagged_kind =
      match assoc_lookup pairs "criteria_kind" with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let legacy_kind =
      match assoc_lookup pairs "kind" with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let dispatch kind =
      match kind with
      | "keeper_turn_capture_v1" -> Some (decode_keeper_turn_capture_v1 pairs)
      | "contract_catalog_invariants" -> Some (decode_contract_catalog_invariants pairs)
      | "verification_request" -> Some (decode_verification_request pairs)
      | "persona_probe" -> Some (decode_persona_probe pairs)
      | _ -> None
    in
    let attempted =
      match tagged_kind with
      | Some k -> dispatch k
      | None ->
        (match legacy_kind with
         | Some k -> dispatch k
         | None ->
           (* Legacy contract_catalog shape has no [kind] tag — recognize
              by required-field shape. *)
           (match
              ( assoc_lookup pairs "contract_name"
              , assoc_lookup pairs "invariants" )
            with
            | Some _, Some _ -> Some (decode_contract_catalog_invariants pairs)
            | _ -> None))
    in
    (match attempted with
     | Some (Ok v) -> Ok v
     | Some (Error _) | None -> Ok (Free j))
  | other -> Ok (Free other)
