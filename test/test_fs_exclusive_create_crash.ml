open Alcotest

module Writer = Fs_compat_test_support.Capability_write_for_testing
module Core = Fs_compat_internal.Capability_recovery_obligation
module Reconciler = Fs_compat_internal.Capability_recovery_reconciler

type cut = Prepared | Bound | Payload_opened | Payload_written | Published | Parent_synced

let cuts = [Prepared; Bound; Payload_opened; Payload_written; Published; Parent_synced]
let cut_name = function
  | Prepared -> "prepared"
  | Bound -> "bound"
  | Payload_opened -> "payload-opened"
  | Payload_written -> "payload-written"
  | Published -> "published"
  | Parent_synced -> "parent-synced"
let cut_stage = function
  | Prepared -> Fs_compat.Create_staging_directory
  | Bound -> Fs_compat.Create_staging_entry
  | Payload_opened -> Fs_compat.Write_payload
  | Payload_written -> Fs_compat.Sync_payload
  | Published -> Fs_compat.Sync_staging_directory
  | Parent_synced -> Fs_compat.Discharge_bound_recovery_obligation

let payload = String.make 65536 'x'
let owner_name = "exclusive-create-crash"

let create ~before_stage ~recovery ~target ~parent content =
  Writer.create_capability_file_exclusive ~before_stage ~recovery ~target ~parent content

let with_writer ~fs directory f =
  Eio.Switch.run @@ fun sw ->
  let root = Filename.concat directory "root" in
  let registry_path = Filename.concat directory "registry" in
  let recovery = match Fs_compat.Publication_recovery.open_registry ~sw ~fs
      ~registry_root:Eio.Path.(fs / registry_path) with
    | Ok value -> value
    | Error error -> fail (Fs_compat.Publication_recovery.registry_error_to_string error) in
  Eio.Path.with_open_dir Eio.Path.(fs / root) @@ fun parent ->
  let stat = Eio.Path.stat ~follow:true parent in
  let target = match Fs_compat.capability_publication_target
      ~allowed_root_path:root ~allowed_root_device:stat.dev ~allowed_root_inode:stat.ino
      ~parent_components:[] ~target_leaf:"result" ~permissions:0o600 with
    | Ok value -> value
    | Error error -> fail (Fs_compat.capability_publication_target_error_to_string error) in
  match Fs_compat.Publication_recovery.with_lane ~registry:recovery ~owner:owner_name
          (fun recovery -> f ~recovery ~target ~parent) with
  | Ok (Fs_compat.Publication_recovery.Lane_released value) -> value
  | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) -> fail "writer lane release failed"
  | Error error -> fail (Fs_compat.Publication_recovery.lane_open_error_to_string error)

let child cut directory =
  Eio_main.run @@ fun env ->
  with_writer ~fs:(Eio.Stdenv.fs env) directory @@ fun ~recovery ~target ~parent ->
  let before_stage stage =
    if stage = cut_stage cut then (
      output_char stdout '!'; flush stdout;
      (* Parent owns this pipe handshake and sends SIGKILL, so no unwind runs. *)
      let one = Bytes.create 1 in
      ignore (Unix.read Unix.stdin one 0 1);
      fail "parent did not kill the producer at its acknowledged boundary")
  in
  match create ~before_stage ~recovery ~target ~parent payload with
  | Ok () -> ()
  | Error error -> fail (Fs_compat.capability_write_error_to_string error)

let with_directory f =
  let path = Filename.temp_file "masc-exclusive-crash-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () ->
    Unix.mkdir (Filename.concat path "root") 0o700;
    Unix.mkdir (Filename.concat path "registry") 0o700;
    f (Unix.realpath path))

let kill_at cut directory =
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let hold_read, hold_write = Unix.pipe ~cloexec:true () in
  let pid = Unix.create_process Sys.executable_name
      [|Sys.executable_name; "--crash-child"; cut_name cut; directory|]
      hold_read ready_write Unix.stderr in
  Unix.close ready_write;
  Unix.close hold_read;
  let reaped = ref false in
  Fun.protect
    ~finally:(fun () ->
      Unix.close ready_read; Unix.close hold_write;
      if not !reaped then (
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        ignore (Unix.waitpid [] pid)))
    (fun () ->
       let byte = Bytes.create 1 in
       check int "child reached requested real write boundary" 1
         (Unix.read ready_read byte 0 1);
       check char "boundary acknowledgement" '!' (Bytes.get byte 0);
       Unix.kill pid Sys.sigkill;
       let _, status = Unix.waitpid [] pid in
       reaped := true;
       check bool "producer actually died by SIGKILL" true (status = Unix.WSIGNALED Sys.sigkill))

let test_crash cut () = with_directory @@ fun directory ->
  kill_at cut directory;
  let target_path = Filename.concat directory "root/result" in
  (match cut with
   | Prepared | Bound | Payload_opened | Payload_written ->
     check bool "public leaf absent before publication" false (Sys.file_exists target_path)
   | Published | Parent_synced ->
     check string "public payload is complete after publication" payload (Fs_compat.load_file target_path));
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let valid = function
    | Ok value -> value
    | Error error -> fail (Core.validation_error_to_string error) in
  let transitioned = function
    | Ok value -> value
    | Error error -> fail (Core.transition_error_to_string error) in
  let registry = transitioned (Core.open_registry ~sw
      ~registry_root:Eio.Path.(Eio.Stdenv.fs env / Filename.concat directory "registry")) in
  let owner = valid (Core.owner_of_string owner_name) in
  let inventory () =
    match Core.with_existing_store ~registry ~owner (fun store -> transitioned (Core.inventory store)) with
    | Ok (Core.Existing_store_scope_released rows) -> rows
    | Ok (Core.Existing_store_scope_release_failed _) -> fail "reader release failed"
    | Ok (Core.Existing_store_scope_cancelled _) -> fail "reader cancelled"
    | Error error -> fail (Core.transition_error_to_string error) in
  let prepared = match cut, inventory () with
    | Prepared, [Core.Active_record prepared] -> prepared
    | (Bound | Payload_opened | Payload_written | Published | Parent_synced), [Core.Owned_record bound] ->
      Core.bound_prepared bound
    | _ -> fail "crash has no exact durable operation at the required phase" in
  check bool "original exclusive-create intent survived producer death" true
    (Core.prepared_publication prepared = Core.Create_exclusive);
  let operation_id = Core.operation_id_to_string (Core.prepared_operation_id prepared) in
  let report = Reconciler.reconcile_owner ~fs:(Eio.Stdenv.fs env) ~registry ~owner in
  check bool "startup reconciliation recorded an explicit forensic outcome" true
    (Reconciler.report_is_ready report);
  (match inventory () with
   | [Core.Forensic_record forensic] ->
     check string "same operation identity after reconciliation" operation_id
       (Core.operation_id_to_string (Core.forensic_operation_id forensic));
     let source = match Core.forensic_source forensic with
       | Core.Prepared_source (source, _) -> source
       | Core.Bound_source (bound, _) -> Core.bound_prepared bound in
     check bool "forensic source retains exclusive-create intent" true
       (Core.prepared_publication source = Core.Create_exclusive)
   | _ -> fail "reconciliation did not retain exact forensic evidence");
  (match cut with
   | Prepared | Bound | Payload_opened | Payload_written ->
     check bool "reconciliation never publishes unproven content" false (Sys.file_exists target_path)
   | Published | Parent_synced ->
     check string "reconciliation preserves published target bytes" payload (Fs_compat.load_file target_path))

let () =
  match Array.to_list Sys.argv with
  | [_; "--crash-child"; name; directory] ->
    (match List.find_opt (fun cut -> String.equal name (cut_name cut)) cuts with
     | Some cut -> child cut directory
     | None -> fail "unknown child crash boundary")
  | _ -> run "exclusive-create process crash"
      ["SIGKILL/reopen", List.map (fun cut -> test_case (cut_name cut) `Quick (test_crash cut)) cuts]
