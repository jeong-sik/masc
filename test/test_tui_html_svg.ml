open Alcotest
module Document = Markup_document
module Html = Masc_tui_artifact_html

let xml source = match Document.parse_xml source with
  | Ok nodes -> nodes
  | Error detail -> fail detail

let element name nodes = match Document.first_element_named name nodes with
  | Some node -> node
  | None -> fail ("missing element " ^ name)

let attribute namespace name = function
  | Document.Element {attributes;_} -> List.assoc_opt (namespace,name) attributes
  | Text _ -> fail "expected element"

let svg_source (image : Html.image) = match image.source with
  | Embedded_svg source -> source
  | Embedded_base64 _ | Unavailable _ -> fail "expected inline SVG"

let unavailable (image : Html.image) = match image.source with
  | Unavailable _ -> ()
  | Embedded_base64 _ | Embedded_svg _ -> fail "expected unavailable image"

let test_detached_namespaces () =
  let source = "<root xmlns='urn:outer' xmlns:x='http://www.w3.org/1999/xlink'>"
    ^ "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 20 10'>"
    ^ "<use href='#plain' x:href='#linked' xml:space='preserve'/>"
    ^ "<g xmlns=''><text>A &amp; B &lt; C</text></g></svg></root>" in
  let svg = element "svg" (xml source) in
  let serialized = match Document.to_xml svg with Ok value -> value | Error e -> fail e in
  let nodes = xml serialized in
  let use = element "use" nodes in
  check (option string) "unqualified href stays separate" (Some "#plain")
    (Document.attribute "href" use);
  check (option string) "inherited XLink binding survives detachment" (Some "#linked")
    (attribute "http://www.w3.org/1999/xlink" "href" use);
  check (option string) "XML attribute namespace survives" (Some "preserve")
    (attribute "http://www.w3.org/XML/1998/namespace" "space" use);
  (match element "g" nodes with
   | Document.Element {namespace;_} -> check string "namespace reset" "" namespace
   | Text _ -> fail "expected g");
  check string "escaped text survives serialization" "A & B < C"
    (Document.text_content (element "text" nodes));
  let linked_only = element "a" (xml "<a xmlns:x='urn:other' x:href='foreign'/>") in
  check (option string) "qualified attribute cannot impersonate href" None
    (Document.attribute "href" linked_only)

let test_html_svg_sources () =
  let source = "<body><svg viewBox='0 0 20 10' width='20' height='10'>"
    ^ "<defs><rect id='bar' width='20' height='10'/></defs>"
    ^ "<use xlink:href='#bar' fill='#19a974'/></svg>"
    ^ "<div hidden><svg/></div><template><svg/></template>"
    ^ "<svg aria-hidden='true'/><canvas></canvas><img src='https://example.invalid/a.png'>"
    ^ "<svg><script>fetch('/secret')</script><use href='file:///secret'/></svg></body>" in
  match Html.images (Html.project source) with
  | [first;canvas;external_image;unsafe] ->
    unavailable canvas;
    unavailable external_image;
    let nodes = xml (svg_source first) in
    check (option string) "HTML5 SVG viewBox case" (Some "0 0 20 10")
      (Document.attribute "viewBox" (element "svg" nodes));
    check (option string) "implicit HTML5 XLink namespace" (Some "#bar")
      (attribute "http://www.w3.org/1999/xlink" "href" (element "use" nodes));
    (* Projection must not erase unsafe SVG into an apparently safe source.
       Offline acquisition is the validation authority. *)
    let unsafe = xml (svg_source unsafe) in
    check string "script retained for renderer refusal" "fetch('/secret')"
      (Document.text_content (element "script" unsafe));
    check (option string) "external reference retained for renderer refusal"
      (Some "file:///secret") (Document.attribute "href" (element "use" unsafe))
  | [] | _ :: _ -> fail "expected visible SVG roots, canvas and external image in source order"

let () = run "HTML SVG sources" ["semantic boundaries", [
  test_case "detached namespace and text identity" `Quick test_detached_namespaces;
  test_case "HTML SVG selection and validation handoff" `Quick test_html_svg_sources]]
