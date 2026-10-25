module Observation = Agent_core.Base.Schema_observation

module Descriptors = Ephemeron.K1.Make (struct
  type t = Keeper_tool_descriptor.t
  let equal left right = left == right
  (* The immutable id selects a bucket; equality remains physical identity. *)
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end)

module Owners = Ephemeron.K1.Make (struct
  type t = Lane_addon_tool_export.owner
  let equal = Lane_addon_tool_export.equal_owner
  let hash _ = 0
end)

let descriptors = Descriptors.create 128
let owners = Owners.create 16
let mutex = Mutex.create ()

let locked operation =
  Mutex.lock mutex;
  Fun.protect operation ~finally:(fun () -> Mutex.unlock mutex)

let descriptor_id descriptor =
  match locked (fun () -> Descriptors.find_opt descriptors descriptor) with
  | Some id -> Some id
  | None ->
    (* The SDK allocates identities outside this adapter's mutex. Recheck the
       winner before publication; no observer operation runs under this lock. *)
    match Observation.fresh_object_id () with
    | None -> None
    | Some fresh ->
      Some (locked (fun () ->
        match Descriptors.find_opt descriptors descriptor with
        | Some existing -> existing
        | None -> Descriptors.add descriptors descriptor fresh; fresh))

let owner_id owner =
  match locked (fun () -> Owners.find_opt owners owner) with
  | Some id -> Some id
  | None ->
    match Observation.fresh_object_id () with
    | None -> None
    | Some fresh ->
      Some (locked (fun () ->
        match Owners.find_opt owners owner with
        | Some existing -> existing
        | None -> Owners.add owners owner fresh; fresh))

let with_definition descriptor operation =
  let definition = Observation.observer_work (fun () ->
    Option.map (fun descriptor_id ->
      let addon_owner_id = match descriptor.Keeper_tool_descriptor.runtime_handler with
        | Tool_lane_addon export -> owner_id export.Lane_addon_tool_export.owner
        | _ -> None in
      descriptor_id, addon_owner_id) (descriptor_id descriptor))
  in
  match definition with
  | None -> operation ()
  | Some (descriptor_id, addon_owner_id) ->
    Observation.with_definition ~descriptor_id ~addon_owner_id operation
