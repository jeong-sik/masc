open Result.Syntax

module Scope = Agent_core.Tool_contract.Resource_scope

type operation = Read | Edit

type identity = { device : int64; inode : int64 }
type directory =
  { capability : Eio.Fs.dir_ty Eio.Path.t
  ; components : string list
  ; identity : identity
  ; native_chain : (string * identity) list
  ; scope : Scope.t
  }

type owner =
  { base_path : string
  ; keeper_name : string
  ; task_id : Keeper_id.Task_id.t option
  ; trace_id : Keeper_id.Trace_id.t
  }

type t =
  { operation : operation
  ; owner : owner
  ; args : Yojson.Safe.t
  ; root : Eio.Fs.dir_ty Eio.Path.t
  ; root_path : string
  ; target : directory
  ; leaf : string
  ; source : directory
  ; source_leaf : string
  ; target_object_scope : Scope.t
  ; source_object_scope : Scope.t
  ; released : bool Atomic.t
  ; release_resources : unit -> unit
  }

let owner ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  { base_path = config.base_path; keeper_name = meta.name
  ; task_id = meta.current_task_id; trace_id = meta.runtime.trace_id }
;;

let equal_owner left right =
  String.equal left.base_path right.base_path
  && String.equal left.keeper_name right.keeper_name
  && Option.equal Keeper_id.Task_id.equal left.task_id right.task_id
  && Keeper_id.Trace_id.equal left.trace_id right.trace_id
;;

let identity (stat : Eio.File.Stat.t) = { device = stat.dev; inode = stat.ino }
let equal_identity left right =
  Int64.equal left.device right.device && Int64.equal left.inode right.inode
;;

let scope_identity resource =
  Scope.identity ~namespace:"filesystem-directory"
    ~key:(Printf.sprintf "%Ld:%Ld" resource.device resource.inode)
  |> Result.map_error (function
    | Scope.Empty_namespace -> "filesystem resource namespace is empty"
    | Scope.Empty_key -> "filesystem resource identity is empty")
;;

(* Patch atomically replaces one lexical directory entry. Parent identity plus
   leaf survives an earlier replacement and unifies directory aliases. Object
   claims below additionally retain the backend's inode-based mutation lease
   and unify filesystem spelling aliases without guessed case folding. *)
let entry_identity ~parent leaf =
  Scope.identity ~namespace:"filesystem-entry"
    ~key:(Printf.sprintf "%Ld:%Ld:%s" parent.device parent.inode leaf)
  |> Result.map_error (function
    | Scope.Empty_namespace -> "filesystem entry namespace is empty"
    | Scope.Empty_key -> "filesystem entry identity is empty")
;;

let object_scope ~access directory stat =
  let resource = identity stat in
  let* occupied = Scope.identity ~namespace:"filesystem-object"
      ~key:(Printf.sprintf "%Ld:%Ld" resource.device resource.inode)
    |> Result.map_error (function
      | Scope.Empty_namespace -> "filesystem object namespace is empty"
      | Scope.Empty_key -> "filesystem object identity is empty") in
  let* ancestry = List.fold_right (fun (_, resource) accumulated ->
    let* tail = accumulated in
    let* resource = scope_identity resource in
    Ok (resource :: tail)) directory.native_chain (Ok []) in
  Ok (Scope.create ~access ~occupied ~ancestors:ancestry)
;;

let rec split_leaf = function
  | [] -> None
  | [leaf] -> Some ([], leaf)
  | component :: rest ->
    Option.map (fun (parents, leaf) -> component :: parents, leaf) (split_leaf rest)
;;

let rec ancestors path =
  let parent = Filename.dirname path in
  if String.equal parent path then [path] else path :: ancestors parent
;;

let stat_directory path =
  let stat = Eio.Path.stat ~follow:true path in
  if stat.kind = `Directory then Ok (identity stat)
  else Error "prepared file parent is no longer a directory"
;;

(* A directory opened with [Eio.Path.open_dir] is closed when its switch ends.
   eio_posix gives it no [Close] handler, so [Eio.Resource.close] raises
   "Operation not supported" there (macOS); only eio_linux accepts it. A
   preparation has to give its directories back before it answers [Ok None] or
   [Error], and when the SDK drops one it never ran, long before the caller's
   switch ends. It therefore opens them under a switch of its own, which a
   daemon fiber of the caller's switch keeps alive until [release] ends it. *)
module Held_switch : sig
  type t

  val create : sw:Eio.Switch.t -> t
  val switch : t -> Eio.Switch.t
  val release : t -> unit
end = struct
  type t =
    { inner : Eio.Switch.t
    ; finish : unit Eio.Promise.u
    ; finished : bool Atomic.t
    ; closed : unit Eio.Promise.t
    }

  let create ~sw =
    let ready, resolve_ready = Eio.Promise.create () in
    let finish_signal, finish = Eio.Promise.create () in
    let closed, resolve_closed = Eio.Promise.create () in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Switch.run (fun inner ->
        (* Registered before any directory is opened, so it runs after their
           release hooks: [closed] means every descriptor is closed. *)
        Eio.Switch.on_release inner (fun () -> Eio.Promise.resolve resolve_closed ());
        Eio.Promise.resolve resolve_ready inner;
        Eio.Promise.await finish_signal);
      `Stop_daemon);
    (* [Fiber.fork_daemon] runs the daemon up to its first suspension before it
       returns, so [ready] is already resolved here and the await returns at
       once. When [sw] is already cancelled it starts nothing, [ready] stays
       unresolved, and the await raises [Cancelled]: the caller runs under
       [sw], so its cancel context is cancelled too. *)
    { inner = Eio.Promise.await ready; finish; finished = Atomic.make false; closed }
  ;;

  let switch held = held.inner

  (* A second call only waits for [closed], so [finish] is resolved once even
     when the caller's own guard is missing. *)
  let release held =
    if not (Atomic.exchange held.finished true) then Eio.Promise.resolve held.finish ();
    Eio.Promise.await held.closed
  ;;
end

let inspect_directory_capability ~fs ~access ~leaf ~components
    (capability : Eio.Fs.dir_ty Eio.Path.t) =
  match Eio.Path.native capability with
  | None -> Ok None
  | Some native ->
    let native = Fs_compat.realpath native in
    let* native_chain = List.fold_right (fun path accumulated ->
      let* tail = accumulated in
      let* identity = stat_directory Eio.Path.(fs / path) in
      Ok ((path, identity) :: tail)) (ancestors native) (Ok []) in
    let* actual = stat_directory capability in
    (match native_chain with
     | [] -> Error "prepared file has no native directory identity"
     | (_, observed) :: _ ->
       if not (equal_identity actual observed) then
         Error "prepared file native parent differs from its pinned capability"
       else
         let* occupied = entry_identity ~parent:actual leaf in
         let* ancestry = List.fold_right (fun (_, resource) accumulated ->
           let* tail = accumulated in
           let* resource = scope_identity resource in
           Ok (resource :: tail)) native_chain (Ok []) in
         Ok (Some { capability; components; identity = actual; native_chain
                  ; scope = Scope.create ~access ~occupied ~ancestors:ancestry }))
;;

let inspect_directory ~sw ~fs ~access ~leaf root components =
  let capability = List.fold_left (fun parent component ->
    let directory = Eio.Path.open_dir ~sw Eio.Path.(parent / component) in
    (directory :> Eio.Fs.dir_ty Eio.Path.t)) root components in
  inspect_directory_capability ~fs ~access ~leaf ~components capability
;;

let validate_directory ~root directory =
  let* held = stat_directory directory.capability in
  let* current = stat_directory
      (List.fold_left (fun path component -> Eio.Path.(path / component))
         root directory.components) in
  if not (equal_identity directory.identity held && equal_identity held current) then
    Error "prepared file parent binding changed before execution"
  else
    match Fs_compat.get_fs_opt () with
    | None -> Error "prepared file filesystem is unavailable"
    | Some fs ->
      List.fold_left (fun result (path, expected) ->
        let* () = result in
        let* actual = stat_directory Eio.Path.(fs / path) in
        if equal_identity actual expected then Ok ()
        else Error "prepared file physical ancestry changed before execution")
        (Ok ()) directory.native_chain
;;

let prepare ~sw ~operation ~config ~meta ~args ~confined =
  let target_access = match operation with Read -> Scope.Read | Edit -> Scope.Write in
  match Fs_compat.get_fs_opt (),
        split_leaf (Keeper_alerting_path.confined_relative_components confined),
        split_leaf (Keeper_alerting_path.confined_endpoint_components confined) with
  | None, _, _ | _, None, _ | _, _, None -> Ok None
  | Some fs, Some (parent_components, leaf), Some (source_components, source_leaf) ->
    let held = Held_switch.create ~sw in
    let released = Atomic.make false in
    let release_partial () = Eio.Cancel.protect (fun () ->
      if not (Atomic.exchange released true) then Held_switch.release held) in
    let open_dir path =
      let directory = Eio.Path.open_dir ~sw:(Held_switch.switch held) path in
      (directory :> Eio.Fs.dir_ty Eio.Path.t)
    in
    let inspect () =
      let anchor = open_dir Eio.Path.(fs / Keeper_alerting_path.confined_anchor_root confined) in
      let relative = Keeper_alerting_path.confined_root_relative_path confined in
      let root = if String.equal relative "." then anchor else open_dir Eio.Path.(anchor / relative) in
      let* () = Keeper_alerting_path.verify_confined_root_capability confined root in
      let* target = inspect_directory ~sw:(Held_switch.switch held) ~fs ~access:target_access ~leaf root parent_components in
      let* source = inspect_directory ~sw:(Held_switch.switch held) ~fs ~access:Scope.Read ~leaf:source_leaf root source_components in
      match target, source with
      | Some target, Some source ->
        let source_stat = Eio.Path.stat ~follow:true Eio.Path.(source.capability / source_leaf) in
        if source_stat.kind <> `Regular_file then Ok None
        else
          let target_stat = Eio.Path.stat ~follow:false Eio.Path.(target.capability / leaf) in
          let* target_object_scope = object_scope ~access:target_access target target_stat in
          let* source_object_scope = object_scope ~access:Scope.Read source source_stat in
          Ok (Some { operation; owner = owner ~config ~meta; args; root
                   ; root_path = Keeper_alerting_path.confined_root confined
                   ; target; leaf; source; source_leaf; target_object_scope; source_object_scope
                   ; released; release_resources = release_partial })
      | None, _ | _, None -> Ok None
    in
    match
      try inspect () with
      | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None
      | Eio.Io _ as error -> Error (Printexc.to_string error)
      | Unix.Unix_error _ as error -> Error (Printexc.to_string error)
      | Sys_error detail -> Error detail
    with
    | Ok (Some _ as prepared) ->
      Eio.Switch.on_release sw (fun () -> Atomic.set released true);
      Ok prepared
    | Ok None -> release_partial (); Ok None
    | Error error -> release_partial (); Error error
    | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      release_partial ();
      Printexc.raise_with_backtrace error backtrace
;;

let scopes prepared =
  [prepared.target.scope; prepared.source.scope
  ; prepared.target_object_scope; prepared.source_object_scope]
;;
let release prepared = prepared.release_resources ()

let with_parents ~operation ~config ~meta ~args ~confined prepared continue =
  if Atomic.get prepared.released then Error "prepared file resources were released"
  else if operation <> prepared.operation then Error "prepared file operation changed"
  else if not (equal_owner prepared.owner (owner ~config ~meta) && Yojson.Safe.equal args prepared.args)
  then Error "prepared file belongs to a different owner or input"
  else if not (String.equal prepared.root_path (Keeper_alerting_path.confined_root confined)
               && split_leaf (Keeper_alerting_path.confined_relative_components confined)
                  = Some (prepared.target.components, prepared.leaf))
  then Error "prepared file confined target changed"
  else
    let* source, source_leaf =
      let endpoint = split_leaf (Keeper_alerting_path.confined_endpoint_components confined) in
      if endpoint = Some (prepared.source.components, prepared.source_leaf) then
        Ok (prepared.source, prepared.source_leaf)
      else if operation = Read && endpoint = Some (prepared.target.components, prepared.leaf) then
        (* A preceding atomic Edit may replace a symlink with the regular
           entry the Read already claimed. That exact entry remains bound to
           its pinned parent; a redirect to any other new source is refused. *)
        Ok (prepared.target, prepared.leaf)
      else Error "prepared file confined source changed"
    in
    let validation =
      try
        let* () = Keeper_alerting_path.verify_confined_root_capability confined prepared.root in
        let* () = validate_directory ~root:prepared.root prepared.target in
        validate_directory ~root:prepared.root source
      with Eio.Io _ as error -> Error (Printexc.to_string error)
    in
    let* () = validation in
    continue ~parent_dir:prepared.target.capability ~parent_components:prepared.target.components
      ~leaf:prepared.leaf ~source_parent_dir:source.capability ~source_leaf
;;

module Write = struct
  type t =
    { operation : Keeper_tool_write_mode.t
    ; owner : owner
    ; args : Yojson.Safe.t
    ; root : Eio.Fs.dir_ty Eio.Path.t
    ; root_path : string
    ; target : directory
    ; target_missing_parents : string list
    ; leaf : string
    ; source : directory
    ; source_missing_parents : string list
    ; source_leaf : string
    ; resources : Scope.t list
    ; released : bool Atomic.t
    ; release_resources : unit -> unit
    }

  (* Both preparation and consumption only open existing directories here.
     The caller owns every opened capability's switch. Creation stays in the
     original post-Gate consumer, with its directory commit observations. *)
  let inspect_parent ~sw ~fs ~leaf root components =
    let rec existing parent traversed_rev remaining =
      match remaining with
      | [] -> parent, List.rev traversed_rev, []
      | component :: rest ->
          (match Eio.Path.open_dir ~sw Eio.Path.(parent / component) with
           | child -> existing (child :> Eio.Fs.dir_ty Eio.Path.t)
               (component :: traversed_rev) rest
           | exception Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
               parent, List.rev traversed_rev, remaining)
    in
    let capability, components, missing = existing root [] components in
    let occupied_leaf = match missing with [] -> leaf | component :: _ -> component in
    inspect_directory_capability ~fs ~access:Scope.Write ~leaf:occupied_leaf
      ~components capability
    |> Result.map (Option.map (fun directory -> directory, missing))

  let within_ancestor ~ancestor directory =
    if List.exists (fun (_, identity) -> equal_identity ancestor.identity identity)
         directory.native_chain
    then Ok ()
    else Error "prepared Write resolved outside its claimed physical ancestor"

  let prepare ~sw ~operation ~config ~meta ~args ~confined =
    match operation, Fs_compat.get_fs_opt (),
          split_leaf (Keeper_alerting_path.confined_relative_components confined),
          split_leaf (Keeper_alerting_path.confined_endpoint_components confined) with
    | Keeper_tool_write_mode.Patch, _, _, _
    | _, None, _, _ | _, _, None, _ | _, _, _, None -> Ok None
    | (Keeper_tool_write_mode.Overwrite | Keeper_tool_write_mode.Append), Some fs,
      Some (parents, leaf), Some (source_parents, source_leaf) ->
      let held = Held_switch.create ~sw in
      let released = Atomic.make false in
      let release_resources () = Eio.Cancel.protect (fun () ->
        if not (Atomic.exchange released true) then Held_switch.release held) in
      let open_dir path =
        let directory = Eio.Path.open_dir ~sw:(Held_switch.switch held) path in
        (directory :> Eio.Fs.dir_ty Eio.Path.t) in
      let object_claim ~follow directory ~missing leaf =
        match missing with
        | _ :: _ -> Ok None
        | [] ->
            (match Eio.Path.stat ~follow Eio.Path.(directory.capability / leaf) with
             | stat when stat.kind = `Regular_file || stat.kind = `Symbolic_link ->
                 object_scope ~access:Scope.Write directory stat |> Result.map Option.some
             | _ -> Error "prepared Write target must be a regular file, symbolic link or missing entry"
             | exception Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None) in
      let missing_entry_claim directory =
        (* An absent entry has no inode to unify filesystem spelling aliases.
           Its actual parent owns creation; do not guess case/Unicode folding. *)
        let* occupied = scope_identity directory.identity in
        let* ancestry = List.fold_right (fun (_, resource) accumulated ->
          let* tail = accumulated in
          if equal_identity resource directory.identity then Ok tail
          else let* resource = scope_identity resource in Ok (resource :: tail))
            directory.native_chain (Ok []) in
        Ok (Scope.create ~access:Scope.Write ~occupied ~ancestors:ancestry) in
      let claim directory = function
        | Some resource -> Ok resource
        | None -> missing_entry_claim directory in
      let inspect () =
        let anchor = open_dir Eio.Path.(fs / Keeper_alerting_path.confined_anchor_root confined) in
        let relative = Keeper_alerting_path.confined_root_relative_path confined in
        let root = if String.equal relative "." then anchor else open_dir Eio.Path.(anchor / relative) in
        let* () = Keeper_alerting_path.verify_confined_root_capability confined root in
        let* target = inspect_parent ~sw:(Held_switch.switch held) ~fs ~leaf root parents in
        let* source = inspect_parent ~sw:(Held_switch.switch held) ~fs
            ~leaf:source_leaf root source_parents in
        match target, source with
        | Some (target, target_missing_parents), Some (source, source_missing_parents) ->
            let* target_object = object_claim ~follow:false target
                ~missing:target_missing_parents leaf in
            let* source_object = object_claim
                ~follow:(operation = Keeper_tool_write_mode.Append) source
                ~missing:source_missing_parents source_leaf in
            let* target_object = claim target target_object in
            let* source_object = claim source source_object in
            let resources = target.scope :: source.scope
                :: [target_object; source_object] in
            Ok (Some {operation; owner=owner ~config ~meta; args; root;
              root_path=Keeper_alerting_path.confined_root confined;
              target; target_missing_parents; leaf; source; source_missing_parents;
              source_leaf; resources; released; release_resources})
        | None, _ | _, None -> Ok None in
      match (try inspect () with
        | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None
        | Eio.Io _ as error -> Error (Printexc.to_string error)
        | Unix.Unix_error _ as error -> Error (Printexc.to_string error)
        | Sys_error detail -> Error detail) with
      | Ok (Some _ as prepared) ->
          Eio.Switch.on_release sw (fun () -> Atomic.set released true);
          Ok prepared
      | Ok None -> release_resources (); Ok None
      | Error error -> release_resources (); Error error
      | exception error ->
          let backtrace = Printexc.get_raw_backtrace () in
          release_resources ();
          Printexc.raise_with_backtrace error backtrace

  let scopes prepared = prepared.resources
  let release prepared = prepared.release_resources ()

  let with_parents ~operation ~config ~meta ~args ~confined prepared consume =
    if Atomic.get prepared.released then Error "prepared Write resources were released"
    else if operation <> prepared.operation then Error "prepared Write operation changed"
    else if not (equal_owner prepared.owner (owner ~config ~meta)
                 && Yojson.Safe.equal prepared.args args) then
      Error "prepared Write belongs to a different owner or input"
    else if not (String.equal prepared.root_path (Keeper_alerting_path.confined_root confined)) then
      Error "prepared Write confined root changed"
    else
      Eio.Switch.run @@ fun sw ->
      let* target, missing_parents, leaf = try
        let* fs = match Fs_compat.get_fs_opt () with
          | Some fs -> Ok fs | None -> Error "prepared Write filesystem is unavailable" in
        let target = split_leaf (Keeper_alerting_path.confined_relative_components confined) in
        let endpoint = split_leaf (Keeper_alerting_path.confined_endpoint_components confined) in
        let* target_parents, leaf = match target with
          | Some target -> Ok target | None -> Error "prepared Write target has no leaf" in
        let* source_parents, source_leaf = match endpoint with
          | Some source -> Ok source | None -> Error "prepared Write source has no leaf" in
        let* () =
          let* () = Keeper_alerting_path.verify_confined_root_capability confined prepared.root in
          validate_directory ~root:prepared.root prepared.target in
        let* target, missing_parents = match prepared.target_missing_parents with
          | [] ->
              if target = Some (prepared.target.components, prepared.leaf)
              then Ok (prepared.target, [])
              else Error "prepared Write confined target changed"
          | _ :: _ ->
              let* current = inspect_parent ~sw ~fs ~leaf prepared.root target_parents in
              (match current with
               | None -> Error "prepared Write target parent has no native identity"
               | Some (current, missing) ->
                   let* () = within_ancestor ~ancestor:prepared.target current in
                   Ok (current, missing)) in
        let* () = match prepared.source_missing_parents with
          | [] ->
              let* source =
                if endpoint = Some (prepared.source.components, prepared.source_leaf) then Ok prepared.source
                else if operation = Keeper_tool_write_mode.Append
                    && endpoint = Some (target_parents, leaf) then Ok prepared.target
                else Error "prepared Write confined source changed" in
              validate_directory ~root:prepared.root source
          | _ :: _ ->
              let* () = validate_directory ~root:prepared.root prepared.source in
              let* current = inspect_parent ~sw ~fs ~leaf:source_leaf prepared.root source_parents in
              (match current with
               | None -> Error "prepared Write source parent has no native identity"
               | Some (current, _) -> within_ancestor ~ancestor:prepared.source current) in
        Ok (target, missing_parents, leaf)
      with
      | Eio.Cancel.Cancelled _ as error -> raise error
      | Eio.Io _ as error -> Error (Printexc.to_string error)
      | Unix.Unix_error _ as error -> Error (Printexc.to_string error)
      | Sys_error detail -> Error detail
      in
      consume ~root_dir:prepared.root ~parent_dir:target.capability
        ~parent_components:target.components ~missing_parents ~leaf
end
