(** Tool Set: composable, deduplicated tool collections.

    Internal representation: ordered list + name→index map for O(1) lookup.
    List is maintained in insertion order; merge appends right-hand tools,
    overwriting on name conflict (last-writer-wins). *)

module Tool_map = Map.Make (String)
module Name_set = Set.Make (String)

(** Map from tool name to tool. Preserves insertion order via list. *)
type t =
  { tools : Tool.t list
  ; by_name : Tool.t Tool_map.t
  }

type dep_error =
  | DuplicateName of string
  | EmptyName

let empty = { tools = []; by_name = Tool_map.empty }

let singleton tool =
  let by_name = Tool_map.singleton tool.Tool.schema.Types.name tool in
  { tools = [ tool ]; by_name }
;;

let of_list tools =
  (* Last occurrence wins: iterate forward, add keeps last *)
  let by_name =
    List.fold_left
      (fun acc (tool : Tool.t) -> Tool_map.add tool.schema.name tool acc)
      Tool_map.empty
      tools
  in
  (* Rebuild list from map to deduplicate, preserving last occurrence *)
  let _, deduped =
    List.fold_left
      (fun (seen, acc) (tool : Tool.t) ->
         let name = tool.schema.name in
         if Name_set.mem name seen
         then seen, acc
         else Name_set.add name seen, Tool_map.find name by_name :: acc)
      (Name_set.empty, [])
      (List.rev tools)
  in
  { tools = deduped; by_name }
;;

let merge left right = of_list (left.tools @ right.tools)

let to_list set = set.tools
let find name set = Tool_map.find_opt name set.by_name
let mem name set = Tool_map.mem name set.by_name
let size set = List.length set.tools
let names set = List.map (fun (t : Tool.t) -> t.schema.Types.name) set.tools

let validate set =
  let errors = ref [] in
  List.iter
    (fun (tool : Tool.t) -> if tool.schema.name = "" then errors := EmptyName :: !errors)
    set.tools;
  (* Check internal consistency: list length = map size *)
  if List.length set.tools <> Tool_map.cardinal set.by_name
  then (
    let _ =
      List.fold_left
        (fun seen (tool : Tool.t) ->
           let name = tool.schema.name in
           if Name_set.mem name seen then errors := DuplicateName name :: !errors;
           Name_set.add name seen)
        Name_set.empty
        set.tools
    in
    ());
  match !errors with
  | [] -> Ok ()
  | errs -> Error (List.rev errs)
;;
