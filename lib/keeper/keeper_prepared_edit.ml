open Result.Syntax

module Scope = Agent_core.Tool_contract.Resource_scope

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
  { owner : owner
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
  else Error "prepared Edit parent is no longer a directory"
;;

let prepare ~sw ~config ~meta ~args ~confined =
  match Fs_compat.get_fs_opt (),
        split_leaf (Keeper_alerting_path.confined_relative_components confined),
        split_leaf (Keeper_alerting_path.confined_endpoint_components confined) with
  | None, _, _ | _, None, _ | _, _, None -> Ok None
  | Some fs, Some (parent_components, leaf), Some (source_components, source_leaf) ->
    let opened = ref [] in
    let released = Atomic.make false in
    let release_partial () = Eio.Cancel.protect (fun () ->
      if not (Atomic.exchange released true) then List.iter (fun close -> close ()) !opened) in
    let open_dir path =
      let directory = Eio.Path.open_dir ~sw path in
      opened := (fun () -> Eio.Resource.close (fst directory)) :: !opened;
      (directory :> Eio.Fs.dir_ty Eio.Path.t)
    in
    let rec descend parent = function
      | [] -> parent
      | component :: rest -> descend (open_dir Eio.Path.(parent / component)) rest
    in
    let inspect_directory ~access ~leaf root components =
      let capability = descend root components in
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
         | [] -> Error "prepared Edit has no native directory identity"
         | (_, observed) :: _ ->
           if not (equal_identity actual observed) then
             Error "prepared Edit native parent differs from its pinned capability"
           else
             let* occupied = entry_identity ~parent:actual leaf in
             let* ancestry = List.fold_right (fun (_, resource) accumulated ->
               let* tail = accumulated in
               let* resource = scope_identity resource in
               Ok (resource :: tail)) native_chain (Ok []) in
             Ok (Some { capability; components; identity = actual; native_chain
                      ; scope = Scope.create ~access ~occupied ~ancestors:ancestry }))
    in
    let inspect () =
      let anchor = open_dir Eio.Path.(fs / Keeper_alerting_path.confined_anchor_root confined) in
      let relative = Keeper_alerting_path.confined_root_relative_path confined in
      let root = if String.equal relative "." then anchor else open_dir Eio.Path.(anchor / relative) in
      let* () = Keeper_alerting_path.verify_confined_root_capability confined root in
      let* target = inspect_directory ~access:Scope.Write ~leaf root parent_components in
      let* source = inspect_directory ~access:Scope.Read ~leaf:source_leaf root source_components in
      match target, source with
      | Some target, Some source ->
        let source_stat = Eio.Path.stat ~follow:true Eio.Path.(source.capability / source_leaf) in
        if source_stat.kind <> `Regular_file then Ok None
        else
          let target_stat = Eio.Path.stat ~follow:false Eio.Path.(target.capability / leaf) in
          let* target_object_scope = object_scope ~access:Scope.Write target target_stat in
          let* source_object_scope = object_scope ~access:Scope.Read source source_stat in
          Ok (Some { owner = owner ~config ~meta; args; root
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

let with_parents ~config ~meta ~args ~confined prepared continue =
  if Atomic.get prepared.released then Error "prepared Edit resources were released"
  else if not (equal_owner prepared.owner (owner ~config ~meta) && Yojson.Safe.equal args prepared.args)
  then Error "prepared Edit belongs to a different owner or input"
  else if not (String.equal prepared.root_path (Keeper_alerting_path.confined_root confined)
               && split_leaf (Keeper_alerting_path.confined_relative_components confined)
                  = Some (prepared.target.components, prepared.leaf)
               && split_leaf (Keeper_alerting_path.confined_endpoint_components confined)
                  = Some (prepared.source.components, prepared.source_leaf))
  then Error "prepared Edit confined target or source changed"
  else
    let validate directory =
      let* held = stat_directory directory.capability in
      let* current = stat_directory
          (List.fold_left (fun path component -> Eio.Path.(path / component))
             prepared.root directory.components) in
      if not (equal_identity directory.identity held && equal_identity held current) then
        Error "prepared Edit parent binding changed before execution"
      else
        match Fs_compat.get_fs_opt () with
        | None -> Error "prepared Edit filesystem is unavailable"
        | Some fs ->
          List.fold_left (fun result (path, expected) ->
            let* () = result in
            let* actual = stat_directory Eio.Path.(fs / path) in
            if equal_identity actual expected then Ok ()
            else Error "prepared Edit physical ancestry changed before execution")
            (Ok ()) directory.native_chain
    in
    let validation =
      try
        let* () = Keeper_alerting_path.verify_confined_root_capability confined prepared.root in
        let* () = validate prepared.target in
        validate prepared.source
      with Eio.Io _ as error -> Error (Printexc.to_string error)
    in
    let* () = validation in
    continue ~parent_dir:prepared.target.capability ~parent_components:prepared.target.components
      ~leaf:prepared.leaf ~source_parent_dir:prepared.source.capability ~source_leaf:prepared.source_leaf
;;
