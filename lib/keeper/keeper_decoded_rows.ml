type 'line kept =
  { rows : string
  ; lines : 'line list
  ; read_at : int
  }

type 'line t =
  { budget_bytes : int
  ; stores : (string, 'line kept) Hashtbl.t
  ; lock : Stdlib.Mutex.t
  ; mutable kept_bytes : int
  ; mutable reads : int
  }

let initial_store_slots = 64

let create ~budget_bytes =
  if budget_bytes < 0 then invalid_arg "Keeper_decoded_rows.create: budget_bytes is negative";
  { budget_bytes
  ; stores = Hashtbl.create initial_store_slots
  ; lock = Stdlib.Mutex.create ()
  ; kept_bytes = 0
  ; reads = 0
  }
;;

let kept_bytes t = Stdlib.Mutex.protect t.lock (fun () -> t.kept_bytes)

let forget_locked t path =
  match Hashtbl.find_opt t.stores path with
  | None -> ()
  | Some kept ->
    Hashtbl.remove t.stores path;
    t.kept_bytes <- t.kept_bytes - String.length kept.rows
;;

let forget t ~path = Stdlib.Mutex.protect t.lock (fun () -> forget_locked t path)

let read_longest_ago t =
  Hashtbl.fold
    (fun path kept oldest ->
       match oldest with
       | Some (_, read_at) when read_at <= kept.read_at -> oldest
       | Some _ | None -> Some (path, kept.read_at))
    t.stores
    None
;;

let rec drop_to_budget t =
  if t.kept_bytes > t.budget_bytes
  then (
    match read_longest_ago t with
    | None -> ()
    | Some (path, _) ->
      forget_locked t path;
      drop_to_budget t)
;;

(* The store just read is the newest, so it is the last one dropped, and it
   fits the budget by itself: the loop ends with it kept. *)
let keep t ~path ~rows ~lines =
  Stdlib.Mutex.protect t.lock (fun () ->
    forget_locked t path;
    if String.length rows <= t.budget_bytes
    then (
      t.reads <- t.reads + 1;
      Hashtbl.replace t.stores path { rows; lines; read_at = t.reads };
      t.kept_bytes <- t.kept_bytes + String.length rows;
      drop_to_budget t))
;;

let lines t ~path ~rows ~decode =
  let known = Stdlib.Mutex.protect t.lock (fun () -> Hashtbl.find_opt t.stores path) in
  let lines =
    match known with
    | Some known when String.equal known.rows rows -> known.lines
    | Some known when String.starts_with ~prefix:known.rows rows ->
      let known_bytes = String.length known.rows in
      let appended = String.sub rows known_bytes (String.length rows - known_bytes) in
      known.lines @ decode ~after:(List.length known.lines) appended
    | Some _ | None -> decode ~after:0 rows
  in
  keep t ~path ~rows ~lines;
  lines
;;
