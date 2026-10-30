(** Tool Set: composable, deduplicated tool collections.

    Internal representation: ordered list + name→index map for O(1) lookup.
    List is maintained in insertion order; merge appends right-hand tools,
    overwriting on name conflict (last-writer-wins). *)

(** Map from tool name to tool. Preserves insertion order via list. *)
type t =
  { tools : Tool.t list
  ; by_name : (string, Tool.t) Hashtbl.t
  }

type dep_error =
  | DuplicateName of string
  | EmptyName

let empty = { tools = []; by_name = Hashtbl.create 0 }

let singleton tool =
  let by_name = Hashtbl.create 1 in
  Hashtbl.replace by_name tool.Tool.schema.Types.name tool;
  { tools = [ tool ]; by_name }
;;

let of_list tools =
  let by_name = Hashtbl.create (List.length tools) in
  (* Last occurrence wins: iterate forward, replace keeps last *)
  List.iter (fun (tool : Tool.t) -> Hashtbl.replace by_name tool.schema.name tool) tools;
  (* Rebuild list from hashtbl to deduplicate, preserving last occurrence *)
  let seen = Hashtbl.create (Hashtbl.length by_name) in
  let deduped =
    List.rev tools
    |> List.filter_map (fun (tool : Tool.t) ->
      let name = tool.schema.name in
      if Hashtbl.mem seen name
      then None
      else (
        Hashtbl.replace seen name ();
        Some (Hashtbl.find by_name name)))
    |> List.rev
  in
  { tools = deduped; by_name }
;;

let merge left right = of_list (left.tools @ right.tools)

let concat sets =
  let all_tools = List.concat_map (fun s -> s.tools) sets in
  of_list all_tools
;;

let to_list set = set.tools
let find name set = Hashtbl.find_opt set.by_name name
let mem name set = Hashtbl.mem set.by_name name
let size set = List.length set.tools
let names set = List.map (fun (t : Tool.t) -> t.schema.Types.name) set.tools

let validate set =
  let errors = ref [] in
  List.iter
    (fun (tool : Tool.t) -> if tool.schema.name = "" then errors := EmptyName :: !errors)
    set.tools;
  (* Check internal consistency: list length = hashtbl size *)
  if List.length set.tools <> Hashtbl.length set.by_name
  then (
    let seen = Hashtbl.create 16 in
    List.iter
      (fun (tool : Tool.t) ->
         let name = tool.schema.name in
         if Hashtbl.mem seen name then errors := DuplicateName name :: !errors;
         Hashtbl.replace seen name ())
      set.tools);
  match !errors with
  | [] -> Ok ()
  | errs -> Error (List.rev errs)
;;
