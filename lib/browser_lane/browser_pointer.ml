type point = { x : float; y : float }
type viewport = { document_id : string; width : float; height : float;
  scroll_x : float; scroll_y : float }
let ( let* ) = Result.bind
let fields allowed = function
  | `Assoc fields when List.length fields = List.length allowed
      && List.sort String.compare (List.map fst fields) = List.sort String.compare allowed -> Ok fields
  | _ -> Error "pointer geometry has missing, duplicate or unknown fields"
let number key fields = match List.assoc_opt key fields with
  | Some (`Int value) -> Ok (float_of_int value)
  | Some (`Float value) when Float.is_finite value -> Ok value
  | _ -> Error ("pointer geometry requires finite " ^ key)
let point_of_json json =
  let* fields = fields ["x"; "y"] json in
  let* x = number "x" fields in let* y = number "y" fields in
  if x >= 0. && x < 1. && y >= 0. && y < 1. then Ok {x;y}
  else Error "pointer coordinates must be viewport fractions in [0,1)"
let viewport_of_json json =
  let* fields = fields ["documentId"; "width"; "height"; "scrollX"; "scrollY"] json in
  let* document_id = match List.assoc_opt "documentId" fields with
    | Some (`String id) when id <> "" -> Ok id | _ -> Error "viewport requires documentId" in
  let* width = number "width" fields in let* height = number "height" fields in
  let* scroll_x = number "scrollX" fields in let* scroll_y = number "scrollY" fields in
  if width > 0. && height > 0. then Ok {document_id;width;height;scroll_x;scroll_y}
  else Error "viewport dimensions must be positive"
let point_to_json point = `Assoc ["x",`Float point.x;"y",`Float point.y]
let viewport_to_json viewport = `Assoc ["documentId",`String viewport.document_id;
  "width",`Float viewport.width;"height",`Float viewport.height;
  "scrollX",`Float viewport.scroll_x;"scrollY",`Float viewport.scroll_y]
