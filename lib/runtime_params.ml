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

type 'a param_entry = {
  key : string;
  default : unit -> 'a;
  validate : 'a -> (unit, string) result;
  serialize : 'a -> Yojson.Safe.t;
  deserialize : Yojson.Safe.t -> ('a, string) result;
  mutable override : 'a option;
}

(** Type-erased wrapper for the registry.
    [clear_override] is used internally by typed {!clear} but set-only
    from this module's perspective, hence the warning suppression. *)
type erased = {
  key : string;
  current_json : unit -> Yojson.Safe.t;
  default_json : unit -> Yojson.Safe.t;
  has_override : unit -> bool;
  set_from_json : Yojson.Safe.t -> (unit, string) result;
  clear_override : unit -> unit; [@warning "-69"]
}

type 'a param = 'a param_entry

(* ── global state ────────────────────────────────────────────── *)

(** Registry keyed by parameter name.
    Protected by [mu]. *)
let registry_tbl : (string, erased) Hashtbl.t = Hashtbl.create 64

(** Eio.Mutex for all mutable state.
    Falls back to lock-free when Eio scheduler is absent (tests, init). *)
let mu = Eio.Mutex.create ()

let with_rw f =
  try Eio.Mutex.use_rw ~protect:true mu f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

let with_ro f =
  try Eio.Mutex.use_ro mu f
  with Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> f ()

(* ── registration ────────────────────────────────────────────── *)

let register ~key ~default ~validate ~serialize ~deserialize =
  let entry = { key; default; validate; serialize; deserialize; override = None } in
  let erased =
    {
      key;
      current_json =
        (fun () ->
          let v = match entry.override with Some v -> v | None -> entry.default () in
          entry.serialize v);
      default_json = (fun () -> entry.serialize (entry.default ()));
      has_override = (fun () -> Option.is_some entry.override);
      set_from_json =
        (fun json ->
          match entry.deserialize json with
          | Error msg -> Error msg
          | Ok v -> (
              match entry.validate v with
              | Error msg -> Error msg
              | Ok () ->
                  entry.override <- Some v;
                  Ok ()));
      clear_override = (fun () -> entry.override <- None);
    }
  in
  (* Check + insert under mutex to prevent TOCTOU race.
     At module init time, Eio scheduler may be absent — with_rw falls
     back to lock-free f() which is safe since init is single-threaded. *)
  with_rw (fun () ->
    if Hashtbl.mem registry_tbl key then
      invalid_arg (sprintf "Runtime_params: duplicate key %S" key);
    Hashtbl.replace registry_tbl key erased);
  entry

(* ── read / write ────────────────────────────────────────────── *)

let get (entry : 'a param) =
  with_ro (fun () ->
    match entry.override with Some v -> v | None -> entry.default ())

let set (entry : 'a param) value =
  with_rw (fun () ->
    match entry.validate value with
    | Error msg -> Error (sprintf "validation failed for %s: %s" entry.key msg)
    | Ok () ->
        entry.override <- Some value;
        Ok ())

let set_by_key key json =
  with_rw (fun () ->
    match Hashtbl.find_opt registry_tbl key with
    | None -> Error (sprintf "unknown parameter: %s" key)
    | Some erased -> erased.set_from_json json)

let clear (entry : 'a param) =
  with_rw (fun () -> entry.override <- None)

let registry () =
  with_ro (fun () ->
    Hashtbl.fold
      (fun _key (erased : erased) acc ->
        (erased.key, erased.current_json (), erased.default_json (), erased.has_override ()) :: acc)
      registry_tbl [])
  |> List.sort (fun (a, _, _, _) (b, _, _, _) -> String.compare a b)

(* ── persistence ─────────────────────────────────────────────── *)

let params_file base_path =
  Filename.concat (Filename.concat base_path ".masc") "runtime_params.json"

let audit_file base_path =
  Filename.concat (Filename.concat base_path ".masc") "param_audit.jsonl"

let ensure_dir path =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then (
    try Sys.mkdir dir 0o755
    with Sys_error _ -> ())

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
            if erased.has_override () then (erased.key, erased.current_json ()) :: acc
            else acc)
          registry_tbl [])
    in
    let json = `Assoc overrides in
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc (Yojson.Safe.pretty_to_string json));
    Sys.rename tmp path
  with exn ->
    Printf.eprintf "Runtime_params.persist: %s\n%!" (Printexc.to_string exn)

let restore ~base_path =
  let path = params_file base_path in
  if Sys.file_exists path then (
    try
      let ic = open_in path in
      let content =
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          In_channel.input_all ic)
      in
      match Yojson.Safe.from_string content with
      | `Assoc pairs ->
          with_rw (fun () ->
            List.iter
              (fun (key, json) ->
                match Hashtbl.find_opt registry_tbl key with
                | None -> () (* param not registered yet; skip *)
                | Some erased -> (
                    match erased.set_from_json json with
                    | Ok () -> ()
                    | Error msg ->
                        Printf.eprintf
                          "Runtime_params.restore: skipping %s: %s\n%!" key msg))
              pairs)
      | _ ->
          Printf.eprintf "Runtime_params.restore: invalid JSON in %s\n%!" path
    with exn ->
      Printf.eprintf "Runtime_params.restore: %s\n%!" (Printexc.to_string exn))

(* ── audit ───────────────────────────────────────────────────── *)

let record_audit ~base_path ~key ~old_value ~new_value ?case_id ~actor () =
  let path = audit_file base_path in
  ensure_dir path;
  let entry =
    `Assoc
      ([ ("timestamp", `Float (Unix.gettimeofday ()));
         ("key", `String key);
         ("old_value", old_value);
         ("new_value", new_value);
         ("actor", `String actor);
       ]
      @ (match case_id with Some id -> [ ("case_id", `String id) ] | None -> []))
  in
  let line = Yojson.Safe.to_string entry ^ "\n" in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc line)

let recent_audit ~base_path n =
  let path = audit_file base_path in
  if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in path in
      let lines =
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          let acc = ref [] in
          (try
             while true do
               let line = input_line ic in
               if String.trim line <> "" then
                 acc := Yojson.Safe.from_string line :: !acc
             done
           with End_of_file -> ());
          !acc)
      in
      (* lines is reversed; take first n = most recent n *)
      let rec take n = function
        | [] -> []
        | _ when n <= 0 -> []
        | x :: rest -> x :: take (n - 1) rest
      in
      take n lines
    with _ -> []
