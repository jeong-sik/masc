module Read_backs = Set_util.StringMap

(* What a file read returns for [written], or why its snapshot does not
   decode. [written] is compared physically. The Owner publishes an immutable
   meta and a new one with every change, so the same value is the same file
   content, and comparing it costs nothing however large the meta is. *)
type read_back =
  { base_path : string
  ; keeper_name : string
  ; written : Keeper_meta_contract.keeper_meta
  ; as_read : (Keeper_meta_contract.keeper_meta, string) result
  }

(* One entry per Keeper whose Owner stands for its file. Readers on fibers and
   on system threads share it, so it is an immutable map replaced by
   compare-and-set. A lost race costs one more read-back, never a wrong one:
   an entry is only used when its [written] is the meta just read. *)
let read_backs : read_back Read_backs.t Atomic.t = Atomic.make Read_backs.empty

let key ~base_path ~keeper_name = base_path ^ "\000" ^ keeper_name

(* An entry answers a read only while the Keeper's Owner still holds its
   [written]. One that no longer can is left by a Keeper that was removed or
   whose Owner stopped, and nothing reads that Keeper again to replace it. *)
let still_answers entry =
  match
    Keeper_owner_projection.meta_the_file_holds
      ~base_path:entry.base_path
      ~keeper_name:entry.keeper_name
  with
  | Some held -> held == entry.written
  | None -> false
;;

(* Every insert drops the entries that no longer answer, so the map holds at
   most one entry per Owner that stood at the last insert. The scan is one
   projection lookup per entry, once per meta an Owner publishes. *)
let rec remember key entry =
  let seen = Atomic.get read_backs in
  let kept = Read_backs.filter (fun _key other -> still_answers other) seen in
  if not (Atomic.compare_and_set read_backs seen (Read_backs.add key entry kept))
  then remember key entry
;;

let read_back ~base_path ~keeper_name written =
  let key = key ~base_path ~keeper_name in
  match Read_backs.find_opt key (Atomic.get read_backs) with
  | Some entry when entry.written == written -> entry.as_read
  | Some _ | None ->
    let as_read = Keeper_meta_store.snapshot_read_back written in
    (match as_read with
     | Ok _ -> ()
     | Error detail ->
       Log.Keeper.warn
         ~keeper_name
         "the Owner's meta does not read back from its own snapshot, reading \
          the meta file instead: %s"
         detail);
    remember key { base_path; keeper_name; written; as_read };
    as_read
;;

let read (config : Workspace.config) name ~read_file =
  let base_path = config.base_path in
  match Keeper_owner_projection.meta_the_file_holds ~base_path ~keeper_name:name with
  | None -> read_file ()
  | Some written ->
    (match read_back ~base_path ~keeper_name:name written with
     | Ok meta -> Ok (Some meta)
     | Error _ -> read_file ())
;;
