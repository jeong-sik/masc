type owner = Keeper_chat_events.response_identity

type t = {
  admitted : owner option;
  closed : owner option;
  unobserved_scope : int option;
}

type admission =
  | Admitted of t
  | Preserved_unobserved of t
  | Stale

let create () = { admitted = None; closed = None; unobserved_scope = None }

let owner_order (a : owner) (b : owner) =
  let generation = Int.compare a.response_generation b.response_generation in
  if generation = 0 then Int.compare a.response_scope b.response_scope
  else generation

let admit t (response : Keeper_chat_events.text_response) =
  match response with
  | Keeper_chat_events.Unobserved_scope scope ->
    let t = match scope, t.unobserved_scope with
      | Some scope, Some current when scope = current -> t
      | Some scope, (Some _ | None) -> {t with unobserved_scope=Some scope}
      | None, (Some _ | None) -> t in
    Preserved_unobserved t
  | Keeper_chat_events.Observed_response owner ->
    let closed_out =
      match t.closed with
      | Some closed -> owner_order owner closed <= 0
      | None -> false in
    let precedes_current =
      match t.admitted with
      | Some current when owner_order owner current < 0 -> true
      | Some current when owner.response_generation = current.response_generation ->
        (match t.unobserved_scope with
         | Some scope -> owner.response_scope < scope
         | None -> false)
      | Some _ | None -> false in
    if closed_out || precedes_current then Stale
    else match t.admitted, t.unobserved_scope with
      | Some current, None when owner_order owner current = 0 -> Admitted t
      | (Some _ | None), (Some _ | None) ->
          Admitted {t with admitted=Some owner; unobserved_scope=None}

let retire_attempt t =
  let closed = match t.admitted with
   | Some owner ->
     Some
       (match t.closed with
        | Some closed when owner_order closed owner >= 0 -> closed
        | Some _ | None -> owner)
   | None -> t.closed in
  {admitted=None; closed; unobserved_scope=None}
