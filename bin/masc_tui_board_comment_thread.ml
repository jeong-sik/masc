open Masc_tui_types

(* Four levels is what a 120-column pane can indent and still leave a comment
   more room than its rail. Deeper replies keep the deepest rail: the order
   below still nests them under their parent, so the thread is intact even
   where the indent has stopped saying how deep it goes. *)
let max_depth = 4

let indent_cells = 2

let rail ~depth =
  String.make (indent_cells * max 0 (min depth max_depth)) ' '

(* Children by parent id, each in arrival order. Built once so the walk below
   is a lookup per comment rather than a scan of the whole page per comment --
   a 300-reply post is a real size here. *)
let children_by_parent comments =
  let table = Hashtbl.create 64 in
  List.iter
    (fun comment ->
      match comment.bc_parent_id with
      | None -> ()
      | Some parent ->
          let existing =
            Option.value (Hashtbl.find_opt table parent) ~default:[]
          in
          Hashtbl.replace table parent (comment :: existing))
    comments;
  Hashtbl.iter (fun parent kids -> Hashtbl.replace table parent (List.rev kids))
    table;
  table

let order comments =
  let present = Hashtbl.create 64 in
  List.iter (fun comment -> Hashtbl.replace present comment.bc_id ()) comments;
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
        | Some parent -> not (Hashtbl.mem present parent))
      comments
  in
  (* [visited] is what makes this total. Two comments naming each other as
     parent are unreachable from any root, so the walk simply never reaches
     them -- but a self-parented comment is its own root, and without the mark
     it would descend forever. Rows the walk never reached are appended at the
     end rather than dropped, for the same reason an orphan is drawn. *)
  let visited = Hashtbl.create 64 in
  let rec walk depth comment acc =
    if Hashtbl.mem visited comment.bc_id then acc
    else begin
      Hashtbl.replace visited comment.bc_id ();
      let acc = (depth, comment) :: acc in
      Option.value (Hashtbl.find_opt children comment.bc_id) ~default:[]
      |> List.fold_left (fun acc child -> walk (depth + 1) child acc) acc
    end
  in
  let ordered = List.fold_left (fun acc root -> walk 0 root acc) [] roots in
  let unreached =
    List.filter_map
      (fun comment ->
        if Hashtbl.mem visited comment.bc_id then None else Some (0, comment))
      comments
  in
  List.rev ordered @ unreached
