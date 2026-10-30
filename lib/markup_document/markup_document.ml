type t =
  | Text of string
  | Element of {
      namespace : string;
      name : string;
      attributes : ((string * string) * string) list;
      children : t list;
    }

let node_of_text parts = Text (String.concat "" parts)

let node_of_element (namespace, name) attributes children =
  Element { namespace; name; attributes; children }

(* HTML parsing adjustments, not XML case folding. Markup 1.0.3 leaves these
   attribute tokens lowercased and exposes foreign prefixes as namespaces.
   https://html.spec.whatwg.org/multipage/parsing.html#adjust-svg-attributes *)
module Attribute_names = Map.Make (String)

let svg_attribute_names =
  [ "attributeName"; "attributeType"; "baseFrequency"; "baseProfile";
    "calcMode"; "clipPathUnits"; "diffuseConstant"; "edgeMode";
    "filterUnits"; "glyphRef"; "gradientTransform"; "gradientUnits";
    "kernelMatrix"; "kernelUnitLength"; "keyPoints"; "keySplines";
    "keyTimes"; "lengthAdjust"; "limitingConeAngle"; "markerHeight";
    "markerUnits"; "markerWidth"; "maskContentUnits"; "maskUnits";
    "numOctaves"; "pathLength"; "patternContentUnits"; "patternTransform";
    "patternUnits"; "pointsAtX"; "pointsAtY"; "pointsAtZ"; "preserveAlpha";
    "preserveAspectRatio"; "primitiveUnits"; "refX"; "refY"; "repeatCount";
    "repeatDur"; "requiredExtensions"; "requiredFeatures"; "specularConstant";
    "specularExponent"; "spreadMethod"; "startOffset"; "stdDeviation";
    "stitchTiles"; "surfaceScale"; "systemLanguage"; "tableValues";
    "targetX"; "targetY"; "textLength"; "viewBox"; "viewTarget";
    "xChannelSelector"; "yChannelSelector"; "zoomAndPan" ]
  |> List.to_seq |> Seq.map (fun name -> String.lowercase_ascii name, name)
  |> Attribute_names.of_seq

let html_element (namespace, name) attributes children =
  let foreign = namespace = Markup.Ns.svg || namespace = Markup.Ns.mathml in
  let adjust ((ns, local), value) =
    let qualified = if foreign then match ns, local with
      | "xlink", ("actuate" | "arcrole" | "href" | "role" | "show" | "title" | "type") ->
        Markup.Ns.xlink, local
      | "xml", ("lang" | "space") -> Markup.Ns.xml, local
      | "", "xmlns" | "xmlns", "xlink" -> Markup.Ns.xmlns, local
      | _ -> ns, local
    else ns, local in
    let ns, local = qualified in
    let local = if ns = "" && namespace = Markup.Ns.svg then
      match Attribute_names.find_opt local svg_attribute_names with
      | Some canonical -> canonical | None -> local
    else if ns = "" && namespace = Markup.Ns.mathml && local = "definitionurl"
    then "definitionURL" else local in
    (ns, local), value
  in
  node_of_element (namespace, name) (List.map adjust attributes) children

let trees ~element signals =
  Markup.trees ~text:node_of_text ~element signals
  |> Markup.to_list

let parse_html source =
  source |> Markup.string |> Markup.parse_html |> Markup.signals
  |> trees ~element:html_element

let parse_xml source =
  let first_error = ref None in
  let report location error =
    if Option.is_none !first_error then
      first_error := Some (Markup.Error.to_string ~location error)
  in
  let document = source |> Markup.string |> Markup.parse_xml ~report
    |> Markup.signals |> trees ~element:node_of_element in
  match !first_error with None -> Ok document | Some detail -> Error detail

let rec text_content = function
  | Text value -> value
  | Element { children; _ } ->
    children |> List.map text_content |> String.concat ""

let attribute key = function
  | Text _ -> None
  | Element { attributes; _ } -> List.assoc_opt ("", key) attributes

let to_xml node =
  let first_error = ref None in
  let report _ error =
    if Option.is_none !first_error then
      first_error := Some (Markup.Error.to_string error)
  in
  let xml_node = function
    | Text value -> `Text value
    | Element { namespace; name; attributes; children } ->
      (* A detached root may have inherited its declarations. Reconstruct
         declarations from expanded names at each element, including xmlns=""
         when leaving a default namespace. XML's own prefix is predefined. *)
      let attributes = List.filter (fun ((ns, _), _) -> ns <> Markup.Ns.xmlns) attributes in
      let namespaces = attributes |> List.filter_map (fun ((ns, _), _) ->
        if ns = "" || ns = Markup.Ns.xml then None else Some ns)
        |> List.sort_uniq String.compare in
      let declarations = namespaces |> List.mapi (fun index ns ->
        (Markup.Ns.xmlns, "ns" ^ string_of_int (index + 1)), ns) in
      let attributes = ((Markup.Ns.xmlns, "xmlns"), namespace)
        :: declarations @ attributes in
      `Element ((namespace, name), attributes, children)
  in
  let source = node |> Markup.from_tree xml_node |> Markup.write_xml ~report
    |> Markup.to_string in
  match !first_error with None -> Ok source | Some detail -> Error detail

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
