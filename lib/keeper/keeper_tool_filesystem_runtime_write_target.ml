open Result.Syntax
open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared

let resolve_write_attribution = Keeper_write_attribution.resolve
;;

let created_file_permissions = 0o644
let created_directory_permissions = 0o755

let same_file_resource (left : Eio.File.Stat.t) (right : Eio.File.Stat.t) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let replacement_file_permissions ~parent_dir ~leaf =
  let target = Eio.Path.(parent_dir / leaf) in
  try
    let resource = Eio.Path.stat ~follow:false target in
    match resource.kind with
    | `Symbolic_link -> Ok created_file_permissions
    | `Regular_file -> Ok resource.perm
    | (`Block_device
      | `Character_special
      | `Directory
      | `Fifo
      | `Socket
      | `Unknown) as kind ->
      Error
        (Fmt.str
           "filesystem atomic replacement target must be a regular file, symbolic link, or missing entry; found %a"
           Eio.File.Stat.pp_kind
           kind)
  with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok created_file_permissions
;;

let load_open_file file =
  Eio.Buf_read.parse_exn ~max_size:max_int Eio.Buf_read.take_all file
;;

let rec with_deepest_existing_parent
          parent_dir
          traversed_components_rev
          remaining_components
          f
  =
  match remaining_components with
  | [] ->
    f
      ~parent_dir
      ~parent_components:(List.rev traversed_components_rev)
      ~missing_parents:[]
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Ok child_dir ->
       with_deepest_existing_parent
         child_dir
         (component :: traversed_components_rev)
         rest
         f
     | Error `Missing ->
       f
         ~parent_dir
         ~parent_components:(List.rev traversed_components_rev)
         ~missing_parents:remaining_components)
;;

let rec with_open_directory_components ~on_missing parent_dir components f =
  match components with
  | [] -> f parent_dir
  | component :: rest ->
    Eio.Switch.run @@ fun sw ->
    (match
       try Ok (Eio.Path.open_dir ~sw Eio.Path.(parent_dir / component)) with
       | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Error `Missing
     with
     | Error `Missing -> on_missing ()
     | Ok child_dir ->
       with_open_directory_components ~on_missing child_dir rest f)
;;

let rec split_leaf_components = function
  | [] -> None
  | [ leaf ] -> Some ([], leaf)
  | component :: rest ->
    Option.map
      (fun (parent, leaf) -> component :: parent, leaf)
      (split_leaf_components rest)
;;

let with_confined_write_parent confined f =
  match Fs_compat.get_fs_opt () with
  | None -> Error (fs_guidance_text Capability_unavailable)
  | Some fs ->
    (try
       let anchor_root = Keeper_alerting_path.confined_anchor_root confined in
       let root_relative_path =
         Keeper_alerting_path.confined_root_relative_path confined
       in
       let target_components =
         Keeper_alerting_path.confined_relative_components confined
       in
       let with_root root_dir =
         let* () =
           Keeper_alerting_path.verify_confined_root_capability confined root_dir
         in
         match split_leaf_components target_components with
         | None -> Error "filesystem target has no writable leaf"
         | Some (parent_components, leaf) ->
           with_deepest_existing_parent
             root_dir
             []
             parent_components
             (fun ~parent_dir ~parent_components ~missing_parents ->
                f
                  ~root_dir
                  ~parent_dir
                  ~parent_components
                  ~missing_parents
                  ~leaf)
       in
       Eio.Path.with_open_dir Eio.Path.(fs / anchor_root) @@ fun anchor_dir ->
       if String.equal root_relative_path "."
       then with_root anchor_dir
       else
         Eio.Path.with_open_dir Eio.Path.(anchor_dir / root_relative_path)
         @@ fun root_dir ->
         with_root root_dir
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | Eio.Io _ as exn -> Error (Printexc.to_string exn))
;;
