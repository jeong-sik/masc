module Decode = Masc.Tui_decode
module Projection = Masc.Keeper_context_observation_projection

type reading = {
  observation : Decode.context_observation option;
  error : string option;
}

type t =
  | Empty
  | Reading of {
      keeper_name : string;
      reading : reading;
    }

let empty = Empty

let reading_for_keeper ~keeper_name = function
  | Reading snapshot when String.equal snapshot.keeper_name keeper_name ->
      Some snapshot.reading
  | Empty | Reading _ -> None

let resolve_with ~project (keeper : Decode.keeper) =
  let json =
    project ~keeper_name:keeper.k_name ~current_trace_id:keeper.k_trace_id
    |> fun fields -> `Assoc fields
  in
  match
    Decode.decode_context_observation ~expected_trace_id:keeper.k_trace_id json
  with
  | Ok observation ->
      Reading
        { keeper_name = keeper.k_name;
          reading = { observation = Some observation; error = None };
        }
  | Error error ->
      Reading
        { keeper_name = keeper.k_name;
          reading = { observation = None; error = Some error };
        }

let load ~config =
  resolve_with ~project:(fun ~keeper_name ~current_trace_id ->
      Projection.context_fields ~config ~keeper_name ~current_trace_id)

let for_selection ~load = function
  | Some keeper -> load keeper
  | None -> empty
