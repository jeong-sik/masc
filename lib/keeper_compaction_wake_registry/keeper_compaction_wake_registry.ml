module Key = struct
  type t = Keeper_id.Keeper_name.t

  let equal = Keeper_id.Keeper_name.equal
  let hash value = Hashtbl.hash (Keeper_id.Keeper_name.to_string value)
end

module Registrations = Hashtbl.Make (Key)

type registration_state =
  | Open of { pending : bool }
  | Closed

type t =
  { mutex : Stdlib.Mutex.t
  ; registrations : registration Registrations.t
  }

and registration =
  { owner : t
  ; keeper_name : Keeper_id.Keeper_name.t
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; mutable state : registration_state
  }

type register_error = Already_registered

type unregister_result =
  | Unregistered
  | Registration_not_current

type wake_result =
  | Signaled
  | Coalesced
  | Not_registered

type await_result =
  | Wake
  | Registration_closed

let create () =
  { mutex = Stdlib.Mutex.create (); registrations = Registrations.create 0 }
;;

let with_registry (t : t) f = Stdlib.Mutex.protect t.mutex f
let with_registration (registration : registration) f =
  Stdlib.Mutex.protect registration.mutex f
;;

let unregister registration =
  let removed =
    with_registry registration.owner (fun () ->
      match
        Registrations.find_opt
          registration.owner.registrations
          registration.keeper_name
      with
      | Some current when current == registration ->
        Registrations.remove
          registration.owner.registrations
          registration.keeper_name;
        true
      | Some _ | None -> false)
  in
  if removed
  then (
    with_registration registration (fun () -> registration.state <- Closed);
    Eio.Condition.broadcast registration.condition;
    Unregistered)
  else Registration_not_current
;;

let register ~sw owner keeper_name =
  Eio.Switch.check sw;
  let registration =
    { owner
    ; keeper_name
    ; mutex = Stdlib.Mutex.create ()
    ; condition = Eio.Condition.create ()
    ; state = Open { pending = false }
    }
  in
  let registered =
    with_registry owner (fun () ->
      match Registrations.find_opt owner.registrations keeper_name with
      | Some _ -> false
      | None ->
        Registrations.add owner.registrations keeper_name registration;
        true)
  in
  if registered
  then (
    Eio.Switch.on_release sw (fun () ->
      match unregister registration with
      | Unregistered | Registration_not_current -> ());
    Ok registration)
  else Error Already_registered
;;

let wake owner keeper_name =
  let result, notify =
    with_registry owner (fun () ->
      match Registrations.find_opt owner.registrations keeper_name with
      | None -> (Not_registered, None)
      | Some registration ->
        with_registration registration (fun () ->
          match registration.state with
          | Closed -> Not_registered, None
          | Open { pending = true } -> Coalesced, None
          | Open { pending = false } ->
            registration.state <- Open { pending = true };
            Signaled, Some registration.condition))
  in
  Option.iter Eio.Condition.broadcast notify;
  result
;;

let await registration =
  Eio.Condition.loop_no_mutex registration.condition (fun () ->
    with_registration registration (fun () ->
      match registration.state with
      | Closed -> Some Registration_closed
      | Open { pending = false } -> None
      | Open { pending = true } ->
        registration.state <- Open { pending = false };
        Some Wake))
;;
