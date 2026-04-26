(** Per-session discovered tool tracking with turn-based decay. *)

type entry =
  { name : string
  ; discovered_at_turn : int
  ; mutable last_active_turn : int
  }

type t =
  { entries : (string, entry) Hashtbl.t
  ; decay_turns : int
  }

let create ~decay_turns = { entries = Hashtbl.create 16; decay_turns = max 1 decay_turns }

let add t ~turn ~names =
  List.iter
    (fun name ->
       match Hashtbl.find_opt t.entries name with
       | Some e ->
         (* Re-adding resets the decay clock *)
         e.last_active_turn <- turn
       | None ->
         Hashtbl.replace
           t.entries
           name
           { name; discovered_at_turn = turn; last_active_turn = turn })
    names
;;

let mark_used t ~turn ~name =
  match Hashtbl.find_opt t.entries name with
  | Some e -> e.last_active_turn <- turn
  | None -> ()
;;

let is_active ~decay_turns ~turn (e : entry) = turn - e.last_active_turn <= decay_turns

let active_names t ~turn =
  Hashtbl.fold
    (fun _key (e : entry) acc ->
       if is_active ~decay_turns:t.decay_turns ~turn e then e.name :: acc else acc)
    t.entries
    []
;;

let decay t ~turn =
  let expired = ref [] in
  Hashtbl.filter_map_inplace
    (fun _key (e : entry) ->
       if is_active ~decay_turns:t.decay_turns ~turn e
       then Some e
       else (
         expired := e.name :: !expired;
         None))
    t.entries;
  !expired
;;

let count t = Hashtbl.length t.entries
let clear t = Hashtbl.clear t.entries

let to_json t =
  let entries =
    Hashtbl.fold
      (fun _key (e : entry) acc ->
         `Assoc
           [ "name", `String e.name
           ; "discovered_at_turn", `Int e.discovered_at_turn
           ; "last_active_turn", `Int e.last_active_turn
           ]
         :: acc)
      t.entries
      []
  in
  `Assoc
    [ "count", `Int (Hashtbl.length t.entries)
    ; "decay_turns", `Int t.decay_turns
    ; "entries", `List entries
    ]
;;
