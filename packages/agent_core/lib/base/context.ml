(** Cross-turn shared state for agent execution.
    Inspired by Google ADK's session.state pattern.

    Uses Hashtbl internally, protected by either Eio.Mutex for Eio agent hot
    paths or Stdlib.Mutex for synchronous tests/serialization code.
    Values are Yojson.Safe.t for flexibility while maintaining serializability. *)

type mutex =
  | Stdlib_mu of Mutex.t
  | Eio_mu of Eio.Mutex.t

type t =
  { mu : mutex
  ; tbl : (string, Yojson.Safe.t) Hashtbl.t
  }

type scope =
  | App
  | User
  | Session
  | Temp
  | Custom of string

type diff =
  { added : (string * Yojson.Safe.t) list
  ; removed : string list
  ; changed : (string * Yojson.Safe.t) list
  }

type concurrency_backend =
  | Stdlib_mutex
  | Eio_mutex

let create () : t = { mu = Eio_mu (Eio.Mutex.create ()); tbl = Hashtbl.create 16 }
let create_sync () : t = { mu = Stdlib_mu (Mutex.create ()); tbl = Hashtbl.create 16 }

let is_eio_backed ctx =
  match ctx.mu with
  | Eio_mu _ -> true
  | Stdlib_mu _ -> false
;;

let concurrency_backend ctx = if is_eio_backed ctx then Eio_mutex else Stdlib_mutex

let with_lock ctx f =
  match ctx.mu with
  | Stdlib_mu mu ->
    Mutex.lock mu;
    Fun.protect f ~finally:(fun () -> Mutex.unlock mu)
  | Eio_mu mu -> Eio.Mutex.use_rw ~protect:true mu f
;;

let get (ctx : t) key = with_lock ctx (fun () -> Hashtbl.find_opt ctx.tbl key)
let set (ctx : t) key value = with_lock ctx (fun () -> Hashtbl.replace ctx.tbl key value)
let delete (ctx : t) key = with_lock ctx (fun () -> Hashtbl.remove ctx.tbl key)

let keys (ctx : t) =
  with_lock ctx (fun () -> Hashtbl.fold (fun k _ acc -> k :: acc) ctx.tbl [])
;;

let snapshot (ctx : t) =
  with_lock ctx (fun () ->
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) ctx.tbl []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b))
;;

let scope_prefix = function
  | App -> "app:"
  | User -> "user:"
  | Session -> "session:"
  | Temp -> "temp:"
  | Custom raw ->
    let raw = String.trim raw in
    if raw = ""
    then "custom:"
    else if String.ends_with ~suffix:":" raw
    then raw
    else raw ^ ":"
;;

let scoped_key scope key = scope_prefix scope ^ key
let get_scoped (ctx : t) scope key = get ctx (scoped_key scope key)
let set_scoped (ctx : t) scope key value = set ctx (scoped_key scope key) value
let delete_scoped (ctx : t) scope key = delete ctx (scoped_key scope key)

let keys_in_scope (ctx : t) scope =
  let prefix = scope_prefix scope in
  let prefix_len = String.length prefix in
  with_lock ctx (fun () ->
    Hashtbl.fold (fun k _ acc -> k :: acc) ctx.tbl []
    |> List.filter_map (fun key ->
      if String.length key >= prefix_len && String.sub key 0 prefix_len = prefix
      then Some (String.sub key prefix_len (String.length key - prefix_len))
      else None)
    |> List.sort String.compare)
;;

let merge (ctx : t) (pairs : (string * Yojson.Safe.t) list) =
  with_lock ctx (fun () -> List.iter (fun (k, v) -> Hashtbl.replace ctx.tbl k v) pairs)
;;

let diff before after =
  let json_equal a b = a == b || Yojson.Safe.equal a b in
  let rec walk before_items after_items added removed changed =
    match before_items, after_items with
    | [], [] ->
      { added = List.rev added; removed = List.rev removed; changed = List.rev changed }
    | [], (key, value) :: after_tail ->
      walk [] after_tail ((key, value) :: added) removed changed
    | (key, _) :: before_tail, [] -> walk before_tail [] added (key :: removed) changed
    | ( ((before_key, before_value) :: before_tail as before_all)
      , ((after_key, after_value) :: after_tail as after_all) ) ->
      let order = String.compare before_key after_key in
      if order = 0
      then (
        let changed =
          if json_equal before_value after_value
          then changed
          else (after_key, after_value) :: changed
        in
        walk before_tail after_tail added removed changed)
      else if order < 0
      then walk before_tail after_all added (before_key :: removed) changed
      else walk before_all after_tail ((after_key, after_value) :: added) removed changed
  in
  walk (snapshot before) (snapshot after) [] [] []
;;

let to_json (ctx : t) : Yojson.Safe.t =
  let pairs = snapshot ctx in
  `Assoc pairs
;;

let of_json ?(eio = false) (json : Yojson.Safe.t) : t =
  match json with
  | `Assoc pairs ->
    let ctx = if eio then create () else create_sync () in
    List.iter (fun (k, v) -> Hashtbl.replace ctx.tbl k v) pairs;
    ctx
  | _ -> invalid_arg "Context.of_json: expected JSON object"
;;

let copy ?eio (ctx : t) : t =
  with_lock ctx (fun () ->
    let use_eio =
      match eio with
      | Some value -> value
      | None -> is_eio_backed ctx
    in
    let new_ctx = if use_eio then create () else create_sync () in
    Hashtbl.iter (fun k v -> Hashtbl.replace new_ctx.tbl k v) ctx.tbl;
    new_ctx)
;;

(* ── Scoped isolation for sub-agent delegation ───────────────── *)

(** An isolated scope for sub-agent execution.
    [parent] is the parent context (read-only reference).
    [local] is the sub-agent's working context.
    [propagate_up] lists keys that should be merged back to parent.
    [propagate_down] lists keys inherited from parent at creation. *)
type isolated_scope =
  { parent : t
  ; local : t
  ; propagate_up : string list
  ; propagate_down : string list
  }

(** Create an isolated scope from a parent context.
    Only keys listed in [propagate_down] are copied to the local context.
    Reads from parent under lock, then populates new local context. *)
let create_scope ~parent ~propagate_down ~propagate_up =
  let local = if is_eio_backed parent then create () else create_sync () in
  let pairs =
    with_lock parent (fun () ->
      List.filter_map
        (fun key ->
           match Hashtbl.find_opt parent.tbl key with
           | Some v -> Some (key, v)
           | None -> None)
        propagate_down)
  in
  List.iter (fun (k, v) -> Hashtbl.replace local.tbl k v) pairs;
  { parent; local; propagate_up; propagate_down }
;;

(** Merge specified keys from the local context back into the parent.
    Only keys listed in [propagate_up] are merged.
    Collects local values, then writes to parent under a single lock. *)
let merge_back scope =
  let pairs =
    with_lock scope.local (fun () ->
      List.filter_map
        (fun key ->
           match Hashtbl.find_opt scope.local.tbl key with
           | Some v -> Some (key, v)
           | None -> None)
        scope.propagate_up)
  in
  with_lock scope.parent (fun () ->
    List.iter (fun (k, v) -> Hashtbl.replace scope.parent.tbl k v) pairs)
;;

(* ── User data convenience API ─────────────────────────────── *)

let set_user_data (ctx : t) key value = set_scoped ctx User key value
let get_user_data (ctx : t) key = get_scoped ctx User key
let delete_user_data (ctx : t) key = delete_scoped ctx User key

let all_user_data (ctx : t) =
  let prefix = scope_prefix User in
  let prefix_len = String.length prefix in
  with_lock ctx (fun () ->
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) ctx.tbl []
    |> List.filter_map (fun (key, value) ->
      if String.length key >= prefix_len && String.sub key 0 prefix_len = prefix
      then Some (String.sub key prefix_len (String.length key - prefix_len), value)
      else None))
;;
