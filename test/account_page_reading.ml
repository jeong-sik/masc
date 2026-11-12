module Doc = Markup_document

type login =
  | Open
  | Closed

type flaw =
  | No_form
  | Several_forms of int
  | No_submit_button
  | Several_submit_buttons of int
  | Not_rendered
  | No_description
  | Description_missing of string
  | Description_hidden of string
  | Description_blank

(* An element of HTML with this name. A [button] inside an [svg] is in another
   namespace and is no button. *)
let named name = function
  | Doc.Element element -> String.equal element.namespace Markup.Ns.html && String.equal element.name name
  | Doc.Text _ -> false
;;

let has name node = Option.is_some (Doc.attribute name node)

(* The keywords of an enumerated attribute compare without case. *)
let keyword name node = Option.map String.lowercase_ascii (Doc.attribute name node)

(* Every element under [nodes] in document order, each with the elements that
   hold it. *)
let rec elements ?(inside = []) nodes =
  List.concat_map
    (function
      | Doc.Text _ -> []
      | Doc.Element { children; _ } as node -> (node, inside) :: elements ~inside:(node :: inside) children)
    nodes
;;

(* A [hidden] attribute takes an element and everything in it off the page. *)
let rendered (node, inside) = not (List.exists (has "hidden") (node :: inside))

(* A button that submits the form that holds it to the route of that form.
   https://html.spec.whatwg.org/multipage/form-elements.html#the-button-element *)
let submits node =
  named "button" node
  && (match keyword "type" node with
      | Some ("button" | "reset") -> false
      | Some _ | None -> true)
  && not (List.exists (fun name -> has name node) [ "form"; "formaction"; "formmethod" ])
;;

(* A person cannot press a disabled button, nor one a disabled fieldset
   holds. HTML leaves the buttons of the first legend of such a fieldset
   enabled; this reads them as disabled too. *)
let disabled (node, inside) =
  has "disabled" node || List.exists (fun holder -> named "fieldset" holder && has "disabled" holder) inside
;;

(* What the button names as its description is in the page, on the page, and
   holds text. An id names the first element that has it. *)
let described all button =
  match Option.map Doc.html_space_tokens (Doc.attribute "aria-describedby" button) with
  | None | Some [] -> Error No_description
  | Some (_ :: _ as ids) ->
    let text_of id =
      match List.find_opt (fun (node, _) -> Doc.attribute "id" node = Some id) all with
      | None -> Error (Description_missing id)
      | Some target when not (rendered target) -> Error (Description_hidden id)
      | Some (node, _) -> Ok (Doc.text_content node)
    in
    let add text id = Result.bind text (fun text -> Result.map (fun more -> text ^ more) (text_of id)) in
    Result.bind (List.fold_left add (Ok "") ids) (fun text ->
      if String.equal (String.trim text) "" then Error Description_blank else Ok ())
;;

let login ~start page =
  let all = elements (Doc.parse_html page) in
  let posts_to_start (node, _) =
    named "form" node && keyword "method" node = Some "post" && Doc.attribute "action" node = Some start
  in
  match List.filter posts_to_start all with
  | [] -> Error No_form
  | _ :: _ :: _ as forms -> Error (Several_forms (List.length forms))
  | [ (form, _) ] ->
    (match List.filter (fun (node, inside) -> submits node && List.memq form inside) all with
     | [] -> Error No_submit_button
     | _ :: _ :: _ as buttons -> Error (Several_submit_buttons (List.length buttons))
     | [ button ] ->
       if not (rendered button)
       then Error Not_rendered
       else if disabled button
       then Result.map (fun () -> Closed) (described all (fst button))
       else Ok Open)
;;

let pp_login ppf = function
  | Open -> Format.pp_print_string ppf "open"
  | Closed -> Format.pp_print_string ppf "closed"
;;

let pp_flaw ppf = function
  | No_form -> Format.pp_print_string ppf "no form posts to the start route"
  | Several_forms count -> Format.fprintf ppf "%d forms post to the start route" count
  | No_submit_button -> Format.pp_print_string ppf "the form has no submit button"
  | Several_submit_buttons count -> Format.fprintf ppf "the form has %d submit buttons" count
  | Not_rendered -> Format.pp_print_string ppf "the form or its button is hidden"
  | No_description -> Format.pp_print_string ppf "the disabled button names no description"
  | Description_missing id -> Format.fprintf ppf "the button names %S, an id no element has" id
  | Description_hidden id -> Format.fprintf ppf "the description %S is hidden" id
  | Description_blank -> Format.pp_print_string ppf "the description holds no text"
;;

let outcome = Alcotest.result (Alcotest.testable pp_login ( = )) (Alcotest.testable pp_flaw ( = ))
