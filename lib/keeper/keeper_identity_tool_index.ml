module Names = Set.Make (String)
type t = Names.t
let empty = Names.empty
let of_tools tools =
  List.fold_left
    (fun index (tool : Keeper_identity_tools.offered_tool) ->
      Names.add tool.schema.name index)
    empty tools
let mem t ~tool_name = Names.mem tool_name t
