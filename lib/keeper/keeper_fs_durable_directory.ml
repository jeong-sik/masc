(** Directory-chain durability coordination for {!Keeper_fs}.

    The immutable Atomic cache snapshot is the warm-path SSOT. The mutex
    serializes ownership, cache publication, and invalidation; mkdir and fsync
    always run outside it. *)

type validation_domain =
  | Follow_symbolic_links
  | Owned_no_follow of { ownership_root : string }

type directory_key =
  { path : string
  ; validation_domain : validation_domain
  }

module Directory_key = struct
  type t = directory_key

  let compare_domain left right =
    match left, right with
    | Follow_symbolic_links, Follow_symbolic_links -> 0
    | Follow_symbolic_links, Owned_no_follow _ -> -1
    | Owned_no_follow _, Follow_symbolic_links -> 1
    | Owned_no_follow left, Owned_no_follow right ->
      String.compare left.ownership_root right.ownership_root
  ;;

  let compare left right =
    match String.compare left.path right.path with
    | 0 -> compare_domain left.validation_domain right.validation_domain
    | ordering -> ordering
  ;;

  let equal left right = compare left right = 0

  let hash key =
    match key.validation_domain with
    | Follow_symbolic_links -> Hashtbl.hash (key.path, None)
    | Owned_no_follow { ownership_root } ->
      Hashtbl.hash (key.path, Some ownership_root)
  ;;
end

module Directory_key_map = Map.Make (Directory_key)
module Directory_key_table = Hashtbl.Make (Directory_key)

type chain_error =
  | Non_directory_ancestor of { path : string }
  | Outside_ownership_root of
      { ownership_root : string
      ; path : string
      }
  | Missing_root of { path : string }
  | Creation_not_observed of { path : string }

type failure =
  | Directory_chain_failed of chain_error
  | Operation_failed of exn * Printexc.raw_backtrace

type completion =
  | Prepared
  | Retry
  | Failed of failure

type lease =
  { key : directory_key
  ; token : cache_token
  }

and directory_identity =
  { device : int
  ; inode : int
  }

and cache_token =
  { marker : unit ref
  ; identity : directory_identity option
  }

type preparation =
  { completion : completion Eio.Promise.t
  ; resolver : completion Eio.Promise.u
  ; cache_marker : unit ref
  ; valid : bool Atomic.t
  }

type claim =
  | Already_durable
  | Await_preparation of completion Eio.Promise.t
  | Observe_completion of completion
  | Own_preparations of (directory_key * preparation) list

let durable_cache : cache_token Directory_key_map.t Atomic.t =
  Atomic.make Directory_key_map.empty
let prepare_mu = Stdlib.Mutex.create ()
let preparations : preparation Directory_key_table.t = Directory_key_table.create 16

let with_prepare_lock f = Stdlib.Mutex.protect prepare_mu f

let current_lease key =
  match Directory_key_map.find_opt key (Atomic.get durable_cache) with
  | Some token -> Some { key; token }
  | None -> None
;;

let is_durable key = Option.is_some (current_lease key)

let lease_is_current lease =
  match Directory_key_map.find_opt lease.key (Atomic.get durable_cache) with
  | Some token -> token.marker == lease.token.marker
  | None -> false
;;

let rec mark_current_with_token key token =
  let current = Atomic.get durable_cache in
  match Directory_key_map.find_opt key current with
  | Some current_token -> current_token
  | None ->
    let updated = Directory_key_map.add key token current in
    if Atomic.compare_and_set durable_cache current updated
    then token
    else mark_current_with_token key token
;;

let identity_of_stat (stat : Unix.stats) =
  { device = stat.st_dev; inode = stat.st_ino }
;;

let cache_token_for_key ~marker key =
  match key.validation_domain with
  | Follow_symbolic_links -> Ok { marker; identity = None }
  | Owned_no_follow _ ->
    (match Unix.lstat key.path with
     | stat when stat.Unix.st_kind = Unix.S_DIR ->
       Ok { marker; identity = Some (identity_of_stat stat) }
     | _ -> Error (Non_directory_ancestor { path = key.path })
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       Error (Creation_not_observed { path = key.path }))
;;

let mark_current key =
  match cache_token_for_key ~marker:(ref ()) key with
  | Error _ as error -> error
  | Ok token ->
    with_prepare_lock (fun () ->
      ignore (mark_current_with_token key token : cache_token));
    Ok ()
;;

let mark_if_valid preparation key token =
  (* Publication and invalidation share the same short non-I/O critical
     section. Merely checking [valid] before and after a cache CAS is not
     linearizable: invalidation can finish between the check and a later CAS,
     allowing the retired token to be re-published after the subtree sweep. *)
  with_prepare_lock (fun () ->
    if not (Atomic.get preparation.valid)
    then false
    else (
      ignore
        (mark_current_with_token key token : cache_token);
      true))
;;

let path_is_at_or_below ~root path =
  String.equal root path
  ||
  let prefix =
    if String.ends_with ~suffix:Filename.dir_sep root
    then root
    else root ^ Filename.dir_sep
  in
  String.starts_with ~prefix path
;;

let rec invalidate_cache_subtree path =
  let current = Atomic.get durable_cache in
  let updated =
    Directory_key_map.filter
      (fun candidate _ ->
         not (path_is_at_or_below ~root:path candidate.path))
      current
  in
  if not (Atomic.compare_and_set durable_cache current updated)
  then invalidate_cache_subtree path
;;

let finish preparation completion =
  (* See [release]: durable-prefix publication makes this wake idempotent. *)
  ignore (Eio.Promise.try_resolve preparation.resolver completion)
;;

let invalidate path =
  let invalidated =
    with_prepare_lock (fun () ->
      let invalidated =
        Directory_key_table.fold
          (fun candidate preparation found ->
             if path_is_at_or_below ~root:path candidate.path
             then (candidate, preparation) :: found
             else found)
          preparations
          []
      in
      List.iter
        (fun (candidate, preparation) ->
           Atomic.set preparation.valid false;
           match Directory_key_table.find_opt preparations candidate with
           | Some current when current == preparation ->
             Directory_key_table.remove preparations candidate
           | Some _ | None -> ())
        invalidated;
      invalidate_cache_subtree path;
      invalidated)
  in
  List.iter (fun (_, preparation) -> finish preparation Retry) invalidated
;;

let clear () =
  let invalidated =
    with_prepare_lock (fun () ->
      let invalidated = Directory_key_table.to_seq_values preparations |> List.of_seq in
      List.iter
        (fun preparation -> Atomic.set preparation.valid false)
        invalidated;
      Directory_key_table.clear preparations;
      Atomic.set durable_cache Directory_key_map.empty;
      invalidated)
  in
  List.iter (fun preparation -> finish preparation Retry) invalidated
;;

let make_preparation () =
  let completion, resolver = Eio.Promise.create () in
  { completion; resolver; cache_marker = ref (); valid = Atomic.make true }
;;

let directory_chain_from_root path =
  let rec loop descendants current =
    let parent = Filename.dirname current in
    if String.equal parent current
    then current, descendants
    else loop (current :: descendants) parent
  in
  loop [] path
;;

let ensure_root ~follow key =
  if is_durable key
  then Ok ()
  else (
    match Fs_compat.path_kind ~follow key.path with
    | Fs_compat.Directory ->
      mark_current key
    | Fs_compat.Other -> Error (Non_directory_ancestor { path = key.path })
    | Fs_compat.Missing -> Error (Missing_root { path = key.path }))
;;

let ensure_component_visible ~follow key =
  if is_durable key
  then Ok false
  else (
    let path = key.path in
    let observed =
      match Fs_compat.path_kind ~follow path with
      | Fs_compat.Directory -> Ok ()
      | Fs_compat.Other -> Error (Non_directory_ancestor { path })
      | Fs_compat.Missing ->
        Fs_compat.mkdir_p path;
        (match Fs_compat.path_kind ~follow path with
         | Fs_compat.Directory -> Ok ()
         | Fs_compat.Other -> Error (Non_directory_ancestor { path })
         | Fs_compat.Missing -> Error (Creation_not_observed { path }))
    in
    match observed with
    | Error _ as error -> error
    | Ok () -> Ok true)
;;

let rec visible_preparations ~follow pending = function
  | [] -> Ok (List.rev pending)
  | ((path, _) as preparation) :: rest ->
    (match ensure_component_visible ~follow path with
     | Error _ as error -> error
     | Ok false -> visible_preparations ~follow pending rest
     | Ok true -> visible_preparations ~follow (preparation :: pending) rest)
;;

let claim components =
  with_prepare_lock (fun () ->
    let cache = Atomic.get durable_cache in
    let cached key = Directory_key_map.mem key cache in
    let rec first_outstanding = function
      | [] -> None
      | key :: rest ->
        if cached key
        then first_outstanding rest
        else (
          match Directory_key_table.find_opt preparations key with
          | None -> first_outstanding rest
          | Some preparation ->
            (match Eio.Promise.peek preparation.completion with
             | None -> Some (`Await preparation.completion)
             | Some completion ->
               Directory_key_table.remove preparations key;
               Some (`Observe completion)))
    in
    match first_outstanding components with
    | Some (`Await completion) -> Await_preparation completion
    | Some (`Observe completion) -> Observe_completion completion
    | None ->
      let owned =
        List.filter_map
          (fun key ->
             if cached key
             then None
             else (
               let preparation = make_preparation () in
               Directory_key_table.replace preparations key preparation;
               Some (key, preparation)))
          components
      in
      (match owned with
       | [] -> Already_durable
       | _ :: _ -> Own_preparations owned))
;;

let release ~completion owned =
  let removal =
    try
      with_prepare_lock (fun () ->
        List.iter
          (fun (key, preparation) ->
             match Directory_key_table.find_opt preparations key with
             | Some current when current == preparation ->
               Directory_key_table.remove preparations key
             | Some _ | None -> ())
          owned);
      Ok ()
    with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  List.iter (fun (_, preparation) -> finish preparation completion) owned;
  removal
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let prepare_owned ~follow ~before_prepare ~before_directory_fsync owned =
  before_prepare ();
  (* Directory observation, creation, and fsync may all block on a slow
     filesystem. Keep the complete cold-path transaction in one systhread
     handoff so a single Keeper lane cannot stop the Eio scheduler domain. *)
  Eio_guard.run_in_systhread (fun () ->
    match visible_preparations ~follow [] owned with
    | Error error -> Error (Directory_chain_failed error)
    | Ok pending ->
      (* Publishing each component after its parent fsync lets a sibling start
         its divergent suffix while this owner continues deeper in the
         original chain. *)
      let rec prepare = function
        | [] -> Ok ()
        | (key, preparation) :: rest ->
          if not (Atomic.get preparation.valid)
          then (
            finish preparation Retry;
            prepare rest)
          else (
            let parent = Filename.dirname key.path in
            before_directory_fsync parent;
            fsync_directory parent;
            match
              cache_token_for_key ~marker:preparation.cache_marker key
            with
            | Error error -> Error (Directory_chain_failed error)
            | Ok token ->
              if mark_if_valid preparation key token
              then finish preparation Prepared
              else finish preparation Retry;
              prepare rest)
      in
      prepare pending)
;;

let capture_operation f =
  try f () with
  | exn -> Error (Operation_failed (exn, Printexc.get_raw_backtrace ()))
;;

let propagate_cancellation outcome =
  Eio_guard.check_if_ready ();
  match outcome with
  | Error (Operation_failed ((Eio.Cancel.Cancelled _ as exn), backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
  | outcome -> outcome
;;

let completion_of_outcome = function
  | Ok () -> Prepared
  | Error (Operation_failed (Eio.Cancel.Cancelled _, _)) -> Retry
  | Error failure -> Failed failure
;;

let directory_chain ?ownership_root dir =
  match ownership_root with
  | None ->
    let root, component_paths = directory_chain_from_root dir in
    let validation_domain = Follow_symbolic_links in
    let key path = { path; validation_domain } in
    let root = key root in
    let components = List.map key component_paths in
    let target =
      match List.rev components with
      | target :: _ -> target
      | [] -> root
    in
    Ok (root, components, target, true)
  | Some ownership_root ->
    (match Fs_compat.owned_directory_paths ~ownership_root dir with
     | Ok component_paths ->
       let validation_domain = Owned_no_follow { ownership_root } in
       let key path = { path; validation_domain } in
       let root = key ownership_root in
       let components = List.map key component_paths in
       let target =
         match List.rev components with
         | target :: _ -> target
         | [] -> root
       in
       Ok (root, components, target, false)
     | Error (Fs_compat.Owned_path_outside_root { ownership_root; path }) ->
       Error (Outside_ownership_root { ownership_root; path })
     | Error (Fs_compat.Owned_path_non_directory { path; _ }) ->
       Error (Non_directory_ancestor { path }))
;;

type cached_chain_observation =
  | Cached_chain_current
  | Cached_chain_uncached
  | Cached_chain_changed of { path : string }
  | Cached_chain_missing of { path : string }
  | Cached_chain_non_directory of { path : string }
  | Cached_chain_domain_mismatch of { path : string }

let same_identity expected (stat : Unix.stats) =
  expected.device = stat.st_dev && expected.inode = stat.st_ino
;;

let observe_cached_owned_chain cache keys =
  let rec observe has_uncached = function
    | [] ->
      if has_uncached then Cached_chain_uncached else Cached_chain_current
    | key :: rest ->
      (match Directory_key_map.find_opt key cache with
       | None -> observe true rest
       | Some { identity = None; _ } ->
         Cached_chain_domain_mismatch { path = key.path }
       | Some { identity = Some expected; _ } ->
         (match Unix.lstat key.path with
          | stat when stat.Unix.st_kind <> Unix.S_DIR ->
            Cached_chain_non_directory { path = key.path }
          | stat when same_identity expected stat -> observe has_uncached rest
          | _ -> Cached_chain_changed { path = key.path }
          | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
            Cached_chain_missing { path = key.path }))
  in
  observe false keys
;;

let validate_current_lease keys target =
  match target.validation_domain with
  | Follow_symbolic_links -> Ok (current_lease target)
  | Owned_no_follow _ ->
       let cache = Atomic.get durable_cache in
       let lease =
         Directory_key_map.find_opt target cache
         |> Option.map (fun token -> { key = target; token })
       in
       let observation =
         try Ok (Eio_guard.run_in_systhread (fun () ->
           observe_cached_owned_chain cache keys)) with
         | exn -> Error (Operation_failed (exn, Printexc.get_raw_backtrace ()))
       in
       Eio_guard.check_if_ready ();
       (match observation with
        | Error _ as error -> error
        | Ok Cached_chain_current ->
          (match lease with
           | Some lease when lease_is_current lease -> Ok (Some lease)
           | Some _ | None -> Ok None)
        | Ok Cached_chain_uncached -> Ok None
        | Ok (Cached_chain_changed { path } | Cached_chain_missing { path }) ->
          invalidate path;
          Ok None
        | Ok (Cached_chain_non_directory { path }) ->
          invalidate path;
          Error (Directory_chain_failed (Non_directory_ancestor { path }))
        | Ok (Cached_chain_domain_mismatch { path }) ->
          invalidate path;
          Error
            (Operation_failed
               ( Failure
                   (Printf.sprintf
                      "owned durability cache lost identity for %s"
                      path)
               , Printexc.get_callstack 16 )))
;;

let rec ensure_with
          ~after_validation
          ~before_prepare
          ~before_directory_fsync
          ?ownership_root
          dir
  =
  match directory_chain ?ownership_root dir with
  | Error error -> Error (Directory_chain_failed error)
  | Ok (root, components, target, follow) ->
   (match
      validate_current_lease (root :: components) target
      |> propagate_cancellation
    with
    | Error _ as error -> error
    | Ok (Some lease) -> Ok lease
    | Ok None ->
    after_validation ();
    match
      capture_operation (fun () ->
        Eio_guard.run_in_systhread (fun () ->
          match ensure_root ~follow root with
          | Ok () -> Ok ()
          | Error error -> Error (Directory_chain_failed error)))
      |> propagate_cancellation
    with
    | Error _ as error -> error
    | Ok () ->
      (match claim components with
       | Already_durable ->
         ensure_with
           ~after_validation
           ~before_prepare
           ~before_directory_fsync
           ?ownership_root
           dir
       | Await_preparation completion ->
         (match Eio.Promise.await completion with
          | Prepared | Retry ->
            ensure_with
              ~after_validation
              ~before_prepare
              ~before_directory_fsync
              ?ownership_root
              dir
          | Failed failure -> Error failure)
       | Observe_completion completion ->
         (match completion with
          | Prepared | Retry ->
            ensure_with
              ~after_validation
              ~before_prepare
              ~before_directory_fsync
              ?ownership_root
              dir
          | Failed failure -> Error failure)
       | Own_preparations owned ->
         let outcome =
           capture_operation (fun () ->
             prepare_owned ~follow ~before_prepare ~before_directory_fsync owned)
         in
         let completion = completion_of_outcome outcome in
         let cleanup =
           if Eio_guard.is_ready ()
           then Eio.Cancel.protect (fun () -> release ~completion owned)
           else release ~completion owned
         in
         (match cleanup, outcome with
          | Ok (), (Error _ as outcome) -> propagate_cancellation outcome
          | Ok (), Ok () ->
            Eio_guard.check_if_ready ();
            ensure_with
              ~after_validation
              ~before_prepare
              ~before_directory_fsync
              ?ownership_root
              dir
          | Error (cleanup_exn, cleanup_backtrace), Ok () ->
            propagate_cancellation
              (Error (Operation_failed (cleanup_exn, cleanup_backtrace)))
          | Error (cleanup_exn, _), Error failure ->
            Log.Keeper.warn
              "filesystem_runtime: directory preparation ownership cleanup failed: %s"
              (Printexc.to_string cleanup_exn);
            propagate_cancellation (Error failure))))
;;

let ensure = ensure_with ~after_validation:(fun () -> ())

module For_testing = struct
  let ensure = ensure_with
end
