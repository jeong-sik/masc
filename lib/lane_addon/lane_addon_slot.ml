module Lifecycle = Lane_addon_lifecycle
module Engine = Lane_addon_engine

type port = {
  read_engine : unit -> (Lifecycle.engine, Lifecycle.engine_fault) result;
  find : Engine.lookup -> (string option, string) result;
  inspect : string -> (Engine.held, string) result;
  remove : string -> (unit, string) result;
}

let ( let* ) = Result.bind

let fault_failure ~recorded = function
  | Lifecycle.Unreachable detail -> Lifecycle.Engine_unreachable detail
  | Lifecycle.Identity_unreadable detail ->
      Lifecycle.Engine_mismatch { recorded; observed = Lifecycle.Unreadable_engine detail }

let reaches port ~expected = match port.read_engine () with
  | Ok engine when Lifecycle.engine_equal engine expected -> Ok ()
  | Ok engine ->
      Error (Lifecycle.Engine_mismatch { recorded = expected; observed = Lifecycle.Other_engine engine })
  | Error fault -> Error (fault_failure ~recorded:expected fault)

let proven port ~expected ~lift work =
  let* () = reaches port ~expected |> Result.map_error lift in
  let* value = work () in
  let* () = reaches port ~expected |> Result.map_error lift in
  Ok value

type holder_class =
  | Mine
  | Predecessor of { instance_id : string; run_state : Engine.run_state }
  | Foreign of Lifecycle.holder

let holder_of (held : Engine.held) : Lifecycle.holder =
  { container_id = held.container_id; instance = held.instance; state_owner = held.state_owner }

(* This incarnation's own container: its instance label is this incarnation's
   unique ID and its owner label is the owner this worker was given. *)
let owns ~instance_id ~mine (held : Engine.held) =
  match held.instance with
  | Some instance -> String.equal instance instance_id && held.state_owner = mine
  | None -> false

let classify ~instance_id ~mine ~is_live_instance (held : Engine.held) =
  if owns ~instance_id ~mine held then Mine
  else match held.instance, held.state_owner, mine with
    | Some instance, Some owner, Some expected when String.equal owner expected ->
        (* Same installation, another incarnation. Only a dead one is removable. *)
        if is_live_instance instance then Foreign (holder_of held)
        else Predecessor { instance_id = instance; run_state = held.run_state }
    (* Every other pairing is another owner's container, an ephemeral name
       collision, or a container with no instance label. None is removable. *)
    | Some _, Some _, Some _ | Some _, Some _, None | Some _, None, Some _ | Some _, None, None
    | None, Some _, Some _ | None, Some _, None | None, None, Some _ | None, None, None ->
        Foreign (holder_of held)

let named_slot ~name (held : Engine.held) =
  if String.equal held.name name then Ok ()
  else Error ("the container under the slot name is called " ^ held.name)

let claim port ~name ~instance_id ~mine ~is_live_instance =
  let unreadable detail = Lifecycle.Worker_failed ("cannot read the container slot: " ^ detail) in
  let* found = port.find (Engine.Name name) |> Result.map_error unreadable in
  match found with
  | None -> Ok ()
  | Some id ->
      let* held = port.inspect id |> Result.map_error unreadable in
      let* () = named_slot ~name held |> Result.map_error unreadable in
      (match classify ~instance_id ~mine ~is_live_instance held with
       | Foreign holder -> Error (Lifecycle.Slot_foreign holder)
       | Mine ->
           port.remove id |> Result.map_error (fun detail -> Lifecycle.Cleanup_unconfirmed detail)
       | Predecessor { instance_id = predecessor; _ } ->
           port.remove id |> Result.map_error (fun detail ->
             Lifecycle.Slot_predecessor_unremovable { instance_id = predecessor; detail }))

let release port ~lookup ~instance_id ~mine =
  let unconfirmed detail = Lifecycle.Cleanup_unconfirmed detail in
  let* found = port.find lookup |> Result.map_error unconfirmed in
  match found with
  | None -> Ok ()
  | Some id ->
      let* held = port.inspect id |> Result.map_error unconfirmed in
      let* () = match lookup with
        | Engine.Name name -> named_slot ~name held |> Result.map_error unconfirmed
        | Engine.Id _ -> Ok () in
      if owns ~instance_id ~mine held then port.remove id |> Result.map_error unconfirmed
      else (match lookup with
        | Engine.Name _ -> Ok ()
        | Engine.Id _ -> Error (Lifecycle.Slot_foreign (holder_of held)))

let holder_changed port (holder : Lifecycle.holder) =
  match port.find (Engine.Id holder.container_id) with
  | Ok None -> true
  | Ok (Some id) ->
      (match port.inspect id with
       | Ok held -> holder_of held <> holder
       | Error _ -> false)
  | Error _ -> false
