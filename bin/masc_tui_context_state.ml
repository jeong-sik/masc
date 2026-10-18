module Decode = Masc.Tui_decode
module Projection = Masc.Keeper_context_observation_projection
module Fetched = Masc_tui_fetched

type key = {
  scope : unit ref;
  base_path : string;
  keeper_name : string;
  identity : (string, string) result;
}

type request = key Fetched.request
type t = (key, Decode.context_observation) Fetched.t
type start_result = Already_loading | Started of t * request

let empty = Fetched.initial
let clear = Fetched.clear
let suspend = Fetched.suspend

let key_for_keeper ~scope ~base_path (keeper : Decode.keeper) =
  { scope; base_path; keeper_name = keeper.k_name;
    identity = Result.map (fun identity -> identity.Decode.k_trace_id) keeper.k_identity }

let same_key left right =
  left.scope == right.scope && String.equal left.base_path right.base_path
  && String.equal left.keeper_name right.keeper_name && left.identity = right.identity

let describe_key key = key.base_path, key.keeper_name, Result.to_option key.identity
let current_key = Fetched.current_key
let request_key = Fetched.request_key
let request_id = Fetched.request_id
let is_current state request = Fetched.is_current ~equal:same_key state request

let start state ~key =
  match Fetched.start ~equal:same_key state ~key with
  | Fetched.Already_loading -> Already_loading
  | Fetched.Started (state, request) -> Started (state, request)

let complete state request result = Fetched.complete ~equal:same_key state request result
let view state ~key = Fetched.view_for ~equal:same_key state ~key

let resolve_with ~project (keeper : Decode.keeper) =
  Result.bind keeper.k_identity (fun identity ->
      let json = project ~keeper_name:keeper.k_name ~current_trace_id:identity.k_trace_id
        |> fun fields -> `Assoc fields in
      Decode.decode_context_observation ~expected_trace_id:identity.k_trace_id json)

let load ~config =
  resolve_with ~project:(fun ~keeper_name ~current_trace_id ->
      Projection.context_fields ~config ~keeper_name ~current_trace_id)
