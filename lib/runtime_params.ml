(** Runtime_params — Typed parameter store with governance override.

    Architecture:
    - Each parameter has a [default] thunk (reads env_config at call time),
      an optional [override] ref, and [validate]/[serialize]/[deserialize] fns.
    - A global Eio.Mutex protects [overrides] and the registry Hashtbl.
    - Persistence: atomic write to [.masc/runtime_params.json].
    - Audit: append to [.masc/param_audit.jsonl].

    @since 2.96.0 *)

(* ── helpers ─────────────────────────────────────────────────── *)

let sprintf = Printf.sprintf

(* ── types ───────────────────────────────────────────────────── *)

type param_meta =
  { description : string
  ; value_type : string
  ; min_value : Yojson.Safe.t option
  ; max_value : Yojson.Safe.t option
  }

type 'a param_entry =
  { key : string
  ; default : unit -> 'a
  ; validate : 'a -> (unit, string) result
  ; serialize : 'a -> Yojson.Safe.t
  ; deserialize : Yojson.Safe.t -> ('a, string) result
  ; mutable override : 'a option
  }

(** Type-erased wrapper for the registry.
    [clear_override] is used internally by typed {!clear} but set-only
    from this module's perspective, hence the warning suppression. *)
type erased =
  { key : string
  ; current_json : unit -> Yojson.Safe.t
  ; default_json : unit -> Yojson.Safe.t
  ; has_override : unit -> bool
  ; set_from_json : Yojson.Safe.t -> (unit, string) result
  ; clear_override : unit -> unit [@warning "-69"]
  ; meta : param_meta option
  }

type 'a param = 'a param_entry

(* ── global state ────────────────────────────────────────────── *)

(** Registry keyed by parameter name.
    Protected by [mu]. *)
let registry_tbl : (string, erased) Hashtbl.t = Hashtbl.create 64

(** Eio.Mutex for all mutable state.
    Falls back to lock-free when Eio scheduler is absent (tests, init). *)
let mu = Eio.Mutex.create ()

let with_rw f = Eio_guard.with_mutex mu f
let with_ro f = Eio_guard.with_mutex_ro mu f

(* ── registration ────────────────────────────────────────────── *)

let register ~key ~default ~validate ~serialize ~deserialize ?meta () =
  let entry = { key; default; validate; serialize; deserialize; override = None } in
  let erased =
    { key
    ; current_json =
        (fun () ->
          let v =
            match entry.override with
            | Some v -> v
            | None -> entry.default ()
          in
          entry.serialize v)
    ; default_json = (fun () -> entry.serialize (entry.default ()))
    ; has_override = (fun () -> Option.is_some entry.override)
    ; set_from_json =
        (fun json ->
          match entry.deserialize json with
          | Error msg -> Error msg
          | Ok v ->
            (match entry.validate v with
             | Error msg -> Error msg
             | Ok () ->
               entry.override <- Some v;
               Ok ()))
    ; clear_override = (fun () -> entry.override <- None)
    ; meta
    }
  in
  (* Check + insert under mutex to prevent TOCTOU race.
     At module init time, Eio scheduler may be absent — with_rw falls
     back to lock-free f() which is safe since init is single-threaded. *)
  with_rw (fun () ->
    if Hashtbl.mem registry_tbl key
    then invalid_arg (sprintf "Runtime_params: duplicate key %S" key);
    Hashtbl.replace registry_tbl key erased);
  entry
;;

(* ── read / write ────────────────────────────────────────────── *)

let get (entry : 'a param) =
  with_ro (fun () ->
    match entry.override with
    | Some v -> v
    | None -> entry.default ())
;;

let set (entry : 'a param) value =
  with_rw (fun () ->
    match entry.validate value with
    | Error msg -> Error (sprintf "validation failed for %s: %s" entry.key msg)
    | Ok () ->
      entry.override <- Some value;
      Ok ())
;;

let set_by_key key json =
  with_rw (fun () ->
    match Hashtbl.find_opt registry_tbl key with
    | None -> Error (sprintf "unknown parameter: %s" key)
    | Some erased -> erased.set_from_json json)
;;

let clear (entry : 'a param) = with_rw (fun () -> entry.override <- None)

let clear_by_key key =
  with_rw (fun () ->
    match Hashtbl.find_opt registry_tbl key with
    | None -> Error (sprintf "unknown parameter: %s" key)
    | Some erased ->
      erased.clear_override ();
      Ok ())
;;

let registry () =
  with_ro (fun () ->
    Hashtbl.fold
      (fun _key (erased : erased) acc ->
         ( erased.key
         , erased.current_json ()
         , erased.default_json ()
         , erased.has_override ()
         , erased.meta )
         :: acc)
      registry_tbl
      [])
  |> List.sort (fun (a, _, _, _, _) (b, _, _, _, _) -> String.compare a b)
;;

(* ── persistence ─────────────────────────────────────────────── *)

let params_file base_path =
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path) "runtime_params.json"
;;

let audit_file base_path =
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path) "param_audit.jsonl"
;;

let ensure_dir path =
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir
;;

(** Atomic write via rename.  Errors are logged but do not propagate
    — callers should not fail just because persistence is unavailable. *)
let persist ~base_path =
  try
    let path = params_file base_path in
    ensure_dir path;
    let overrides =
      with_ro (fun () ->
        Hashtbl.fold
          (fun _key (erased : erased) acc ->
             if erased.has_override ()
             then (erased.key, erased.current_json ()) :: acc
             else acc)
          registry_tbl
          [])
    in
    let json = `Assoc overrides in
    match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
    | Ok () -> ()
    | Error msg -> Log.Config.error "Runtime_params.persist atomic: %s" msg
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Config.error "Runtime_params.persist: %s" (Printexc.to_string exn)
;;

let restore ~base_path =
  let path = params_file base_path in
  if Sys.file_exists path
  then (
    try
      let content = Fs_compat.load_file path in
      match Yojson.Safe.from_string content with
      | `Assoc pairs ->
        with_rw (fun () ->
          List.iter
            (fun (key, json) ->
               match Hashtbl.find_opt registry_tbl key with
               | None -> () (* param not registered yet; skip *)
               | Some erased ->
                 (match erased.set_from_json json with
                  | Ok () -> ()
                  | Error msg ->
                    Log.Config.warn "Runtime_params.restore: skipping %s: %s" key msg))
            pairs)
      | _ -> Log.Config.warn "Runtime_params.restore: invalid JSON in %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Log.Config.error "Runtime_params.restore: %s" (Printexc.to_string exn))
;;

(* ── audit ───────────────────────────────────────────────────── *)

let record_audit ~base_path ~key ~old_value ~new_value ?case_id ~actor () =
  let path = audit_file base_path in
  ensure_dir path;
  let entry =
    `Assoc
      ([ "timestamp", `Float (Unix.gettimeofday ())
       ; "key", `String key
       ; "old_value", old_value
       ; "new_value", new_value
       ; "actor", `String actor
       ]
       @
       match case_id with
       | Some id -> [ "case_id", `String id ]
       | None -> [])
  in
  Fs_compat.append_jsonl path entry
;;

let recent_audit ~base_path n =
  let path = audit_file base_path in
  let all = Fs_compat.load_jsonl path in
  (* Take last n entries (most recent) *)
  let len = List.length all in
  if len <= n
  then List.rev all
  else all |> List.to_seq |> Seq.drop (len - n) |> List.of_seq |> List.rev
;;
