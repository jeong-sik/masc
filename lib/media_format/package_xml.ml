type name = string * string

type element =
  { name : name
  ; attributes : (name * string) list
  ; depth : int
  }

let compare_name (namespace, local) (namespace', local') =
  match String.compare namespace namespace' with
  | 0 -> String.compare local local'
  | order -> order
;;

(* xmlm does not refuse an attribute written twice (XML 1.0 §3.1, "Unique
   Att Spec"). Sorting finds one in n log n steps whatever the names are. *)
let repeated_attribute attributes =
  let rec adjacent = function
    | first :: (second :: _ as rest) ->
      if compare_name first second = 0 then Some first else adjacent rest
    | [] | [ _ ] -> None
  in
  adjacent (List.sort compare_name (List.map fst attributes))
;;

let elements source =
  let input = Xmlm.make_input ~strip:true (`String (0, source)) in
  (* [open_elements] counts the elements started and not yet ended. *)
  let rec read open_elements found =
    match Xmlm.input input with
    | `Dtd None | `Data _ -> read open_elements found
    | `Dtd (Some _) ->
      (* xmlm keeps the declaration as text and expands none of its
         entities. .NET's System.IO.Packaging reads [_rels/.rels] with
         XmlReader defaults, which refuse a declaration, and none of the
         520 HWPX manifests in the L2 survey has one. *)
      Error "the part declares a document type"
    | `El_start (name, attributes) ->
      (match repeated_attribute attributes with
       | Some (namespace, local) ->
         Error (Printf.sprintf "one element has the attribute {%s}%s twice" namespace local)
       | None -> read (open_elements + 1) ({ name; attributes; depth = open_elements } :: found))
    | `El_end ->
      if open_elements > 1
      then read (open_elements - 1) found
      else if Xmlm.eoi input
      then Ok (List.rev found)
      else Error "markup follows the root element"
  in
  match read 0 [] with
  | result -> result
  | exception Xmlm.Error ((line, column), error) ->
    Error (Printf.sprintf "%d:%d: %s" line column (Xmlm.error_message error))
;;

let attribute key element =
  List.find_map
    (fun ((namespace, local), value) ->
       if String.equal namespace "" && String.equal local key then Some value else None)
    element.attributes
;;
