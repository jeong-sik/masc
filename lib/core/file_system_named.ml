type name =
  | Existing of string
  | Not_yet of string

(* [path] with its nearest existing ancestor named by the file system and the
   pieces below that ancestor as spelled. *)
let name_through_nearest_existing path =
  let rec resolve dir below =
    match Unix.realpath dir with
    | real -> List.fold_left Filename.concat real below
    | exception Unix.Unix_error _ ->
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then List.fold_left Filename.concat dir below
      else resolve parent (Filename.basename dir :: below)
  in
  resolve path []

let name path =
  match Unix.realpath path with
  | name -> Existing name
  | exception Unix.Unix_error _ -> Not_yet (name_through_nearest_existing path)

module Spellings = Map.Make (String)

(* The entry of each spelling whose file existed when the file system was
   asked. [removals] counts the times {!removed} was called; a removal
   empties the map. *)
type 'a remembered =
  { removals : int
  ; of_existing : 'a Spellings.t
  }

type 'a t =
  { make : unit -> 'a
  ; by_name : (string, 'a) Hashtbl.t
  ; by_name_mu : Stdlib.Mutex.t
  ; remembered : 'a remembered Atomic.t
  }

let create make =
  { make
  ; by_name = Hashtbl.create 16
  ; by_name_mu = Stdlib.Mutex.create ()
  ; remembered = Atomic.make { removals = 0; of_existing = Spellings.empty }
  }

let entry_named t name =
  Stdlib.Mutex.protect t.by_name_mu (fun () ->
    match Hashtbl.find_opt t.by_name name with
    | Some entry -> entry
    | None ->
      let entry = t.make () in
      Hashtbl.add t.by_name name entry;
      entry)

(* A name asked for before a removal is not remembered after it. *)
let rec remember_existing t ~removals spelling entry =
  let now = Atomic.get t.remembered in
  if now.removals = removals
     && not
          (Atomic.compare_and_set
             t.remembered
             now
             { now with of_existing = Spellings.add spelling entry now.of_existing })
  then remember_existing t ~removals spelling entry

type 'a resolved =
  { entry : 'a
  ; existed : bool
  ; removals : int
  }

let resolve t spelling =
  let seen = Atomic.get t.remembered in
  match Spellings.find_opt spelling seen.of_existing with
  | Some entry -> { entry; existed = true; removals = seen.removals }
  | None ->
    (match name spelling with
     | Existing name ->
       let entry = entry_named t name in
       remember_existing t ~removals:seen.removals spelling entry;
       { entry; existed = true; removals = seen.removals }
     | Not_yet name -> { entry = entry_named t name; existed = false; removals = seen.removals })

let another_entry_now t resolved spelling =
  if resolved.existed && (Atomic.get t.remembered).removals = resolved.removals
  then None
  else (
    let now = resolve t spelling in
    if now.entry == resolved.entry then None else Some now.entry)

let rec removed t =
  let now = Atomic.get t.remembered in
  if not
       (Atomic.compare_and_set
          t.remembered
          now
          { removals = now.removals + 1; of_existing = Spellings.empty })
  then removed t

let entries t =
  Stdlib.Mutex.protect t.by_name_mu (fun () ->
    Hashtbl.fold (fun _ entry entries -> entry :: entries) t.by_name [])

let has_entry t path =
  let (Existing name | Not_yet name) = name path in
  Stdlib.Mutex.protect t.by_name_mu (fun () -> Hashtbl.mem t.by_name name)
