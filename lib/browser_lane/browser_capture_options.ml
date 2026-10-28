type scale = Css
type clip = { x : float; y : float; width : float; height : float; scale : float option }
type t = { full_page : bool option; clip : clip option; scale : scale option; raw : bool option }
open Result.Syntax
let fields allowed = function
  | `Assoc fields when List.for_all (fun (key,_) -> List.mem key allowed) fields
      && List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | _ -> Error "invalid, unknown or duplicate native screenshot options"
let number = function
  | `Int n -> Ok (float_of_int n)
  | `Float n when Float.is_finite n -> Ok n
  | _ -> Error "native screenshot coordinates must be finite numbers"
let positive value =
  let* value=number value in
  if value>0. then Ok value else Error "native screenshot size and clip scale must be positive"
let optional parse key fields = match List.assoc_opt key fields with
  | None -> Ok None | Some value -> Result.map Option.some (parse value)
let required parse key fields =
  let* value=Option.to_result ~none:("missing screenshot clip " ^ key) (List.assoc_opt key fields) in
  parse value
let boolean = function `Bool b -> Ok b | _ -> Error "native screenshot flags must be boolean"
let clip_of_json value =
  let* f=fields ["x";"y";"width";"height";"scale"] value in
  let* x=required number "x" f in let* y=required number "y" f in
  let* width=required positive "width" f in let* height=required positive "height" f in
  let* scale=optional positive "scale" f in Ok {x;y;width;height;scale}
let of_json value =
  let* f=fields ["fullPage";"clip";"scale";"raw"] value in
  let* full_page=optional boolean "fullPage" f in
  let* clip=optional clip_of_json "clip" f in
  let* scale=optional (function `String "css" -> Ok Css | _ -> Error "native screenshot scale must be css") "scale" f in
  let* raw=optional boolean "raw" f in Ok {full_page;clip;scale;raw}
let of_optional_json = function None -> Ok None | Some value -> Result.map Option.some (of_json value)
let to_json t =
  `Assoc (List.filter_map Fun.id [
    Option.map (fun value -> "fullPage",`Bool value) t.full_page;
    Option.map (fun (c:clip) -> "clip",`Assoc (["x",`Float c.x;"y",`Float c.y;
      "width",`Float c.width;"height",`Float c.height]
      @ Option.to_list (Option.map (fun s -> "scale",`Float s) c.scale))) t.clip;
    Option.map (fun Css -> "scale",`String "css") t.scale;
    Option.map (fun value -> "raw",`Bool value) t.raw])
