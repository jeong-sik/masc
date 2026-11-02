open Masc_tui_types

(* Four levels is what a 120-column pane can indent and still leave a comment
   more room than its rail. Deeper replies keep the deepest rail: the order
   below still nests them under their parent, so the thread is intact even
   where the indent has stopped saying how deep it goes. *)
let max_depth = 4

let indent_cells = 2

let rail ~depth =
  String.make (indent_cells * max 0 (min depth max_depth)) ' '

module String_map = Map.Make (String)
module String_set = Set.Make (String)

(* Children by parent id, each in arrival order. Built once so the walk below
   is a lookup per comment rather than a scan of the whole page per comment --
   a 300-reply post is a real size here. *)
let children_by_parent comments =
  let table =
    List.fold_left
      (fun acc comment ->
        match comment.bc_parent_id with
        | None -> acc
        | Some parent ->
            let existing =
              Option.value (String_map.find_opt parent acc) ~default:[]
            in
            String_map.add parent (comment :: existing) acc)
      String_map.empty
      comments
  in
  String_map.map List.rev table

let order comments =
  let present =
    List.fold_left
      (fun acc comment -> String_set.add comment.bc_id acc)
      String_set.empty
      comments
  in
  let children = children_by_parent comments in
  (* A root is a comment with no parent, or one whose parent is not on this
     page: a reply whose parent expired under the board's TTL, or one the
     pagination cut. Drawing it at the top level keeps it visible, which is
     the point -- an orphan that renders nowhere is the failure this walk is
     written to avoid. *)
  let roots =
    List.filter
      (fun comment ->
        match comment.bc_parent_id with
        | None -> true
        | Some parent -> not (String_set.mem parent present))
      comments
  in
  (* [visited] is what makes this total. Two comments naming each other as
     parent are unreachable from any root, so the walk simply never reaches
     them -- but a self-parented comment is its own root, and without the mark
     it would descend forever. Rows the walk never reached are appended at the
     end rather than dropped, for the same reason an orphan is drawn. *)
  let rec walk depth comment (acc, visited) =
    if String_set.mem comment.bc_id visited then (acc, visited)
    else
      let visited = String_set.add comment.bc_id visited in
      let acc = (depth, comment) :: acc in
      Option.value (String_map.find_opt comment.bc_id children) ~default:[]
      |> List.fold_left
           (fun state child -> walk (depth + 1) child state)
           (acc, visited)
  in
  let ordered, visited =
    List.fold_left
      (fun state root -> walk 0 root state)
      ([], String_set.empty)
      roots
  in
  let unreached =
    List.filter_map
      (fun comment ->
        if String_set.mem comment.bc_id visited then None else Some (0, comment))
      comments
  in
  List.rev ordered @ unreached
