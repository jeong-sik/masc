open Keeper_meta_contract

type decision =
  | Approve
  | Reject

let ( let* ) = Result.bind

let generate_id () = Random_id.prefixed ~prefix:"continue-" ~bytes:16

let owns ~gate_id (meta : keeper_meta) =
  meta.paused
  &&
  match meta.latched_reason with
  | Some (Keeper_latched_reason.Continue_gate_pending { gate_id = current; _ }) ->
    String.equal current gate_id
  | Some _ | None -> false
;;

let preserve_latest_control_fields
      ~(latest : keeper_meta)
      ~(caller : keeper_meta)
  =
  let merged = Keeper_meta_merge.monotonic_usage_counters ~latest ~caller in
  { merged with
    paused = latest.paused
  ; latched_reason = latest.latched_reason
  ; auto_resume_after_sec = latest.auto_resume_after_sec
  ; runtime = { merged.runtime with last_blocker = latest.runtime.last_blocker }
  }
;;

let legacy_unowned (meta : keeper_meta) = meta.paused && Option.is_none meta.latched_reason

let install_merge
      ~allow_legacy_unowned
      ~gate_id
      ~(latest : keeper_meta)
      ~(caller : keeper_meta)
  =
  if
    latest.paused
    && not (owns ~gate_id latest)
    && not (allow_legacy_unowned && legacy_unowned latest)
  then preserve_latest_control_fields ~latest ~caller
  else Keeper_meta_merge.operator_control_fields_from_caller ~latest ~caller
;;

let resolution_merge ~gate_id ~(latest : keeper_meta) ~(caller : keeper_meta) =
  if owns ~gate_id latest
  then Keeper_meta_merge.operator_control_fields_from_caller ~latest ~caller
  else preserve_latest_control_fields ~latest ~caller
;;

let read_required config keeper_name =
  match Keeper_meta_store.read_meta config keeper_name with
  | Ok (Some meta) -> Ok meta
  | Ok None -> Error (Printf.sprintf "keeper metadata unavailable: %s" keeper_name)
  | Error err -> Error ("keeper metadata read failed: " ^ err)
;;

let install_with
      ~allow_legacy_unowned
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~gate_id
      ~origin
      ~committed_tools
  =
  if String.trim gate_id = ""
  then Error "continue gate id must not be empty"
  else
    let* latest = read_required config meta.name in
    if
      latest.paused
      && not (owns ~gate_id latest)
      && not (allow_legacy_unowned && legacy_unowned latest)
    then Error "keeper is already paused by a different authoritative gate"
    else
      let caller =
        Keeper_meta_merge.monotonic_usage_counters ~latest ~caller:meta
      in
      let gated =
        { caller with
          paused = true
        ; latched_reason =
            Some
              (Keeper_latched_reason.Continue_gate_pending
                 { gate_id; origin; committed_tools })
        ; auto_resume_after_sec = None
        ; updated_at = now_iso ()
        }
      in
      let* persisted =
        Keeper_meta_store.write_meta_with_merge_returning
          ~merge:(install_merge ~allow_legacy_unowned ~gate_id)
          config
          gated
      in
      Keeper_registry.sync_persisted_meta_if_newer
        ~base_path:config.base_path
        persisted.name
        persisted;
      if owns ~gate_id persisted
      then Ok persisted
      else Error "continue gate install lost exact ownership"
;;

let install = install_with ~allow_legacy_unowned:false
let migrate_legacy = install_with ~allow_legacy_unowned:true

let resolve ~(config : Workspace.config) ~keeper_name ~gate_id ~decision =
  let* latest = read_required config keeper_name in
  if not (owns ~gate_id latest)
  then Error "continue gate is stale or no longer owns the keeper pause"
  else
    let caller =
      match decision with
      | Approve ->
        { latest with
          paused = false
        ; latched_reason = None
        ; auto_resume_after_sec = None
        ; updated_at = now_iso ()
        ; runtime = { latest.runtime with last_blocker = None }
        }
      | Reject ->
        { latest with
          paused = true
        ; latched_reason =
            Some
              (Keeper_latched_reason.Operator_paused
                 { operator_actor = Keeper_latched_reason.Hitl_rejection })
        ; auto_resume_after_sec = None
        ; updated_at = now_iso ()
        ; runtime = { latest.runtime with last_blocker = None }
        }
    in
    let* persisted =
      Keeper_meta_store.write_meta_with_merge_returning
        ~merge:(resolution_merge ~gate_id)
        config
        caller
    in
    Keeper_registry.sync_persisted_meta_if_newer
      ~base_path:config.base_path
      persisted.name
      persisted;
    let postcondition =
      match decision with
      | Approve -> (not persisted.paused) && Option.is_none persisted.latched_reason
      | Reject ->
        persisted.paused
        &&
        match persisted.latched_reason with
        | Some
            (Keeper_latched_reason.Operator_paused
              { operator_actor = Keeper_latched_reason.Hitl_rejection }) ->
          true
        | Some (Keeper_latched_reason.Operator_paused _)
        | Some _ | None -> false
    in
    if postcondition
    then Ok persisted
    else Error "continue gate resolution was superseded by newer authoritative state"
;;
