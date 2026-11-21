type t =
  | Key_refused of
      { provider : string
      ; detail : string
      }
  | Spawn_refused of
      { provider : string
      ; detail : string
      }
  | Account_busy of
      { provider : string
      ; account_id : string
      }

type Agent_core.Error.carrier += Provider_refusal of t

let equal left right = left = right

let to_string = function
  | Key_refused { provider; _ } ->
    Printf.sprintf "Provider '%s' refused the API key for this account." provider
  | Spawn_refused { provider; _ } ->
    Printf.sprintf "Client '%s' could not start before sending the turn." provider
  | Account_busy { provider; account_id } ->
    Printf.sprintf
      "Account '%s' on provider '%s' is currently busy with another keeper call."
      account_id
      provider
;;

let core_error refusal =
  Agent_core.Error.Internal_carried
    { message = to_string refusal; carrier = Provider_refusal refusal }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried { carrier = Provider_refusal refusal; _ } ->
    Some refusal
  | ( Agent_core.Error.Api _
    | Provider _
    | Agent _
    | Mcp _
    | Config _
    | Serialization _
    | Io _
    | Orchestration _ | Media _
    | Internal _
    | Internal_carried _ ) -> None
;;
