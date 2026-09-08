type kind = Template | Element
type location = { file : string; line : int; column : int; kind : kind; digest : string }
type t = Unmapped | Located of location | Invalid of string
let ( let* ) = Result.bind
let parse = function
  | `Assoc fields ->
      let* () = if List.length fields = 6 &&
        List.sort String.compare (List.map fst fields) = ["column";"digest";"file";"kind";"line";"schema"]
        then Ok () else Error "source context fields are incomplete or duplicated" in
      let string key = match List.assoc_opt key fields with
        | Some (`String value) -> Ok value | _ -> Error ("invalid source " ^ key) in
      let positive key = match List.assoc_opt key fields with
        | Some (`Int value) when value > 0 -> Ok value | _ -> Error ("invalid source " ^ key) in
      let* schema = string "schema" in
      let* () = if schema = "masc.source.v1" then Ok () else Error "unknown source context schema" in
      let* file = string "file" in
      let* () = if file <> "" && Filename.is_relative file
        && not (String.exists (fun ch -> Char.code ch < 32 || ch = '\\' || ch = ':') file)
        && List.for_all (fun part -> part <> "" && part <> "." && part <> "..") (String.split_on_char '/' file)
        then Ok () else Error "source path must be checkout-relative" in
      let* line = positive "line" in let* column = positive "column" in
      let* kind = string "kind" in
      let* kind = match kind with "template" -> Ok Template | "element" -> Ok Element
        | _ -> Error "unknown source location kind" in
      let* digest = string "digest" in
      let* () = if String.length digest = 64 && String.for_all
        (function '0'..'9' | 'a'..'f' -> true | _ -> false) digest
        then Ok () else Error "source digest must be SHA-256" in
      Ok {file;line;column;kind;digest}
  | _ -> Error "source context must be an object"
let of_json = function
  | `Null -> Unmapped
  | json -> match parse json with Ok source -> Located source | Error detail -> Invalid detail
let label = function
  | Unmapped -> "Source unavailable on this page"
  | Invalid detail -> "Invalid source context: " ^ detail
  | Located source -> Printf.sprintf "%s:%d:%d (%s; verify checkout hash)"
      source.file source.line source.column (match source.kind with Template -> "template" | Element -> "element")
