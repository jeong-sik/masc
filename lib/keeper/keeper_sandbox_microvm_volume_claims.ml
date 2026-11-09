open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_work_volume
open Keeper_sandbox_microvm_volume_claim_scripts

(* Strict decode of marker content. Empty output means no marker (the read
   helper prints nothing for an absent file); anything else must be a JSON
   array of valid claimants, or it is invalid -- never a default. *)
type volume_claims_read =
  | Marker_absent
  | Claims_read of string list
  | Claims_invalid of string

let volume_claims_of_output output =
  let trimmed = String.trim output in
  if String.equal trimmed ""
  then Marker_absent
  else
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error detail -> Claims_invalid ("invalid JSON: " ^ detail)
    | `List elements ->
      let rec claimants_of elements acc =
        match elements with
        | [] -> Ok (List.rev acc)
        | `String claimant :: rest when valid_volume_claimant claimant ->
          claimants_of rest (claimant :: acc)
        | `String claimant :: _ ->
          Error (Printf.sprintf "claimant %S is not a valid base-path claim" claimant)
        | _ :: _ -> Error "a claims element is not a string"
      in
      (match claimants_of elements [] with
       | Ok claimants -> Claims_read claimants
       | Error detail -> Claims_invalid detail)
    | _ -> Claims_invalid "the claims marker is not a JSON array"
;;

(* The release helper's stdout protocol: one outcome word, and for [kept]
   the marker content that remains. Pure, so the mapping is testable
   without a container runtime. *)
type apple_volume_claim_helper_report =
  | Claims_marker_absent
  | Claimant_not_present
  | Released_last_claim
  | Kept_with_claimants of string list
  | Report_unrecognized of string

let volume_claim_helper_report_of_output output =
  match output with
  | "absent\n" -> Claims_marker_absent
  | "not-claimed\n" -> Claimant_not_present
  | "released-last\n" -> Released_last_claim
  | _ ->
    (match String.index_opt output '\n' with
     | None -> Report_unrecognized (String.trim output)
     | Some index ->
       let first = String.sub output 0 index in
       let rest = String.sub output (index + 1) (String.length output - index - 1) in
       match first with
       | "kept" ->
         (match volume_claims_of_output rest with
          | Claims_read claimants -> Kept_with_claimants claimants
          | Marker_absent | Claims_invalid _ ->
            Report_unrecognized "kept without a readable claims array")
       | other -> Report_unrecognized other)
;;

(* One container listing answers every presence question here. The strict
   inventory decoder rejects malformed rows wholesale, and unlabelled rows
   never prove a keeper's absence. *)
let apple_claims_inventory ~run ~timeout_sec =
  match run ~timeout_sec (apple_container_list_argv ()) with
  | Unix.WEXITED 0, stdout, _ ->
    (match Keeper_microvm_inventory_json.of_apple_json stdout with
     | Ok inventory -> Ok inventory
     | Error error ->
       Error
         ("microvm_volume_claims_inventory_invalid: "
          ^ Keeper_microvm_inventory_json.invalid_inventory_message error))
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _, _ ->
    Error
      ("microvm_volume_claims_inventory_failed: container list "
       ^ Keeper_sandbox_exec_failure.status_label status)
;;

let apple_claims_helper_absent ~run ~timeout_sec ~keeper_name =
  let helper_name = volume_claim_helper_name ~keeper_name in
  match apple_claims_inventory ~run ~timeout_sec with
  | Error _ as error -> error
  | Ok inventory ->
    (match Keeper_microvm_inventory_json.presence ~guest_name:helper_name inventory with
     | Ok Keeper_microvm_inventory_json.Absent -> Ok ()
     | Ok Keeper_microvm_inventory_json.Present ->
       Error
         (Printf.sprintf
            "microvm_volume_claim_helper_present: claims helper %s is present; its \
             workspace owner is unknown, so this claim is not written"
            helper_name)
     | Error Keeper_microvm_inventory_json.Invalid_guest_name ->
       Error ("microvm_volume_claim_helper_unnamed: " ^ helper_name))
;;

(* Every observed container that references this keeper: guests carry the
   keeper's scoping label, and the three volume helpers carry its name. Any
   one of them present means a workspace may hold the volume right now --
   a live guest mounting it, or a helper mid-operation -- so a release
   refuses rather than race it. Unlabelled foreign rows prove nothing and
   are not treated as owners. *)
let apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name =
  match apple_claims_inventory ~run ~timeout_sec with
  | Error _ as error -> error
  | Ok inventory ->
    let module Inventory = Keeper_microvm_inventory_json in
    let guests =
      List.filter_map
        (fun (row : Inventory.row) ->
           match row.scoping_labels with
           | Some labels when String.equal labels.keeper keeper_name -> Some row.name
           | Some _ | None -> None)
        (Inventory.rows inventory)
    in
    let helpers =
      List.filter_map
        (fun name ->
           match Inventory.presence ~guest_name:name inventory with
           | Ok Inventory.Present -> Some name
           | Ok Inventory.Absent | Error Inventory.Invalid_guest_name -> None)
        [ work_volume_trim_name ~keeper_name
        ; volume_repair_name ~keeper_name
        ; volume_claim_helper_name ~keeper_name
        ]
    in
    Ok (guests @ helpers)
;;

(* Record one workspace's claim, idempotently. Fresh Apple provisioning stops
   on an error. This does not establish that legacy or adopted users of an
   existing shared volume were recorded. *)
let add_apple_work_volume_claim ~run ~timeout_sec ~keeper_name ~volume_name ~image ~claimant
  : (unit, string) result
  =
  if not (valid_volume_claimant claimant)
  then
    Error
      (Printf.sprintf
         "microvm_volume_claimant_invalid: base path %S cannot be recorded as a claim"
         claimant)
  else
    match apple_claims_helper_absent ~run ~timeout_sec ~keeper_name with
    | Error _ as error -> error
    | Ok () ->
      let status, stdout, stderr =
        run ~timeout_sec (apple_volume_claim_add_argv ~keeper_name ~volume_name ~image ~claimant)
      in
      match status, stdout with
      | Unix.WEXITED 0, ("added\n" | "present\n") -> Ok ()
      | Unix.WEXITED 0, _ ->
        Error
          (Printf.sprintf
             "microvm_volume_claim_helper_unrecognized: %s returned %S"
             (volume_claim_helper_name ~keeper_name)
             (output_for_log ~stdout ~stderr))
      | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _ ->
        Error
          (Printf.sprintf
             "microvm_volume_claim_helper_failed: %s (%s; %s)"
             (volume_claim_helper_name ~keeper_name)
             (Keeper_sandbox_exec_failure.status_label status)
             (output_for_log ~stdout ~stderr))
;;

type apple_volume_claim_release =
  | Kept_for_claimants of string list
  | Kept_for_containers of string list
  | Skipped_unverified of string

(* Release one workspace's claim and always keep the volumes. The last
   recorded claim plus an empty owner listing cannot prove exclusive
   ownership: a legacy, adopted, or paused-unrecorded owner in another
   workspace is absent from both the marker and the container listing, and
   no host-side enumeration can complete the owner set, so deletion on
   those signals could destroy another keeper's resume data. A concurrent
   boot between the listing and a deletion is likewise unfenced. This call
   therefore never deletes; it only releases the caller's claim. The
   release helper runs even when owner containers are present or the owner
   listing fails. A dissolved workspace should release its claim:
   dissolution is one-shot, and a workspace that never comes back would
   keep the marker naming it forever. A helper failure does not prove that
   the release took effect. One helper reads the marker, filters our claim
   out and rewrites it: the read and the write are one container, so no
   other helper can land a claim between them. When ours was the last
   recorded claim the helper removes the marker; the volumes stay, and the
   outcome reports the observation. *)
let release_apple_work_volume_claim ~run ~timeout_sec ~keeper_name ~volume_name ~image ~claimant
  : apple_volume_claim_release
  =
  let skipped detail = Skipped_unverified detail in
  if not (valid_volume_claimant claimant)
  then
    skipped
      (Printf.sprintf
         "microvm_volume_claimant_invalid: base path %S cannot be matched against claims"
         claimant)
  else
    let status, stdout, stderr =
      run ~timeout_sec
        (apple_volume_claim_release_argv ~keeper_name ~volume_name ~image ~claimant)
    in
    let report = volume_claim_helper_report_of_output stdout in
    match apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name with
    | Error listing_detail ->
      let unverified detail =
        skipped
          (Printf.sprintf
             "microvm_volume_release_owner_unverified: the owner listing failed (%s); %s"
             listing_detail detail)
      in
      (match (status, report) with
       | Unix.WEXITED 0, Claims_marker_absent ->
         unverified "no claims marker, so no claim of this workspace remained anyway"
       | Unix.WEXITED 0, Claimant_not_present ->
         unverified
           (Printf.sprintf
              "%s held no recorded claim on the volume"
              claimant)
       | Unix.WEXITED 0, Kept_with_claimants claimants ->
         unverified
           (Printf.sprintf
              "this workspace's claim was released; %d other claimant(s) remain: %s"
              (List.length claimants)
              (String.concat ", " claimants))
       | Unix.WEXITED 0, Released_last_claim ->
         unverified
           "this workspace's claim was the last one and the marker was removed; the \
            volumes are kept because no owner evidence could be read"
       | Unix.WEXITED 0, Report_unrecognized word ->
         unverified
           (Printf.sprintf
              "the claims helper reported %S, so the claim's release is unconfirmed (%s)"
              word
              (output_for_log ~stdout ~stderr))
       | ( ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as failure_status)
         , ( Claims_marker_absent
           | Claimant_not_present
           | Released_last_claim
           | Kept_with_claimants _
           | Report_unrecognized _ ) ) ->
         unverified
           (Printf.sprintf
              "the claims helper failed (%s; %s), so the claim's release is unconfirmed"
              (Keeper_sandbox_exec_failure.status_label failure_status)
              (output_for_log ~stdout ~stderr)))
    | Ok owners ->
      (match (status, report) with
       | Unix.WEXITED 0, Claims_marker_absent ->
         skipped
           "microvm_volume_claims_absent: legacy volume without a claims marker; ownership \
            is not provable"
       | Unix.WEXITED 0, Claimant_not_present ->
         skipped
           (Printf.sprintf
              "microvm_volume_claims_not_claimed: %s holds no recorded claim on %s"
              claimant volume_name)
       | Unix.WEXITED 0, Kept_with_claimants claimants -> Kept_for_claimants claimants
       | Unix.WEXITED 0, Released_last_claim ->
         (match owners with
          | [] ->
            skipped
              "microvm_volume_ownership_unprovable: the last recorded claim was \
               released and no owner container was observed, but a legacy, \
               adopted, or paused-unrecorded owner in another workspace cannot \
               be excluded and a concurrent boot is not fenced; the work and \
               build volumes are kept"
          | _ :: _ -> Kept_for_containers owners)
       | Unix.WEXITED 0, Report_unrecognized word ->
         skipped
           (Printf.sprintf
              "microvm_volume_claims_unrecognized: claims helper %s reported %S (%s)"
              (volume_claim_helper_name ~keeper_name)
              word
              (output_for_log ~stdout ~stderr))
       | ( ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status)
         , ( Claims_marker_absent
           | Claimant_not_present
           | Released_last_claim
           | Kept_with_claimants _
           | Report_unrecognized _ ) ) ->
         skipped
           (Printf.sprintf
              "microvm_volume_claim_helper_failed: %s (%s; %s)"
              (volume_claim_helper_name ~keeper_name)
              (Keeper_sandbox_exec_failure.status_label status)
              (output_for_log ~stdout ~stderr)))
;;
