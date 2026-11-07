module Schemas = Ephemeron.K1.Make (struct
  type t = Keeper_tool_descriptor.t

  let equal left right = left == right
  let hash descriptor = Hashtbl.hash descriptor.Keeper_tool_descriptor.id
end)

let schemas : Agent_core.Types.tool_schema Schemas.t = Schemas.create 0
let mutex = Stdlib.Mutex.create ()

let memoizes descriptor =
  match
    Keeper_tool_descriptor.lane_addon_export
      descriptor.Keeper_tool_descriptor.runtime_handler
  with
  | Some _ -> false
  | None -> true

let construct descriptor =
  match Keeper_tool_descriptor.keeper_model_names descriptor with
  | [name] ->
    Agent_core.Base.Schema_observation.constructor
      ~site:Bridge_execution_env_constructor
      (fun () ->
        Agent_core.Types.tool_schema_of_input_schema
          ~name
          ~description:descriptor.Keeper_tool_descriptor.description
          ~input_schema:descriptor.input_schema
          ())
  | [] -> Error "Keeper descriptor has no model-visible schema"
  | _ :: _ :: _ -> Error "Keeper descriptor has more than one model-visible name"

let for_descriptor descriptor =
  if not (memoizes descriptor) then construct descriptor
  else
    match Stdlib.Mutex.protect mutex (fun () -> Schemas.find_opt schemas descriptor) with
    | Some schema -> Ok schema
    | None ->
      (* Validation and diagnostic callbacks never run under the cache lock.
         The descriptor remains live through the locked publication recheck. *)
      match construct descriptor with
      | Error _ as error -> error
      | Ok candidate ->
        Ok (Stdlib.Mutex.protect mutex (fun () ->
          match Schemas.find_opt schemas descriptor with
          | Some winner -> winner
          | None -> Schemas.add schemas descriptor candidate; candidate))
