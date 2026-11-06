open Result.Syntax
module Layout = Dated_jsonl.Layout
open Task_history_types

type file = { source : source; relative : string; path : string; snapshot : Fs_compat.owned_regular_file_snapshot }
type inventory = { files : file list; observations : (source * availability) list; roots : Yojson.Safe.t list }
let owned result = Result.map_error (fun _ -> Source_unavailable) result
let root_entry_is_metadata source name = match source with
  | Activity -> Activity_graph.root_entry_is_metadata name
  | Audit -> false

let same_stat_identity (a : Unix.stats) (b : Unix.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino

let snapshot_of_stats (stats : Unix.stats) : Fs_compat.owned_regular_file_snapshot =
  { device = stats.st_dev
  ; inode = stats.st_ino
  ; owner_uid = stats.st_uid
  ; permissions = stats.st_perm land 0o7777
  ; file_size = stats.st_size
  ; modified_at = stats.st_mtime
  ; changed_at = stats.st_ctime
  }

let lstat_owned_regular_file ~owner_uid path =
  try
    let st = Unix.lstat path in
    if st.st_kind <> Unix.S_REG
       || st.st_uid <> owner_uid
       || (st.st_perm land 0o022) <> 0
       || (st.st_perm land 0o400) = 0
       || st.st_size < 0
    then Error Source_unavailable
    else Ok (snapshot_of_stats st)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
  | Unix.Unix_error _ -> Error Source_unavailable

let inspect_owned_dir ~root path =
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:root path with
  | Ok (Fs_compat.Owned_directory stat) -> Ok stat
  | Ok Owned_directory_missing -> Error Source_changed
  | Error _ -> Error Source_unavailable

let inventory ~root ~held =
  let owner_uid = Unix.geteuid () in
  let* observations,roots,files=List.fold_left (fun result source ->
    let* observations,roots,files=result in
    let name=source_name source in
    let directory=Filename.concat root name in
    let* months=Fs_compat.read_owned_directory_if_present ~owner_uid
      ~inventory_root:held ~ownership_root:root directory |> owned in
    match months with
    | None -> Ok ((source,Not_created)::observations,`Assoc ["source",`String name;"state",`String "not-created"]::roots,files)
    | Some months ->
      let* stat=inspect_owned_dir ~root directory in
      let* files=List.fold_left (fun result month ->
        let* collected=result in
        if Layout.entry_is_foreign_to_layout month || root_entry_is_metadata source month
        then Ok collected else
        match Layout.year_and_month_of_directory_name month with
        | None -> Error (Invalid_layout {entry=name ^ "/" ^ month})
        | Some (year,month_number) ->
          let month_dir=Filename.concat directory month in
          let* names=Fs_compat.read_owned_directory ~owner_uid ~inventory_root:held ~ownership_root:root month_dir |> owned in
          let* month_before=inspect_owned_dir ~root month_dir in
          let* collected=
            List.fold_left (fun result filename ->
              let* collected=result in
              if Layout.entry_is_foreign_to_layout filename then Ok collected
              else if not (Layout.day_file_name_is_valid ~year ~month:month_number filename)
              then Error (Invalid_layout {entry=name ^ "/" ^ month ^ "/" ^ filename})
              else
                let path=Filename.concat month_dir filename in
                let* snapshot=lstat_owned_regular_file ~owner_uid path in
                Ok ({source;relative=name ^ "/" ^ month ^ "/" ^ filename;path;snapshot}::collected)
            ) (Ok collected) names
          in
          let* month_after=inspect_owned_dir ~root month_dir in
          if not (same_stat_identity month_before month_after) then Error Source_changed
          else Ok collected
      ) (Ok files) months in
      Ok ((source,Observed)::observations,`Assoc ["source",`String name;"state",`String "observed";
        "device",`Int stat.st_dev;"inode",`Int stat.st_ino]::roots,files)
  ) (Ok ([],[],[])) sources in
  if List.for_all (fun (_,availability) -> availability=Not_created) observations then Error Source_unavailable
  else Ok {observations=List.rev observations;roots=List.rev roots;
    files=List.sort (fun left right -> compare_relative right.relative left.relative) files}

let capture files = List.filter_map (fun source ->
  Option.map (fun file -> {file=file.relative;size=file.snapshot.file_size})
    (List.find_opt (fun file -> file.source=source) files)) sources
let prefix ~ceilings files = List.filter (fun file ->
  List.exists (fun (c:ceiling) -> match dated_parts c.file with
    | Some (source,_,_) -> file.source=source && compare_relative file.relative c.file<=0
    | None -> false) ceilings) files
let inventory_hash ~ceilings inventory =
  let rows=List.map (fun file -> let s=file.snapshot in
    let identity=["file",`String file.relative;"device",`Int s.device;"inode",`Int s.inode] in
    let fields=if List.exists (fun (c:ceiling) -> c.file=file.relative && c.size<=s.file_size) ceilings
      then identity else identity @ ["size",`Int s.file_size;"modified",`Float s.modified_at;"changed",`Float s.changed_at] in
    `Assoc fields) (prefix ~ceilings inventory.files) in
  hash (Yojson.Safe.to_string (`List (inventory.roots @ rows)))
