type t =
  | Text of string
  | Element of {
      namespace : string;
      name : string;
      attributes : (string * string) list;
      children : t list;
    }

let node_of_text parts = Text (String.concat "" parts)

let node_of_element (namespace, name) attributes children =
  let attributes =
    List.map (fun ((_, name), value) -> name, value) attributes
  in
  Element { namespace; name; attributes; children }

let trees signals =
  Markup.trees ~text:node_of_text ~element:node_of_element signals
  |> Markup.to_list

let parse_html source =
  source |> Markup.string |> Markup.parse_html |> Markup.signals |> trees

let rec text_content = function
  | Text value -> value
  | Element { children; _ } ->
    children |> List.map text_content |> String.concat ""

let attribute key = function
  | Text _ -> None
  | Element { attributes; _ } -> List.assoc_opt key attributes

let rec elements_named name nodes =
  List.concat_map
    (function
      | Text _ -> []
      | (Element element as node) ->
        let nested = elements_named name element.children in
        if String.equal element.name name then node :: nested else nested)
    nodes

let rec first_element_named name = function
  | [] -> None
  | Text _ :: rest -> first_element_named name rest
  | (Element element as node) :: rest ->
    if String.equal element.name name
    then Some node
    else (
      match first_element_named name element.children with
      | Some _ as found -> found
      | None -> first_element_named name rest)

let html_space_tokens value =
  let is_html_space = function
    | ' ' | '\t' | '\n' | '\012' | '\r' -> true
    | _ -> false
  in
  let buffer = Buffer.create 16 in
  let tokens = ref [] in
  let flush () =
    if Buffer.length buffer > 0
    then (
      tokens := Buffer.contents buffer :: !tokens;
      Buffer.clear buffer)
  in
  String.iter
    (fun character ->
       if is_html_space character then flush () else Buffer.add_char buffer character)
    value;
  flush ();
  List.rev !tokens
