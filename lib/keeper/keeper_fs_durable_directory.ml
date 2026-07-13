(** Directory-chain durability coordination for {!Keeper_fs}.

    The immutable Atomic cache snapshot is the warm-path SSOT. The mutex
    protects only ownership publication/removal; mkdir and fsync always run
    outside it. *)

module String_set = Set.Make (String)

type chain_error =
  | Non_directory_ancestor of { path : string }
  | Missing_root of { path : string }
  | Creation_not_observed of { path : string }

type failure =
  | Directory_chain_failed of chain_error
  | Operation_failed of exn * Printexc.raw_backtrace

type preparation =
  { completion : unit Eio.Promise.t
  ; resolver : unit Eio.Promise.u
  ; cache_revision : unit ref
  }

type claim =
  | Already_durable
  | Await_preparation of unit Eio.Promise.t
  | Own_preparations of (string * preparation) list

type durable_cache =
  { revision : unit ref
  ; dirs : String_set.t
  }

let durable_cache = Atomic.make { revision = ref (); dirs = String_set.empty }
let prepare_mu = Stdlib.Mutex.create ()
let preparations : (string, preparation) Hashtbl.t = Hashtbl.create 16

let is_durable path = String_set.mem path (Atomic.get durable_cache).dirs

let rec mark_current path =
  let current = Atomic.get durable_cache in
  if String_set.mem path current.dirs
  then ()
  else (
    let updated = { current with dirs = String_set.add path current.dirs } in
    if not (Atomic.compare_and_set durable_cache current updated)
    then mark_current path)
;;

let rec mark_if_current ~revision path =
  let current = Atomic.get durable_cache in
  if current.revision != revision
  then false
  else if String_set.mem path current.dirs
  then true
  else (
    let updated = { current with dirs = String_set.add path current.dirs } in
    if Atomic.compare_and_set durable_cache current updated
    then true
    else mark_if_current ~revision path)
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

let rec invalidate path =
  let current = Atomic.get durable_cache in
  let updated =
    { revision = ref ()
    ; dirs =
        String_set.filter
          (fun candidate -> not (path_is_at_or_below ~root:path candidate))
          current.dirs
    }
  in
  if not (Atomic.compare_and_set durable_cache current updated) then invalidate path
;;

let clear () = Atomic.set durable_cache { revision = ref (); dirs = String_set.empty }

let with_prepare_lock f = Stdlib.Mutex.protect prepare_mu f

let make_preparation ~cache_revision =
  let completion, resolver = Eio.Promise.create () in
  { completion; resolver; cache_revision }
;;

let finish preparation =
  (* See [release]: durable-prefix publication makes this wake idempotent. *)
  ignore (Eio.Promise.try_resolve preparation.resolver ())
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

let ensure_root root =
  if is_durable root
  then Ok ()
  else (
    match Fs_compat.path_kind root with
    | Fs_compat.Directory ->
      mark_current root;
      Ok ()
    | Fs_compat.Other -> Error (Non_directory_ancestor { path = root })
    | Fs_compat.Missing -> Error (Missing_root { path = root }))
;;

let ensure_component_visible path =
  if is_durable path
  then Ok false
  else (
    let observed =
      match Fs_compat.path_kind path with
      | Fs_compat.Directory -> Ok ()
      | Fs_compat.Other -> Error (Non_directory_ancestor { path })
      | Fs_compat.Missing ->
        Fs_compat.mkdir_p path;
        (match Fs_compat.path_kind path with
         | Fs_compat.Directory -> Ok ()
         | Fs_compat.Other -> Error (Non_directory_ancestor { path })
         | Fs_compat.Missing -> Error (Creation_not_observed { path }))
    in
    match observed with
    | Error _ as error -> error
    | Ok () -> Ok true)
;;

let rec visible_preparations pending = function
  | [] -> Ok (List.rev pending)
  | ((path, _) as preparation) :: rest ->
    (match ensure_component_visible path with
     | Error _ as error -> error
     | Ok false -> visible_preparations pending rest
     | Ok true -> visible_preparations (preparation :: pending) rest)
;;

let claim components =
  with_prepare_lock (fun () ->
    let cache = Atomic.get durable_cache in
    let cached path = String_set.mem path cache.dirs in
    let rec first_outstanding = function
      | [] -> None
      | path :: rest ->
        if cached path
        then first_outstanding rest
        else (
          match Hashtbl.find_opt preparations path with
          | None -> first_outstanding rest
          | Some preparation ->
            (match Eio.Promise.peek preparation.completion with
             | None -> Some preparation.completion
             | Some () ->
               Hashtbl.remove preparations path;
               first_outstanding rest))
    in
    match first_outstanding components with
    | Some completion -> Await_preparation completion
    | None ->
      let owned =
        List.filter_map
          (fun path ->
             if cached path
             then None
             else (
               let preparation = make_preparation ~cache_revision:cache.revision in
               Hashtbl.replace preparations path preparation;
               Some (path, preparation)))
          components
      in
      (match owned with
       | [] -> Already_durable
       | _ :: _ -> Own_preparations owned))
;;

let release owned =
  let removal =
    try
      with_prepare_lock (fun () ->
        List.iter
          (fun (path, preparation) ->
             match Hashtbl.find_opt preparations path with
             | Some current when current == preparation ->
               Hashtbl.remove preparations path
             | Some _ | None -> ())
          owned);
      Ok ()
    with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  List.iter (fun (_, preparation) -> finish preparation) owned;
  removal
;;

let fsync_directory path =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> Unix.fsync fd)
;;

let prepare_owned ~before_prepare ~before_directory_fsync owned =
  before_prepare ();
  match visible_preparations [] owned with
  | Error error -> Error (Directory_chain_failed error)
  | Ok pending ->
    (* Keep one scheduler-to-systhread handoff per owned chain. Publishing each
       component after its parent fsync lets a sibling start its divergent
       suffix while this owner continues deeper in the original chain. *)
    Eio_guard.run_in_systhread (fun () ->
      List.iter
        (fun (path, preparation) ->
           let parent = Filename.dirname path in
           before_directory_fsync parent;
           fsync_directory parent;
           (* See [ensure]: final cache recheck retries an invalidation race. *)
           ignore (mark_if_current ~revision:preparation.cache_revision path);
           finish preparation)
        pending);
    Ok ()
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

let rec ensure ~before_prepare ~before_directory_fsync dir =
  if is_durable dir
  then Ok ()
  else (
    let root, components = directory_chain_from_root dir in
    match
      capture_operation (fun () ->
        match ensure_root root with
        | Ok () -> Ok ()
        | Error error -> Error (Directory_chain_failed error))
      |> propagate_cancellation
    with
    | Error _ as error -> error
    | Ok () ->
      (match claim components with
       | Already_durable ->
         if is_durable dir
         then Ok ()
         else ensure ~before_prepare ~before_directory_fsync dir
       | Await_preparation completion ->
         Eio.Promise.await completion;
         ensure ~before_prepare ~before_directory_fsync dir
       | Own_preparations owned ->
         let outcome =
           capture_operation (fun () ->
             prepare_owned ~before_prepare ~before_directory_fsync owned)
         in
         let cleanup =
           if Eio_guard.is_ready ()
           then Eio.Cancel.protect (fun () -> release owned)
           else release owned
         in
         (match cleanup, outcome with
          | Ok (), (Error _ as outcome) -> propagate_cancellation outcome
          | Ok (), Ok () ->
            Eio_guard.check_if_ready ();
            if is_durable dir
            then Ok ()
            else ensure ~before_prepare ~before_directory_fsync dir
          | Error (cleanup_exn, cleanup_backtrace), Ok () ->
            propagate_cancellation
              (Error (Operation_failed (cleanup_exn, cleanup_backtrace)))
          | Error (cleanup_exn, _), Error failure ->
            Log.Keeper.warn
              "filesystem_runtime: directory preparation ownership cleanup failed: %s"
              (Printexc.to_string cleanup_exn);
            propagate_cancellation (Error failure))))
;;
