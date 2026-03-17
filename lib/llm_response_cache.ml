(** LLM response cache (L1 memory + L2 .masc/cache). *)

type l1_entry = {
  value_json : Yojson.Safe.t;
  expires_at : float;
}

type l1_stats = {
  entries : int;
  max_entries : int;
}

let l1_table : (string, l1_entry) Hashtbl.t = Hashtbl.create 512
let l1_order : string list ref = ref []
let l1_mutex = Eio.Mutex.create ()
let eio_available = ref false

let enable_eio () = eio_available := true

let with_l1_lock f =
  if !eio_available then
    Eio.Mutex.use_rw ~protect:true l1_mutex (fun () -> f ())
  else
    (* No Eio runtime (module init/unit tests) — run unlocked. *)
    f ()

let default_ttl_seconds () = max 1 Env_config.Llm.cache_ttl_seconds
let l1_max_entries () = max 64 Env_config.Llm.cache_l1_max_entries

let now () = Time_compat.now ()

let cache_config () =
  (* Use current working directory to resolve repository root/worktree root. *)
  Room.default_config (Sys.getcwd ())

let sha256_hex s = Digestif.SHA256.(to_hex (digest_string s))
let make_key ~namespace ~content = Printf.sprintf "%s:%s" namespace (sha256_hex content)

let remove_order_key key =
  l1_order := List.filter (fun existing -> not (String.equal existing key)) !l1_order

let touch_order_key key =
  remove_order_key key;
  l1_order := key :: !l1_order

let rec enforce_l1_limit () =
  if Hashtbl.length l1_table <= l1_max_entries () then
    ()
  else
    match List.rev !l1_order with
    | [] -> ()
    | oldest :: _ ->
        Hashtbl.remove l1_table oldest;
        remove_order_key oldest;
        enforce_l1_limit ()

let put_l1 ~key ~value_json ~expires_at =
  with_l1_lock (fun () ->
      Hashtbl.replace l1_table key { value_json; expires_at };
      touch_order_key key;
      enforce_l1_limit ())

let is_expired ~expires_at = now () >= expires_at

let get_l1 key =
  with_l1_lock (fun () ->
      match Hashtbl.find_opt l1_table key with
      | None -> None
      | Some entry ->
          if is_expired ~expires_at:entry.expires_at then (
            Hashtbl.remove l1_table key;
            remove_order_key key;
            None)
          else (
            touch_order_key key;
            Some entry.value_json))

let put_l2 ~key ~value_json ~ttl_seconds =
  let config = cache_config () in
  let ttl_seconds_opt = Some ttl_seconds in
  Cache_eio.set config ~key ~value:(Yojson.Safe.to_string value_json)
    ?ttl_seconds:ttl_seconds_opt
    ~tags:[ "llm-response-cache" ] ()
  |> Result.map (fun _ -> ())

let get_l2 key =
  let config = cache_config () in
  match Cache_eio.get config ~key with
  | Ok None -> Ok None
  | Ok (Some entry) -> (
      match Safe_ops.parse_json_safe ~context:"llm_response_cache.get_l2" entry.value with
      | Ok json ->
          let ttl_fallback = float_of_int (default_ttl_seconds ()) in
          let expires_at = Option.value entry.expires_at ~default:(now () +. ttl_fallback) in
          put_l1 ~key ~value_json:json ~expires_at;
          Ok (Some json)
      | Error e ->
          let _ = Cache_eio.delete config ~key in
          Error e)
  | Error e -> Error e

let get_json ~key =
  match get_l1 key with
  | Some json -> Ok (Some json)
  | None -> get_l2 key

let set_json ~key ?ttl_seconds value_json =
  let ttl_seconds = Option.value ttl_seconds ~default:(default_ttl_seconds ()) in
  let expires_at = now () +. float_of_int ttl_seconds in
  put_l1 ~key ~value_json ~expires_at;
  put_l2 ~key ~value_json ~ttl_seconds

let delete ~key =
  with_l1_lock (fun () ->
      Hashtbl.remove l1_table key;
      remove_order_key key);
  let config = cache_config () in
  match Cache_eio.delete config ~key with
  | Ok _ -> Ok ()
  | Error e -> Error e

let clear_l1 () =
  with_l1_lock (fun () ->
      Hashtbl.clear l1_table;
      l1_order := [])

let get_l1_stats () =
  with_l1_lock (fun () ->
      { entries = Hashtbl.length l1_table; max_entries = l1_max_entries () })
