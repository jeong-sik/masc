(** Per-endpoint admission of concurrent provider requests. See the .mli for
    the contract. *)

module State = Provider_admission_state

(* Stdlib.Mutex rather than Eio.Mutex: the critical section only swaps an
   immutable registry state and never blocks or switches fibers. A published
   allowance change also reconfigures its scheduler inside it, which never
   blocks either, so schedulers take allowances in the order the registry
   records them. Scheduler creation, diagnostics, snapshots, and permit
   waiting remain outside it. *)
let state : Slot_scheduler.t State.t ref = ref State.empty
let state_mutex = Stdlib.Mutex.create ()

let key_of_config (config : Provider_config.t) =
  State.key
    ~kind:(Provider_config.string_of_provider_kind config.kind)
    ~base_url:config.base_url
    ~secret:(Secret.identity config.api_key)
;;

let apply_transition transition =
  Stdlib.Mutex.protect state_mutex (fun () ->
    let next, output = transition !state in
    state := next;
    output)
;;

let resolve_existing ~key ~allowance =
  Stdlib.Mutex.protect state_mutex (fun () ->
    match State.resolve_existing key ~declared:allowance !state with
    | None -> None
    | Some (next, resolution) ->
      state := next;
      Some resolution)
;;

let allowance_to_string (allowance : State.allowance) =
  match allowance.priority_run_limit with
  | None -> Printf.sprintf "max_concurrent_requests=%d" allowance.max
  | Some limit ->
    Printf.sprintf
      "max_concurrent_requests=%d admission_priority_run_limit=%d"
      allowance.max
      limit
;;

(* Two configs naming the same endpoint identity with different allowances
   have no precedence between them, so neither may run under the other's.
   The disagreement is a configuration error, raised here: before the permit
   is taken and therefore before any provider I/O. *)
let reject_conflict = function
  | None -> ()
  | Some (conflict : State.conflict) ->
    invalid_arg
      (Printf.sprintf
         "Provider_admission: conflicting admission allowances for %s %s: one \
          config declares %s, another declares %s. The endpoint identity (kind, \
          base_url, api-key identity) admits one allowance; make the declarations \
          agree or give them different identities."
         conflict.kind
         (Complete_common.sanitize_url_for_log conflict.base_url)
         (allowance_to_string conflict.authoritative)
         (allowance_to_string conflict.declared))
;;

let entry_for ~key ~(allowance : State.allowance) =
  let resolution =
    match resolve_existing ~key ~allowance with
    | Some resolution -> resolution
    | None ->
      let candidate =
        Slot_scheduler.create
          ~max_slots:allowance.max
          ~priority_run_limit:allowance.priority_run_limit
      in
      apply_transition (State.install key ~declared:allowance ~candidate)
  in
  reject_conflict resolution.conflict;
  resolution.scheduler
;;

(* max >= 1 and a declared run limit >= 1 are enforced by
   Complete_common.validate_all before any dispatch reaches this point;
   Slot_scheduler.create re-checks and raises on a bypassing caller rather
   than admitting silently. *)
let allowance_of_config (config : Provider_config.t) ~max : State.allowance =
  { max; priority_run_limit = config.admission_priority_run_limit }
;;

type allowance_disagreement =
  { kind : string
  ; base_url : string
  ; declarations : (string * State.allowance) list
  }

type published_allowances = (State.key * State.allowance) list

(* Groups the admitted configs by endpoint identity in the order they are
   given; an identity whose configs declare more than one allowance is a
   disagreement. *)
let allowances_of_configs labelled =
  let groups =
    List.fold_left
      (fun groups (label, (config : Provider_config.t)) ->
         match config.max_concurrent_requests with
         | None -> groups
         | Some max ->
           let key = key_of_config config in
           let declaration = label, allowance_of_config config ~max in
           let rec add = function
             | [] -> [ key, config, [ declaration ] ]
             | (group_key, first, declarations) :: rest
               when State.key_equal group_key key ->
               (group_key, first, declarations @ [ declaration ]) :: rest
             | group :: rest -> group :: add rest
           in
           add groups)
      []
      labelled
  in
  let agrees declarations =
    match declarations with
    | [] -> true
    | (_, first) :: rest ->
      List.for_all (fun (_, allowance) -> State.allowance_equal allowance first) rest
  in
  match
    List.filter_map
      (fun (_, (config : Provider_config.t), declarations) ->
         if agrees declarations
         then None
         else
           Some
             { kind = Provider_config.string_of_provider_kind config.kind
             ; base_url = Complete_common.sanitize_url_for_log config.base_url
             ; declarations
             })
      groups
  with
  | [] ->
    Ok
      (List.filter_map
         (fun (key, _, declarations) ->
            match declarations with
            | (_, allowance) :: _ -> Some (key, allowance)
            | [] -> None)
         groups)
  | disagreements -> Error disagreements
;;

(* The registry entry and its scheduler change under one hold of the
   registry mutex, so two loads publishing at once leave every scheduler on
   the allowance the registry records. *)
let publish (published : published_allowances) =
  List.iter
    (fun (key, (allowance : State.allowance)) ->
       let candidate =
         Slot_scheduler.create
           ~max_slots:allowance.max
           ~priority_run_limit:allowance.priority_run_limit
       in
       Stdlib.Mutex.protect state_mutex (fun () ->
         let next, publication = State.publish key ~declared:allowance ~candidate !state in
         state := next;
         match publication with
         | State.Published_new _ | State.Published_unchanged _ -> ()
         | State.Published_changed scheduler ->
           Slot_scheduler.reconfigure
             scheduler
             ~max_slots:allowance.max
             ~priority_run_limit:allowance.priority_run_limit))
    published
;;

let with_admission ~(config : Provider_config.t) f =
  match config.max_concurrent_requests with
  | None -> f ()
  | Some max ->
    let scheduler =
      entry_for ~key:(key_of_config config) ~allowance:(allowance_of_config config ~max)
    in
    Slot_scheduler.with_permit ~admission_class:config.admission_class scheduler f
;;

type permit_wait = Slot_scheduler.permit_wait =
  | Before_any_wait
  | Waiting_for_permit
  | Wait_settled_at of float

let with_admission_until ?wait ~clock ~deadline_at ~(config : Provider_config.t) f =
  match config.max_concurrent_requests with
  | None -> Ok (f ())
  | Some max ->
    let scheduler =
      entry_for ~key:(key_of_config config) ~allowance:(allowance_of_config config ~max)
    in
    Slot_scheduler.with_permit_until
      ?wait
      ~clock
      ~deadline_at
      ~admission_class:config.admission_class
      scheduler
      f
;;

type deadline_expiry =
  | Permit_wait_expired
  | Permit_granted_as_deadline_passed
  | Work_expired

let with_admission_and_work_until ?wait ~clock ~deadline_at ~config f =
  match
    with_admission_until ?wait ~clock ~deadline_at ~config (fun () ->
      let remaining = deadline_at -. Eio.Time.now clock in
      if Float.compare remaining 0.0 <= 0
      then Error Permit_granted_as_deadline_passed
      else (
        match Under_deadline.run clock remaining f with
        | Ok value -> Ok value
        | Error `Timeout -> Error Work_expired))
  with
  | Ok result -> result
  | Error `Permit_wait_expired -> Error Permit_wait_expired
;;

let with_admission_and_work_for ?wait ~clock ~timeout_s ~config f =
  let deadline_at = Eio.Time.now clock +. timeout_s in
  with_admission_and_work_until ?wait ~clock ~deadline_at ~config f
;;

let snapshot_for ~(config : Provider_config.t) =
  let key = key_of_config config in
  let snapshot = Stdlib.Mutex.protect state_mutex (fun () -> !state) in
  State.find_scheduler key snapshot |> Option.map Slot_scheduler.snapshot
;;
