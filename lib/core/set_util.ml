(** Hashtbl-as-set membership kernels. See [set_util.mli] for design rationale
    (Hashtbl over Set.Make: polymorphic key, single-edit future swap). *)

let default_capacity = 16

let of_list_with (key : 'a -> 'b) (xs : 'a list) : ('b, unit) Hashtbl.t =
  let tbl = Hashtbl.create default_capacity in
  List.iter (fun x -> Hashtbl.replace tbl (key x) ()) xs;
  tbl

let count_distinct (key : 'a -> 'b option) (xs : 'a list) : int =
  let seen : ('b, unit) Hashtbl.t = Hashtbl.create default_capacity in
  List.iter
    (fun x ->
      match key x with
      | Some k -> Hashtbl.replace seen k ()
      | None -> ())
    xs;
  Hashtbl.length seen

let count_difference (xs : 'a list)
    ~(present : 'a -> 'b option) ~(absent : 'a -> 'b option) : int =
  let absent_set : ('b, unit) Hashtbl.t = Hashtbl.create default_capacity in
  let present_set : ('b, unit) Hashtbl.t = Hashtbl.create default_capacity in
  List.iter
    (fun x ->
      (match absent x with
       | Some id -> Hashtbl.replace absent_set id ()
       | None -> ());
      match present x with
      | Some id -> Hashtbl.replace present_set id ()
      | None -> ())
    xs;
  Hashtbl.fold
    (fun id () acc -> if Hashtbl.mem absent_set id then acc else acc + 1)
    present_set 0
