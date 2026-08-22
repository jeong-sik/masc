module Decode = Masc.Tui_decode
module Projection = Masc.Keeper_context_observation_projection

type t = {
  observation : Decode.context_observation option;
  error : string option;
}

let empty = { observation = None; error = None }

let resolve_with ~project (keeper : Decode.keeper) =
  let json =
    project ~keeper_name:keeper.k_name ~current_trace_id:keeper.k_trace_id
    |> fun fields -> `Assoc fields
  in
  match
    Decode.decode_context_observation ~expected_trace_id:keeper.k_trace_id json
  with
  | Ok observation -> { observation = Some observation; error = None }
  | Error error -> { observation = None; error = Some error }

let load ~config =
  resolve_with ~project:(fun ~keeper_name ~current_trace_id ->
      Projection.context_fields ~config ~keeper_name ~current_trace_id)

let for_selection ~load = function
  | Some keeper -> load keeper
  | None -> empty
