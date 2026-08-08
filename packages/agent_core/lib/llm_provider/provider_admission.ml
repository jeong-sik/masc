(** Per-endpoint admission of concurrent provider requests. See the .mli for
    the contract. *)

type key =
  { kind : string
  ; base_url : string
  ; secret : Secret.identity option
  }

module Key = struct
  type t = key

  let equal a b =
    String.equal a.kind b.kind
    && String.equal a.base_url b.base_url
    && Option.equal Secret.equal_identity a.secret b.secret
  ;;

  let hash { kind; base_url; secret } =
    let secret_hash =
      match secret with
      | None -> 0
      | Some identity -> Secret.hash_identity identity
    in
    Hashtbl.hash (kind, base_url, secret_hash)
  ;;
end

module Table = Hashtbl.Make (Key)

type entry =
  { scheduler : Slot_scheduler.t
  ; declared_max : int
  ; mutable conflict_warned : bool
  }

(* Stdlib.Mutex rather than Eio.Mutex: the critical section is a table
   lookup/insert that never blocks or switches fibers, and the table is
   shared by every domain that dispatches completions. All waiting happens
   inside Slot_scheduler, whose Eio primitives are domain-safe. *)
let table : entry Table.t = Table.create 8
let table_mutex = Stdlib.Mutex.create ()

let key_of_config (config : Provider_config.t) =
  { kind = Provider_config.string_of_provider_kind config.kind
  ; base_url = config.base_url
  ; secret = Secret.identity config.api_key
  }
;;

let entry_for ~key ~max =
  Stdlib.Mutex.protect table_mutex (fun () ->
    match Table.find_opt table key with
    | Some entry ->
      if entry.declared_max <> max && not entry.conflict_warned
      then (
        entry.conflict_warned <- true;
        Diag.warn
          "provider_admission"
          "conflicting max_concurrent_requests for %s %s: scheduler holds %d, a config \
           declares %d; the first declaration stays authoritative"
          key.kind
          (Complete_common.sanitize_url_for_log key.base_url)
          entry.declared_max
          max);
      entry
    | None ->
      let entry =
        { scheduler = Slot_scheduler.create ~max_slots:max
        ; declared_max = max
        ; conflict_warned = false
        }
      in
      Table.add table key entry;
      entry)
;;

let with_admission ~(config : Provider_config.t) f =
  match config.max_concurrent_requests with
  | None -> f ()
  | Some max ->
    (* max >= 1 is enforced by Complete_common.validate_all before any
       dispatch reaches this point; Slot_scheduler.create re-checks and
       raises on a bypassing caller rather than admitting silently. *)
    let entry = entry_for ~key:(key_of_config config) ~max in
    Slot_scheduler.with_permit entry.scheduler f
;;

let snapshot_for ~(config : Provider_config.t) =
  let key = key_of_config config in
  Stdlib.Mutex.protect table_mutex (fun () ->
    Table.find_opt table key
    |> Option.map (fun entry -> Slot_scheduler.snapshot entry.scheduler))
;;
