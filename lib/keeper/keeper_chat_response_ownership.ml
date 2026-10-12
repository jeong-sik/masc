type owner = Keeper_chat_events.response_identity

type t = {
  mutable admitted : owner option;
  mutable closed : owner option;
  mutable unobserved_scope : int option;
}

type admission =
  | Admitted
  | Preserved_unobserved
  | Stale

let create () = { admitted = None; closed = None; unobserved_scope = None }

let owner_order (a : owner) (b : owner) =
  compare
    (a.response_generation, a.response_scope)
    (b.response_generation, b.response_scope)

let admit t (response : Keeper_chat_events.text_response) =
  match response with
  | Keeper_chat_events.Unobserved_scope scope ->
    Option.iter (fun scope -> t.unobserved_scope <- Some scope) scope;
    Preserved_unobserved
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
    else begin
      t.admitted <- Some owner;
      t.unobserved_scope <- None;
      Admitted
    end

let retire_attempt t =
  (match t.admitted with
   | Some owner ->
     t.closed <- Some
       (match t.closed with
        | Some closed when owner_order closed owner >= 0 -> closed
        | Some _ | None -> owner)
   | None -> ());
  t.admitted <- None;
  t.unobserved_scope <- None
