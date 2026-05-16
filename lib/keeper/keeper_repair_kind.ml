type t =
  | Dangling_tool_use
  | Orphan_tool_result

let to_label = function
  | Dangling_tool_use -> "dangling_tool_use"
  | Orphan_tool_result -> "orphan_tool_result"
;;
