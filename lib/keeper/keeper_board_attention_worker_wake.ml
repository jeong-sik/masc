type registration_state =
  | Open of { pending : bool }
  | Closed

type registration =
  { key : string
  ; mutex : Stdlib.Mutex.t
  ; condition : Eio.Condition.t
  ; mutable state : registration_state
  }

type wake_result =
  | Signaled
  | Coalesced
  | Not_registered

type await_result =
  | Wake
  | Registration_closed

let registry_mutex = Stdlib.Mutex.create ()
let registrations : (string, registration) Hashtbl.t = Hashtbl.create 16
let with_registry f = Stdlib.Mutex.protect registry_mutex f
let with_registration registration f = Stdlib.Mutex.protect registration.mutex f

let key ~base_path ~keeper_name =
  try Ok (Keeper_registry_types.registry_key ~base_path keeper_name) with
  | Invalid_argument detail -> Error detail
;;

let unregister registration =
  let removed =
    with_registry (fun () ->
      match Hashtbl.find_opt registrations registration.key with
      | Some current when current == registration ->
        Hashtbl.remove registrations registration.key;
        true
      | Some _ | None -> false)
  in
  if removed
  then (
    with_registration registration (fun () -> registration.state <- Closed);
    Eio.Condition.broadcast registration.condition)
;;

let register ~sw ~base_path ~keeper_name =
  Eio.Switch.check sw;
  match key ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok key ->
    let registration =
      { key
      ; mutex = Stdlib.Mutex.create ()
      ; condition = Eio.Condition.create ()
      ; state = Open { pending = false }
      }
    in
    let added =
      with_registry (fun () ->
        match Hashtbl.find_opt registrations key with
        | Some _ -> false
        | None ->
          Hashtbl.add registrations key registration;
          true)
    in
    if not added
    then Error ("Board attention worker is already registered: " ^ key)
    else (
      Eio.Switch.on_release sw (fun () -> unregister registration);
      Ok registration)
;;

let request ~base_path ~keeper_name =
  match key ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok key ->
    let result, notify =
      with_registry (fun () ->
        match Hashtbl.find_opt registrations key with
        | None -> Not_registered, None
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
    Ok result
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
