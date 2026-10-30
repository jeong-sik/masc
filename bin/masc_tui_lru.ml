type ('key, 'value) node = {
  n_key : 'key;
  mutable n_value : 'value;
  mutable n_older : ('key, 'value) node option;
  mutable n_newer : ('key, 'value) node option;
}

type ('key, 'value) t = {
  capacity : int;
  table : ('key, ('key, 'value) node) Hashtbl.t;
  mutable newest : ('key, 'value) node option;
  mutable oldest : ('key, 'value) node option;
  mutable size : int;
}

let create ~capacity =
  if capacity <= 0 then invalid_arg "LRU capacity must be positive";
  { capacity;
    table = Hashtbl.create (min capacity 1024);
    newest = None;
    oldest = None;
    size = 0;
  }

let unlink t node =
  (match node.n_newer with
   | Some newer -> newer.n_older <- node.n_older
   | None -> t.newest <- node.n_older);
  (match node.n_older with
   | Some older -> older.n_newer <- node.n_newer
   | None -> t.oldest <- node.n_newer);
  node.n_newer <- None;
  node.n_older <- None

let link_as_newest t node =
  node.n_older <- t.newest;
  node.n_newer <- None;
  (match t.newest with Some newest -> newest.n_newer <- Some node | None -> ());
  t.newest <- Some node;
  if Option.is_none t.oldest then t.oldest <- Some node

let evict_oldest t =
  match t.oldest with
  | None -> ()
  | Some oldest ->
      unlink t oldest;
      Hashtbl.remove t.table oldest.n_key;
      t.size <- t.size - 1

let find t key =
  match Hashtbl.find_opt t.table key with
  | None -> None
  | Some node ->
      unlink t node;
      link_as_newest t node;
      Some node.n_value

let set t key value =
  match Hashtbl.find_opt t.table key with
  | Some node ->
      node.n_value <- value;
      unlink t node;
      link_as_newest t node
  | None ->
      let node = { n_key = key; n_value = value; n_older = None; n_newer = None } in
      Hashtbl.replace t.table key node;
      link_as_newest t node;
      t.size <- t.size + 1;
      if t.size > t.capacity then evict_oldest t

let size t = t.size

let keys_newest_first t =
  let rec walk acc = function
    | None -> List.rev acc
    | Some node -> walk (node.n_key :: acc) node.n_older
  in
  walk [] t.newest
