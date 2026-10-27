module P = Endpoint_job_protocol
open Result.Syntax

type protection_refusal =
  | Payload_is_controller | Payload_is_root | Invalid_payload_uid | Invalid_owner | Invalid_root_path
  | Root_not_private | Root_owner_mismatch | Unsafe_ancestor | Root_identity_changed

type error =
  | Protection_refused of protection_refusal
  | Authority_unavailable of string
  | Publication_failed of Fs_compat.capability_write_error
  | Recovery_unavailable of string
  | Lock_failed of File_lock_eio.durable_lock_error
  | Commit_unconfirmed of string
  | Busy | Binding_mismatch | Invalid_request of P.codec_error | Execution_identity_changed
  | Endpoint_replaced | Missing_original | Admission_incomplete
  | Unsupported_version of { expected : int; actual : int } | Corrupt_original of string
  | Launch_already_requested | Launch_cancelled | Launch_intent_spent | Stale_record
  | Cleanup_failed of { primary : error option; cause : File_lock_eio.durable_lock_error }

let rec error_to_string = function
  | Protection_refused refusal -> "endpoint registry protection refused: " ^ (match refusal with
      | Payload_is_controller -> "payload shares controller UID"
      | Payload_is_root -> "root payload needs a namespace/capability boundary"
      | Invalid_payload_uid -> "invalid payload UID" | Invalid_owner -> "invalid owner"
      | Invalid_root_path -> "control root must be an absolute non-NUL path"
      | Root_not_private -> "control root is not mode0700"
      | Root_owner_mismatch -> "control root owner differs from controller"
      | Unsafe_ancestor -> "control root has an unprotected ancestor"
      | Root_identity_changed -> "control root identity changed")
  | Authority_unavailable detail -> "endpoint registry authority unavailable: " ^ detail
  | Publication_failed error -> Fs_compat.capability_write_error_to_string error
  | Recovery_unavailable detail -> "endpoint registry publication recovery unavailable: " ^ detail
  | Lock_failed error -> File_lock_eio.durable_lock_error_to_string error
  | Commit_unconfirmed detail -> "endpoint registry commit unconfirmed: " ^ detail
  | Busy -> "endpoint operation is busy"
  | Binding_mismatch -> "endpoint original binding mismatch"
  | Invalid_request error -> P.error_to_string error
  | Execution_identity_changed -> "endpoint original execution identity changed"
  | Endpoint_replaced -> "endpoint original boot was replaced"
  | Missing_original -> "endpoint original claim or job data is missing"
  | Admission_incomplete -> "endpoint original admission is still preparing"
  | Unsupported_version {expected;actual} ->
    Printf.sprintf "endpoint original claim has unsupported version %d (expected %d)" actual expected
  | Corrupt_original detail -> "endpoint original record is corrupt: " ^ detail
  | Launch_already_requested -> "endpoint launch is already requested; reconcile original handle"
  | Launch_cancelled -> "endpoint original launch was cancelled"
  | Launch_intent_spent -> "endpoint launch permit was already consumed"
  | Stale_record -> "endpoint original record changed"
  | Cleanup_failed {primary;cause} ->
    (match primary with None -> "endpoint transaction cleanup failed"
     | Some error -> error_to_string error) ^ "; " ^ File_lock_eio.durable_lock_error_to_string cause

type identity = { device : int64; inode : int64 }
type claim_state =
  | Preparing
  | Ready of identity
  | Launch_requested of {job : identity; launch_id : P.Id.t}
  | Cancel_requested of {job : identity; launch_id : P.Id.t option}
type claim =
  { binding : P.binding; admission_id : P.Id.t; controller_uid : int; payload_uid : int
  ; root : identity; revision : int64; state : claim_state }

type t =
  { sw : Eio.Switch.t; fs : Eio.Fs.dir_ty Eio.Path.t; root_cap : Eio.Fs.dir_ty Eio.Path.t
  ; root_path : string; root : identity; controller_uid : int; payload_uid : int
  ; route : P.route; owner : P.owner; recovery : Fs_compat.Publication_recovery.registry }

type record = { registry : t; claim : claim; spec : P.spec }
type storage = { record : record; directory : Eio.Fs.dir_ty Eio.Path.t }
type unlaunched = { original_storage : storage }
let storage_record (storage : storage) = storage.record
let storage_path (storage : storage) = storage.directory
let unlaunched_storage proof = proof.original_storage
type launch_use = Unused | Callback_reserved | Retired_without_callback
type launch_intent = { original : record; launch_id : P.Id.t; use : launch_use Atomic.t }
let launch_record (intent : launch_intent) = intent.original
type launch_state = Not_requested | Requested of P.Id.t
let binding record = record.claim.binding
let specification record = record.spec
let admission_id record = record.claim.admission_id
let revision record = record.claim.revision
let payload_uid record = record.claim.payload_uid
let launch_state record = match record.claim.state with
  | Preparing | Ready _ -> Not_requested
  | Launch_requested {launch_id;_} | Cancel_requested {launch_id=Some launch_id;_} -> Requested launch_id
  | Cancel_requested {launch_id=None;_} -> Not_requested

type cancellation_state = No_cancellation | Cancellation_requested
let cancellation_state record = match record.claim.state with
  | Preparing | Ready _ | Launch_requested _ -> No_cancellation
  | Cancel_requested _ -> Cancellation_requested

type launch_target =
  { binding : P.binding; spec : P.spec; admission_id : P.Id.t; launch_id : P.Id.t; payload_uid : int
  ; original_record : record }
type 'a launch_outcome =
  | Not_performed of error
  | Performed of { value : 'a; release_error : File_lock_eio.durable_lock_error option }

let io f =
  try Ok (f ()) with
  | Unix.Unix_error (error,operation,_) -> Error (Authority_unavailable (operation ^ ": " ^ Unix.error_message error))
  | Sys_error _ -> Error (Authority_unavailable "system I/O failed")
  | Eio.Io _ -> Error (Authority_unavailable "filesystem I/O failed")

let blocking f = Eio_guard.run_in_systhread ~label:"endpoint-registry-authority" (fun () -> io f)
let cpu f = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ f
let identity_of_stat (s : Eio.File.Stat.t) = {device=s.dev;inode=s.ino}
let unix_identity (s : Unix.stats) = {device=Int64.of_int s.st_dev;inode=Int64.of_int s.st_ino}
let check_policy ~controller_uid ~payload_uid =
  if payload_uid<0 then Error (Protection_refused Invalid_payload_uid)
  else if payload_uid=0 then Error (Protection_refused Payload_is_root)
  else if payload_uid=controller_uid then Error (Protection_refused Payload_is_controller)
  else Ok ()
let inspect_root path ~controller_uid =
  let root=Unix.lstat path in
  if root.st_kind<>Unix.S_DIR || root.st_perm land 0o7777<>0o700 then Error (Protection_refused Root_not_private)
  else if root.st_uid<>controller_uid then Error (Protection_refused Root_owner_mismatch)
  else
    let rec parents path =
      let s=Unix.lstat path in
      if s.st_kind<>Unix.S_DIR || (s.st_uid<>0 && s.st_uid<>controller_uid)
         || (s.st_perm land 0o022<>0 && s.st_perm land 0o1000=0)
      then Error (Protection_refused Unsafe_ancestor)
      else let parent=Filename.dirname path in if parent=path then Ok () else parents parent in
    let* () = parents (Filename.dirname path) in Ok (unix_identity root)

let validate_root (registry : t) =
  Eio.Switch.check registry.sw;
  let* result=blocking (fun () -> inspect_root registry.root_path ~controller_uid:registry.controller_uid) in
  let* identity=result in
  if identity=registry.root then Ok () else Error (Protection_refused Root_identity_changed)

let open_registry ~sw ~fs ~root_path ~route ~owner ~payload_uid =
  Eio.Switch.check sw;
  let controller_uid=Unix.geteuid () in
  let* ()=if root_path<>"" && not (Filename.is_relative root_path) && not (String.contains root_path '\000')
    then Ok () else Error (Protection_refused Invalid_root_path) in
  let* ()=check_policy ~controller_uid ~payload_uid in
  let* ()=if owner.P.keeper_name<>"" && not (String.contains owner.keeper_name '\000') then Ok ()
    else Error (Protection_refused Invalid_owner) in
  let* path=blocking (fun () ->
    let original=Unix.lstat root_path in
    if original.st_kind<>Unix.S_DIR then Error (Protection_refused Root_not_private)
    else let path=Unix.realpath root_path in
      let* identity=inspect_root path ~controller_uid in Ok (path,identity)) in
  let* root_path,expected=path in
  let* root_cap=io (fun () -> (Eio.Path.open_dir ~sw Eio.Path.(fs / root_path) :> Eio.Fs.dir_ty Eio.Path.t)) in
  let* actual=io (fun () -> identity_of_stat (Eio.Path.stat ~follow:true root_cap)) in
  let* ()=if actual=expected then Ok () else Error (Protection_refused Root_identity_changed) in
  let* recovery=Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root:root_cap
    |> Result.map_error (fun error -> Recovery_unavailable (Fs_compat.Publication_recovery.registry_error_to_string error)) in
  let registry={sw;fs;root_cap;root_path;root=actual;controller_uid;payload_uid;route;owner;recovery} in
  let* ()=validate_root registry in Ok registry

let root_binding (registry : t) (binding : P.binding) =
  if binding.owner<>registry.owner || binding.route.backend<>registry.route.backend
     || binding.route.endpoint_incarnation<>registry.route.endpoint_incarnation then Error Binding_mismatch
  else Ok ()
let effect_binding (registry : t) (binding : P.binding) =
  let* ()=root_binding registry binding in
  if binding.P.route.boot_id=registry.route.boot_id then Ok () else Error Endpoint_replaced
let base_leaf binding = P.Id.to_string binding.P.operation_id
let claim_leaf binding = base_leaf binding ^ ".claim.json"
let job_leaf binding = base_leaf binding ^ ".job"
let job_path registry binding = Filename.concat registry.root_path (job_leaf binding)
let lock_path registry binding = Filename.concat (job_path registry binding) "lease"

let corrupt field = Error (Corrupt_original field)
let fields required = function
  | `Assoc values when List.sort String.compare (List.map fst values)=List.sort String.compare required -> Ok values
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> corrupt "invalid fields"
let member values key = List.assoc key values
let number field = function
  | `String value -> (match Int64.of_string_opt value with
      | Some n when n>=0L && Int64.to_string n=value -> Ok n | None | Some _ -> corrupt field)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> corrupt field
let uid field value = let* n=number field value in
  if n<=Int64.of_int max_int then Ok (Int64.to_int n) else corrupt field
let identifier field = function
  | `String value -> P.Id.of_string value |> Result.map_error (fun _ -> Corrupt_original field)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> corrupt field
let parse content = cpu (fun () -> try Ok (Yojson.Safe.from_string content)
  with Yojson.Json_error _ -> corrupt "invalid JSON")
let count n = `String (Int64.to_string n)

let claim_json (claim : claim) =
  let* original=P.request_to_json (P.Reconcile_admission claim.binding) |> Result.map_error (fun e -> Invalid_request e) in
  let state,job,launch_id=match claim.state with
    | Preparing -> "preparing",None,None | Ready job -> "ready",Some job,None
    | Launch_requested {job;launch_id} -> "launch_requested",Some job,Some launch_id
    | Cancel_requested {job;launch_id} -> "cancel_requested",Some job,launch_id in
  let coordinate f=match job with None -> `Null | Some job -> count (f job) in
  Ok (`Assoc ["version",`Int 2;"original",original;"admission_id",`String (P.Id.to_string claim.admission_id);
    "controller_uid",count (Int64.of_int claim.controller_uid);"payload_uid",count (Int64.of_int claim.payload_uid);
    "root_device",count claim.root.device;"root_inode",count claim.root.inode;
    "revision",count claim.revision;"state",`String state;
    "job_device",coordinate (fun job -> job.device);"job_inode",coordinate (fun job -> job.inode);
    "launch_id",(match launch_id with None -> `Null | Some id -> `String (P.Id.to_string id))])

let claim_of_json value =
  let* f=fields ["version";"original";"admission_id";"controller_uid";"payload_uid";
    "root_device";"root_inode";"revision";"state";"job_device";"job_inode";"launch_id"] value in
  let* ()=match member f "version" with
    | `Int 2 -> Ok ()
    | `Int actual -> Error (Unsupported_version {expected=2;actual})
    | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> corrupt "claim version" in
  let* original=P.request_of_json (member f "original") |> Result.map_error (fun _ -> Corrupt_original "original binding") in
  let* binding=match original with P.Reconcile_admission b -> Ok b
    | P.Start _ | P.Activate _ | P.Inspect _ | P.Read_output _ | P.Cancel _ | P.Release _ -> corrupt "original binding kind" in
  let* admission_id=identifier "admission ID" (member f "admission_id") in
  let* controller_uid=uid "controller UID" (member f "controller_uid") in
  let* payload_uid=uid "payload UID" (member f "payload_uid") in
  let* device=number "root device" (member f "root_device") in
  let* inode=number "root inode" (member f "root_inode") in
  let* revision=number "revision" (member f "revision") in
  let* state=match member f "state" with
    | `String "preparing" when revision=0L && member f "job_device"=`Null
        && member f "job_inode"=`Null && member f "launch_id"=`Null -> Ok Preparing
    | `String "ready" when revision=1L && member f "launch_id"=`Null ->
      let* device=number "job device" (member f "job_device") in
      let* inode=number "job inode" (member f "job_inode") in Ok (Ready {device;inode})
    | `String "launch_requested" when revision=2L ->
      let* device=number "job device" (member f "job_device") in
      let* inode=number "job inode" (member f "job_inode") in
      let* launch_id=identifier "launch ID" (member f "launch_id") in Ok (Launch_requested {job={device;inode};launch_id})
    | `String "cancel_requested" ->
      let* device=number "job device" (member f "job_device") in
      let* inode=number "job inode" (member f "job_inode") in
      let* launch_id=match member f "launch_id" with
        | `Null when revision=2L -> Ok None
        | `String value when revision=3L -> identifier "launch ID" (`String value) |> Result.map Option.some
        | `Null | `String _ | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> corrupt "cancel launch/revision" in
      Ok (Cancel_requested {job={device;inode};launch_id})
    | `String _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> corrupt "claim state/revision" in
  Ok {binding;admission_id;controller_uid;payload_uid;root={device;inode};revision;state}

let read_private (registry : t) components =
  let* relative=Fs_compat.owned_relative_path components
    |> Result.map_error (fun _ -> Corrupt_original "private relative path") in
  let path=Filename.concat registry.root_path (Fs_compat.owned_relative_path_to_string relative) in
  let* value=Eio_guard.run_in_systhread ~label:"endpoint-registry-original-read" (fun () ->
    Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:registry.controller_uid ~single_link:true
      ~ownership_root:registry.root_path path)
    |> Result.map_error (fun e -> Authority_unavailable (Fs_compat.owned_regular_file_read_error_to_string e)) in
  match value with
  | None -> Ok None
  | Some value when value.snapshot.permissions land 0o7777=0o400 -> Ok (Some value.content)
  | Some _ -> corrupt "original file permissions"
let read_claim (registry : t) (binding : P.binding) =
  let* ()=validate_root registry in
  let* content=read_private registry [claim_leaf binding] in
  match content with
  | None -> let* ()=validate_root registry in Ok None
  | Some content ->
    let* json=parse content in let* claim=claim_of_json json in
    let* ()=if claim.binding=binding then Ok () else Error Binding_mismatch in
    let* ()=if claim.root=registry.root && claim.controller_uid=registry.controller_uid then Ok ()
      else Error (Protection_refused Root_identity_changed) in
    let* ()=validate_root registry in Ok (Some claim)

let inspect_job (registry : t) (binding : P.binding) =
  let* value=blocking (fun () ->
    try
      let stat=Unix.lstat (job_path registry binding) in
      if stat.st_kind<>Unix.S_DIR || stat.st_uid<>registry.controller_uid || stat.st_perm land 0o7777<>0o700
      then corrupt "job directory authority" else Ok (Some (unix_identity stat))
    with Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None) in value

let read_record (registry : t) (binding : P.binding) =
  let* ()=root_binding registry binding in
  let* claim=read_claim registry binding in
  let* claim=match claim with None -> Error Missing_original | Some claim -> Ok claim in
  let* expected=match claim.state with Preparing -> Error Admission_incomplete
    | Ready job | Launch_requested {job;_} | Cancel_requested {job;_} -> Ok job in
  let* observed=inspect_job registry binding in
  let* ()=if observed=Some expected then Ok () else Error Missing_original in
  let* admission=read_private registry [job_leaf binding;"admission_id"] in
  let* ()=if admission=Some (P.Id.to_string claim.admission_id) then Ok () else corrupt "job admission ID" in
  let* original=read_private registry [job_leaf binding;"original.json"] in
  let* original=match original with None -> Error Missing_original | Some content -> parse content in
  let* request=cpu (fun () -> P.request_of_json original) |> Result.map_error (fun _ -> Corrupt_original "original Start") in
  let* spec=match request with
    | P.Start {binding=original;spec} when original=binding -> Ok spec
    | P.Start _ | P.Reconcile_admission _ | P.Activate _ | P.Inspect _ | P.Read_output _ | P.Cancel _ | P.Release _ -> corrupt "original Start binding" in
  let* after=inspect_job registry binding in
  let* ()=if observed=after then validate_root registry else Error (Protection_refused Root_identity_changed) in
  Ok {registry;claim;spec}

let settle_lock = function
  | File_lock_eio.Lock_held_elsewhere -> Error Busy
  | Lock_attempted (Lock_not_acquired error) -> Error (Lock_failed error)
  | Lock_attempted (Body_completed {value;release_error=None}) -> value
  | Lock_attempted (Body_completed {value;release_error=Some cause}) ->
    let primary=match value with Ok _ -> None | Error error -> Some error in Error (Cleanup_failed {primary;cause})
let with_job_lock attempt (registry : t) (binding : P.binding) f =
  let* ()=root_binding registry binding in
  let* ()=validate_root registry in
  settle_lock (attempt ~lock_path:(lock_path registry binding) f)
let locked registry binding f =
  with_job_lock File_lock_eio.try_with_liveness_lock_observed registry binding f
let read_locked registry binding f =
  with_job_lock File_lock_eio.try_with_shared_liveness_lock_observed registry binding f
let load registry ~binding = read_locked registry binding (fun () -> read_record registry binding)

let in_recovery_lane recovery owner f =
  match Fs_compat.Publication_recovery.with_lane ~registry:recovery ~owner f with
  | Error error -> Error (Recovery_unavailable (Fs_compat.Publication_recovery.lane_open_error_to_string error))
  | Ok (Lane_released value) -> value
  | Ok (Lane_release_failed {value;release_failure}) ->
    let detail=Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure in
    Error (Commit_unconfirmed (match value with Ok _ -> detail | Error error -> error_to_string error ^ "; " ^ detail))
let with_recovery (registry : t) owner f = in_recovery_lane registry.recovery owner f
let target (registry : t) ~leaf ~permissions =
  Fs_compat.capability_publication_target ~allowed_root_path:registry.root_path
    ~allowed_root_device:registry.root.device ~allowed_root_inode:registry.root.inode
    ~parent_components:[] ~target_leaf:leaf ~permissions
  |> Result.map_error (fun e -> Authority_unavailable (Fs_compat.capability_publication_target_error_to_string e))
let publish_claim (registry : t) ~exclusive (claim : claim) =
  let* ()=validate_root registry in
  let* json=claim_json claim in let* target=target registry ~leaf:(claim_leaf claim.binding) ~permissions:0o400 in
  let result=with_recovery registry (base_leaf claim.binding) (fun recovery ->
    (if exclusive then Fs_compat.create_capability_file_exclusive else Fs_compat.replace_capability_file)
      ~recovery ~parent:registry.root_cap ~target (Yojson.Safe.to_string json)
    |> Result.map_error (fun e -> Publication_failed e)) in
  let* ()=result in validate_root registry

let already_exists ?(directory=false) = function
  | Publication_failed error ->
    let unchanged=match error.target_effect with
      | Fs_compat.Target_unchanged -> true
      | Target_created | Target_replaced | Target_state_unknown -> false in
    let conflict=match error.primary_failure with
      | Fs_compat.Recovery_primary_failure _ | Recovery_access_primary_failure _ -> false
      | Write_primary_failure failure -> match failure.cause with
        | Fs_compat.Target_already_exists -> true
        | Unexpected_resource_kind kind -> directory && kind=`Directory && failure.stage=Fs_compat.Inspect_target_entry
        | Invalid_recovery_target _ | Mutation_contended | Posix_descriptor_unavailable
        | Resource_identity_unavailable | Resource_identity_changed
        | Payload_write_failed _ | Operation_failed _ -> false in
    unchanged && conflict && error.cleanup_failures=[]
  | Protection_refused _ | Authority_unavailable _ | Recovery_unavailable _
  | Lock_failed _ | Commit_unconfirmed _ | Busy | Binding_mismatch | Invalid_request _
  | Execution_identity_changed | Endpoint_replaced | Missing_original | Admission_incomplete
  | Unsupported_version _ | Corrupt_original _ | Launch_already_requested | Launch_cancelled | Launch_intent_spent | Stale_record | Cleanup_failed _ -> false

let create_job (registry : t) (claim : claim) =
  let* ()=validate_root registry in
  let* payload=Fs_compat.directory_payload
    [{leaf="admission_id";content=P.Id.to_string claim.admission_id;permissions=0o400};
     {leaf="lease";content="";permissions=0o600}]
    |> Result.map_error (fun e -> Authority_unavailable (Fs_compat.directory_payload_error_to_string e)) in
  let* target=target registry ~leaf:(job_leaf claim.binding) ~permissions:0o700 in
  with_recovery registry (base_leaf claim.binding) (fun recovery ->
    Fs_compat.create_capability_directory_exclusive ~recovery ~parent:registry.root_cap ~target payload
    |> Result.map_error (fun e -> Publication_failed e))

let publish_original (registry : t) binding ~encoded =
  let* ()=validate_root registry in
  Eio.Path.with_open_dir Eio.Path.(registry.root_cap / job_leaf binding) (fun opened ->
    let parent=(opened :> Eio.Fs.dir_ty Eio.Path.t) in
    let* stat=io (fun () -> Eio.Path.stat ~follow:true parent) in
    let* target=Fs_compat.capability_publication_target
        ~allowed_root_path:(job_path registry binding) ~allowed_root_device:stat.dev ~allowed_root_inode:stat.ino
        ~parent_components:[] ~target_leaf:"original.json" ~permissions:0o400
      |> Result.map_error (fun e -> Authority_unavailable (Fs_compat.capability_publication_target_error_to_string e)) in
    Eio.Switch.run (fun sw ->
      let* recovery=Fs_compat.Publication_recovery.open_registry ~sw ~fs:registry.fs ~registry_root:parent
        |> Result.map_error (fun e -> Recovery_unavailable (Fs_compat.Publication_recovery.registry_error_to_string e)) in
      in_recovery_lane recovery "original" (fun recovery ->
        let* existing=read_private registry [job_leaf binding;"original.json"] in
        match existing with
        | Some original -> if original=encoded then Ok () else corrupt "preparing original bytes"
        | None -> Fs_compat.create_capability_file_exclusive ~recovery ~parent ~target encoded
            |> Result.map_error (fun e -> Publication_failed e))))

let sync_original registry binding =
  let* relative=Fs_compat.owned_relative_path [job_leaf binding;"original.json"]
    |> Result.map_error (fun _ -> Corrupt_original "original relative path") in
  let* result=blocking (fun () -> Fs_compat.with_owned_inventory_root registry.root_path (fun root ->
    Fs_compat.with_owned_inventory_regular_file ~owner_uid:registry.controller_uid root relative
      (fun ~file ~parent ~stat:_ -> Unix.fsync file;Unix.fsync parent))) in
  result |> Result.map_error (fun e -> Authority_unavailable (Fs_compat.owned_regular_file_read_error_to_string e))

let admit_with_hooks ~after_claim ~after_missing_job ~after_job ~after_original (registry : t) ~new_admission_id ~(binding : P.binding) ~(spec : P.spec) =
  let* ()=effect_binding registry binding in
  let* encoded=cpu (fun () -> P.request_to_json (P.Start {binding;spec})
      |> Result.map Yojson.Safe.to_string) |> Result.map_error (fun e -> Invalid_request e) in
  let* existing=read_claim registry binding in
  let* claim=match existing with
    | Some claim -> Ok claim
    | None ->
      let* job=inspect_job registry binding in
      let* ()=match job with None -> Ok () | Some _ -> Error Missing_original in
      let candidate={binding;admission_id=new_admission_id;controller_uid=registry.controller_uid;
        payload_uid=registry.payload_uid;root=registry.root;revision=0L;state=Preparing} in
      (match publish_claim registry ~exclusive:true candidate with
       | Ok () -> Ok candidate
       | Error error when already_exists error ->
         let* existing=read_claim registry binding in
         (match existing with None -> Error Missing_original | Some claim -> Ok claim)
       | Error error -> Error error) in
  let* ()=if claim.payload_uid=registry.payload_uid then Ok () else Error Execution_identity_changed in
  after_claim ();
  match claim.state with
  | Ready _ | Launch_requested _ | Cancel_requested _ -> load registry ~binding
  | Preparing ->
    let* existing_job=inspect_job registry binding in
    let* ()=match existing_job with
      | Some _ -> Ok ()
      | None -> after_missing_job ();match create_job registry claim with
        | Ok () -> Ok ()
        | Error error when already_exists ~directory:true error ->
          let* current_job=inspect_job registry binding in
          (match current_job with Some _ -> Ok () | None -> Error error)
        | Error error -> Error error in
    after_job ();
    locked registry binding (fun () ->
      let* current=read_claim registry binding in
      let* current=match current with None -> Error Missing_original | Some c -> Ok c in
      match current.state with
      | Ready _ | Launch_requested _ | Cancel_requested _ -> read_record registry binding
      | Preparing ->
        let* job=inspect_job registry binding in
        let* job=match job with None -> Error Missing_original | Some id -> Ok id in
        let ready={current with revision=1L;state=Ready job} in
        let* admission=read_private registry [job_leaf binding;"admission_id"] in
        let* ()=if admission=Some (P.Id.to_string current.admission_id) then Ok () else corrupt "preparing admission ID" in
        let* ()=publish_original registry binding ~encoded in
        let* ()=sync_original registry binding in
        after_original ();
        (* Verify complete original bytes before promoting the separate claim. *)
        let* admission=read_private registry [job_leaf binding;"admission_id"] in
        let* original=read_private registry [job_leaf binding;"original.json"] in
        let* ()=if admission=Some (P.Id.to_string current.admission_id)
           && original=Some encoded then Ok () else corrupt "preparing original bytes" in
        let* ()=publish_claim registry ~exclusive:false ready in
        read_record registry binding)

let same_execution_progress previous current =
  match previous with
  | Preparing -> (match current with
      | Preparing -> true
      | Ready _ | Launch_requested _ | Cancel_requested _ -> false)
  | Ready job -> (match current with
      | Preparing -> false
      | Ready next | Launch_requested {job=next;_} | Cancel_requested {job=next;_} -> job=next)
  | Launch_requested {job;launch_id} -> (match current with
      | Launch_requested {job=next;launch_id=next_id}
      | Cancel_requested {job=next;launch_id=Some next_id} -> job=next && launch_id=next_id
      | Preparing | Ready _ | Cancel_requested {launch_id=None;_} -> false)
  | Cancel_requested {job;launch_id} -> (match current with
      | Cancel_requested {job=next;launch_id=next_id} -> job=next && launch_id=next_id
      | Preparing | Ready _ | Launch_requested _ -> false)

let same_original (original : record) (current : record) =
  {original.claim with revision=current.claim.revision;state=current.claim.state}=current.claim
  && same_execution_progress original.claim.state current.claim.state
  && original.spec=current.spec

let refresh_with_hook ~after_lock (original : record) =
  let registry=original.registry and binding=original.claim.binding in
  read_locked registry binding (fun () ->
    after_lock ();
    let* current=read_record registry binding in
    if same_original original current then Ok current else Error Stale_record)
let refresh original = refresh_with_hook ~after_lock:(fun () -> ()) original

let resync_cancel ~before_parent_sync (current : record) =
  let registry=current.registry and binding=current.claim.binding in
  let* relative=Fs_compat.owned_relative_path [claim_leaf binding]
    |> Result.map_error (fun _ -> Corrupt_original "claim relative path") in
  let* result=blocking (fun () -> Fs_compat.with_owned_inventory_root registry.root_path (fun root ->
    Fs_compat.with_owned_inventory_regular_file ~owner_uid:registry.controller_uid root relative
      (fun ~file ~parent ~stat:_ -> Unix.fsync file;before_parent_sync ();Unix.fsync parent))) in
  let* ()=result |> Result.map_error (fun e ->
    Authority_unavailable (Fs_compat.owned_regular_file_read_error_to_string e)) in
  let* confirmed=read_record registry binding in
  if confirmed.claim=current.claim && confirmed.spec=current.spec then Ok confirmed else Error Stale_record

let request_cancel_with_hook ~before_resync_parent ~after_publication (original : record) ~confirmed_admission_id =
  let registry=original.registry and binding=original.claim.binding in
  let* ()=effect_binding registry binding in
  locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if original.claim.admission_id=confirmed_admission_id
       && current.claim.admission_id=confirmed_admission_id then Ok () else Error Binding_mismatch in
    let* ()=if current.claim.payload_uid=registry.payload_uid
       && current.claim.payload_uid=original.claim.payload_uid then Ok () else Error Execution_identity_changed in
    let* ()=if same_original original current then Ok () else Error Stale_record in
    let publish job launch_id =
      let claim={current.claim with revision=Int64.succ current.claim.revision;
        state=Cancel_requested {job;launch_id}} in
      let* ()=publish_claim registry ~exclusive:false claim in
      after_publication ();
      let* committed=read_record registry binding in
      if committed.claim=claim && committed.spec=current.spec then Ok committed else Error Stale_record in
    match current.claim.state with
    | Preparing -> Error Admission_incomplete
    | Cancel_requested _ -> resync_cancel ~before_parent_sync:before_resync_parent current
    | Ready job -> publish job None
    | Launch_requested {job;launch_id} -> publish job (Some launch_id))

let commit_launch_with_hook ~after_publication (original : record) ~confirmed_admission_id ~launch_id =
  let registry=original.registry and binding=original.claim.binding in
  let* ()=effect_binding registry binding in
  locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if current.claim.admission_id=confirmed_admission_id then Ok () else Error Binding_mismatch in
    let* ()=if current.claim.payload_uid=registry.payload_uid then Ok () else Error Execution_identity_changed in
    match current.claim.state with
    | Launch_requested _ -> Error Launch_already_requested
    | Cancel_requested _ -> Error Launch_cancelled
    | Preparing -> Error Admission_incomplete
    | Ready job ->
      let* ()=if original.claim=current.claim && original.spec=current.spec then Ok () else Error Stale_record in
      let claim={current.claim with revision=2L;state=Launch_requested {job;launch_id}} in
      let* ()=publish_claim registry ~exclusive:false claim in
      after_publication ();
      let* committed=read_record registry binding in
      let* ()=if committed.claim=claim then Ok () else Error Stale_record in
      Ok {original=committed;launch_id;use=Atomic.make Unused})

let original_storage ~sw (current : record) =
  Eio.Switch.check sw;
  let registry=current.registry and binding=current.claim.binding in
  let* expected=match current.claim.state with
    | Ready job | Launch_requested {job;_} | Cancel_requested {job;_} -> Ok job
    | Preparing -> Error Admission_incomplete in
  let* storage=io (fun () ->
    (Eio.Path.open_dir ~sw Eio.Path.(registry.root_cap / job_leaf binding)
      :> Eio.Fs.dir_ty Eio.Path.t)) in
  let* stat=io (fun () -> Eio.Path.stat ~follow:true storage) in
  let* ()=if stat.kind=`Directory && stat.uid=Int64.of_int registry.controller_uid
      && stat.perm land 0o7777=0o700 && identity_of_stat stat=expected
    then Ok () else corrupt "original storage authority" in
  let* after=inspect_job registry binding in
  let* ()=if after=Some expected then validate_root registry else Error Stale_record in
  Eio.Switch.check sw;
  Ok storage

let open_storage ~sw (original : record) =
  Eio.Switch.check sw;
  let registry=original.registry and binding=original.claim.binding in
  read_locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if same_original original current then Ok () else Error Stale_record in
    let* directory=original_storage ~sw current in
    Ok {record=current;directory})

let unlaunched ~sw current =
  let* directory=original_storage ~sw current in
  Ok {original_storage={record=current;directory}}

let settle_cancelled_admission_with_hook ~before_resync_parent ~sw (original : record) =
  Eio.Switch.check sw;
  let registry=original.registry and binding=original.claim.binding in
  locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if same_original original current then Ok () else Error Stale_record in
    match current.claim.state with
    | Cancel_requested {launch_id=None;_} ->
      let* current=resync_cancel ~before_parent_sync:before_resync_parent current in
      unlaunched ~sw current
    | Cancel_requested {launch_id=Some _;_} | Launch_requested _ -> Error Launch_already_requested
    | Preparing | Ready _ -> Error Stale_record)

let settle_cancelled_admission ~sw original =
  settle_cancelled_admission_with_hook ~before_resync_parent:(fun () -> ()) ~sw original

let retire_cancelled_launch_with_hook ~before_resync_parent ~after_retirement ~sw (intent : launch_intent) =
  Eio.Switch.check sw;
  let original=intent.original in
  let registry=original.registry and binding=original.claim.binding in
  locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if same_original original current then Ok () else Error Stale_record in
    let* ()=match current.claim.state with
      | Cancel_requested {launch_id;_} -> (match launch_id with
          | Some actual when actual=intent.launch_id -> Ok ()
          | None | Some _ -> Error Stale_record)
      | Preparing | Ready _ | Launch_requested _ -> Error Stale_record in
    let* ()=match Atomic.get intent.use with
      | Callback_reserved -> Error Launch_intent_spent
      | Unused | Retired_without_callback -> Ok () in
    let* current=resync_cancel ~before_parent_sync:before_resync_parent current in
    let* ()=match Atomic.get intent.use with
      | Callback_reserved -> Error Launch_intent_spent
      | Retired_without_callback -> Ok ()
      | Unused ->
        if Atomic.compare_and_set intent.use Unused Retired_without_callback then Ok ()
        else Error Launch_intent_spent in
    after_retirement ();
    (* Retirement survives a cancelled or failed storage open. It can only
       reopen this cancelled original; callback entry never becomes fresh. *)
    unlaunched ~sw current)

let retire_cancelled_launch ~sw intent =
  retire_cancelled_launch_with_hook ~before_resync_parent:(fun () -> ()) ~after_retirement:(fun () -> ()) ~sw intent

let verify_unlaunched_evidence ~sw ~parent ~leaf ~permissions ~controller_uid content =
  let* opened=io (fun () -> Fs_compat.open_owned_reader ~sw ~parent ~leaf) in
  let* reader=opened |> Result.map_error (fun e -> Authority_unavailable
    (Fs_compat.owned_regular_file_read_error_to_string e)) in
  let* initial=io (fun () -> Fs_compat.owned_reader_stat reader) in
  let private_file (stat : Eio.File.Stat.t) =
    stat.kind=`Regular_file && stat.nlink=1L && stat.uid=Int64.of_int controller_uid
    && stat.perm land 0o7777=permissions
    && Optint.Int63.to_int64 stat.size=Int64.of_int (String.length content) in
  let* ()=if private_file initial then Ok () else corrupt "unlaunched evidence attachment" in
  let validate () =
    let* held=io (fun () -> Fs_compat.owned_reader_stat reader) in
    let* named=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(parent / leaf)) in
    let stable (stat : Eio.File.Stat.t)={initial with atime=stat.atime}=stat in
    if private_file held && private_file named && stable held && stable named
      then Ok () else corrupt "unlaunched evidence changed" in
  let* ()=validate () in
  let buffer=Buffer.create (min 65536 (String.length content)) in
  let rec read offset =
    if offset=String.length content then Ok (Buffer.contents buffer) else
    let* bytes=io (fun () -> Fs_compat.owned_reader_pread reader ~offset:(Int64.of_int offset)
      ~length:(min 65536 (String.length content-offset))) in
    let n=String.length bytes in
    if n=0 then corrupt "unlaunched evidence truncated"
    else (Buffer.add_string buffer bytes;read (offset+n)) in
  let* actual=read 0 in
  let* ()=if actual=content then Ok () else corrupt "unlaunched evidence conflict" in
  let* synced=io (fun () -> Fs_compat.sync_owned_reader ~parent ~leaf reader) in
  let* ()=synced |> Result.map_error (fun e -> Authority_unavailable
    (Fs_compat.owned_regular_file_read_error_to_string e)) in
  validate ()

type evidence = Stream_data of P.stream | Stream_seal of P.stream | Terminal_receipt
let evidence_leaf = function
  | Stream_data P.Stdout -> "stdout.bin" | Stream_data P.Stderr -> "stderr.bin"
  | Stream_seal P.Stdout -> "stdout.seal.json" | Stream_seal P.Stderr -> "stderr.seal.json"
  | Terminal_receipt -> "terminal-result.json"
let evidence_permissions = function Stream_data _ -> 0o600 | Stream_seal _ | Terminal_receipt -> 0o400
let evidence_present parent evidence =
  let* kind=io (fun () -> Eio.Path.kind ~follow:false Eio.Path.(parent / evidence_leaf evidence)) in
  match kind with
  | `Regular_file -> Ok true | `Not_found -> Ok false
  | `Unknown | `Fifo | `Character_special | `Directory | `Block_device | `Symbolic_link | `Socket ->
    corrupt "unlaunched evidence kind"
let check_evidence_creation parent evidence =
  let* present=evidence_present parent evidence in
  if present then Ok () else
  let* terminal=evidence_present parent Terminal_receipt in
  let rec require = function
    | [] -> Ok ()
    | evidence::rest -> let* present=evidence_present parent evidence in
      if present then require rest else corrupt "unlaunched evidence dependency missing" in
  match evidence with
  | Stream_data stream ->
    let* sealed=evidence_present parent (Stream_seal stream) in
    if terminal || sealed then corrupt "sealed original stream missing" else Ok ()
  | Stream_seal stream ->
    if terminal then corrupt "terminal original seal missing" else require [Stream_data stream]
  | Terminal_receipt -> require [Stream_data P.Stdout;Stream_seal P.Stdout;Stream_data P.Stderr;Stream_seal P.Stderr]
let publish_unlaunched ~sw proof ~evidence ~content =
  Eio.Switch.check sw;
  let original=proof.original_storage.record in
  let registry=original.registry and binding=original.claim.binding in
  let leaf=evidence_leaf evidence and permissions=evidence_permissions evidence in
  let* ()=match evidence with
    | Stream_data _ -> if String.length content=0 then Ok () else corrupt "unlaunched stream is not empty"
    | Stream_seal _ | Terminal_receipt -> Ok () in
  let result=locked registry binding (fun () ->
    let* current=read_record registry binding in
    let* ()=if same_original original current then Ok () else Error Stale_record in
    let* ()=match current.claim.state with
      | Cancel_requested _ -> Ok ()
      | Preparing | Ready _ | Launch_requested _ -> Error Stale_record in
    let* current=resync_cancel ~before_parent_sync:(fun () -> ()) current in
    Eio.Switch.run (fun read_sw ->
      let* parent=original_storage ~sw:read_sw current in
      let* ()=check_evidence_creation parent evidence in
      let* root=io (fun () -> Eio.Path.stat ~follow:true parent) in
      let* target=Fs_compat.capability_publication_target
          ~allowed_root_path:(job_path registry binding) ~allowed_root_device:root.dev ~allowed_root_inode:root.ino
          ~parent_components:[] ~target_leaf:leaf ~permissions
        |> Result.map_error (fun e -> Authority_unavailable
          (Fs_compat.capability_publication_target_error_to_string e)) in
      let* ()=Eio.Cancel.protect (fun () ->
        let* recovery=Fs_compat.Publication_recovery.open_registry ~sw:read_sw ~fs:registry.fs ~registry_root:parent
          |> Result.map_error (fun e -> Recovery_unavailable (Fs_compat.Publication_recovery.registry_error_to_string e)) in
        in_recovery_lane recovery "unlaunched" (fun recovery ->
          match Fs_compat.create_capability_file_exclusive ~recovery ~parent ~target content
              |> Result.map_error (fun e -> Publication_failed e) with
          | Ok () -> Ok ()
          | Error e when already_exists e -> Ok ()
          | Error e -> Error e)) in
      let* ()=verify_unlaunched_evidence ~sw:read_sw ~parent ~leaf ~permissions ~controller_uid:registry.controller_uid content in
      let* confirmed=read_record registry binding in
      if same_original current confirmed then Ok () else Error Stale_record)) in
  Eio.Fiber.check ();
  result

let with_launch_with_hook ~after_original ~sw (intent : launch_intent) perform =
  Eio.Switch.check sw;
  let original=intent.original in let registry=original.registry and binding=original.claim.binding in
  let validation=let* ()=effect_binding registry binding in validate_root registry in
  match validation with
  | Error error -> Not_performed error
  | Ok () ->
    let attempt=File_lock_eio.try_with_liveness_lock_observed ~lock_path:(lock_path registry binding) (fun () ->
      let* current=read_record registry binding in
      let* ()=if same_original original current then Ok () else Error Stale_record in
      let* ()=match current.claim.state with
        | Cancel_requested _ -> Error Launch_cancelled
        | Preparing | Ready _ | Launch_requested _ -> Ok () in
      let* ()=if current.claim=original.claim then Ok () else Error Stale_record in
      let* ()=if current.claim.payload_uid=registry.payload_uid then Ok () else Error Execution_identity_changed in
      if not (Atomic.compare_and_set intent.use Unused Callback_reserved) then Error Launch_intent_spent
      else (
        after_original ();
        let* storage=original_storage ~sw current in
        Ok (perform {binding;spec=current.spec;admission_id=current.claim.admission_id;
          launch_id=intent.launch_id;payload_uid=current.claim.payload_uid;original_record=current} ~storage))) in
    match attempt with
    | File_lock_eio.Lock_held_elsewhere -> Not_performed Busy
    | Lock_attempted (Lock_not_acquired error) -> Not_performed (Lock_failed error)
    | Lock_attempted (Body_completed {value=Ok value;release_error}) -> Performed {value;release_error}
    | Lock_attempted (Body_completed {value=Error error;release_error=None}) -> Not_performed error
    | Lock_attempted (Body_completed {value=Error error;release_error=Some cause}) ->
      Not_performed (Cleanup_failed {primary=Some error;cause})

let admit registry ~new_admission_id ~binding ~spec =
  admit_with_hooks ~after_claim:(fun () -> ()) ~after_missing_job:(fun () -> ())
    ~after_job:(fun () -> ()) ~after_original:(fun () -> ())
    registry ~new_admission_id ~binding ~spec
let request_cancel original ~confirmed_admission_id =
  request_cancel_with_hook ~before_resync_parent:(fun () -> ()) ~after_publication:(fun () -> ())
    original ~confirmed_admission_id
let commit_launch original ~confirmed_admission_id ~launch_id =
  commit_launch_with_hook ~after_publication:(fun () -> ())
    original ~confirmed_admission_id ~launch_id
let with_launch ~sw intent perform =
  with_launch_with_hook ~after_original:(fun () -> ()) ~sw intent perform
module For_testing = struct
  let settle_cancelled_admission ?(before_resync_parent=fun () -> ()) ~sw original =
    settle_cancelled_admission_with_hook ~before_resync_parent ~sw original
  let retire_cancelled_launch ?(before_resync_parent=fun () -> ()) ~after_retirement ~sw intent =
    retire_cancelled_launch_with_hook ~before_resync_parent ~after_retirement ~sw intent
  let refresh = refresh_with_hook
  let with_launch = with_launch_with_hook
  let admit = admit_with_hooks
  let commit_launch = commit_launch_with_hook
  let request_cancel ?(before_resync_parent=fun () -> ()) ~after_publication original ~confirmed_admission_id =
    request_cancel_with_hook ~before_resync_parent ~after_publication original ~confirmed_admission_id
end
