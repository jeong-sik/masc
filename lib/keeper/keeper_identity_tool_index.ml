module Names = Map.Make (String)
type t = bool option Names.t
let empty = Names.empty
let of_tools tools =
  List.fold_left
    (fun index (tool : Keeper_identity_tools.offered_tool) ->
      Names.add tool.schema.name tool.read_only index)
    empty tools
let read_only t ~tool_name = Names.find_opt tool_name t
