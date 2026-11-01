(** Reclamation of retired keepers' Apple volumes: report first, delete on
    request. See the interface for the contract; the ordering of the checks
    below is the safety story: containers first (the strongest live
    evidence), then the claims marker, then local registration, and only a
    keeper with no evidence at all becomes a candidate. All effects run
    through the injected [run]. *)

type volume_role =
  | Work_role
  | Build_role

type listed_volume =
  | Masc_keeper_volume of
      { role : volume_role
      ; volume_name : string
      ; keeper_name : string
      }
  | Foreign_volume of string

(* The reverse of the name builders: whatever follows the prefix must be a
   name the builder regenerates the listed name from. A keeper name that
   would build a different name -- or none -- is not ours, and the volume is
   foreign rather than misattributed. *)
let masc_keeper_volume_of_name volume_name =
  let under prefix =
    let prefix_length = String.length prefix in
    if
      String.length volume_name > prefix_length
      && String.starts_with ~prefix volume_name
    then Some (String.sub volume_name prefix_length (String.length volume_name - prefix_length))
    else None
  in
  let round_trip rebuilt =
    match rebuilt with
    | Ok name when String.equal name volume_name -> Some name
    | Ok _ | Error _ -> None
  in
  match (under "masc-keeper-work-", under "masc-keeper-build-") with
  | Some keeper_name, _ ->
    (match round_trip (Keeper_sandbox_microvm.work_volume_name ~keeper_name) with
     | Some _ -> Masc_keeper_volume { role = Work_role; volume_name; keeper_name }
     | None -> Foreign_volume volume_name)
  | _, Some keeper_name ->
    (match round_trip (Keeper_sandbox_microvm.build_volume_name ~keeper_name) with
     | Some _ -> Masc_keeper_volume { role = Build_role; volume_name; keeper_name }
     | None -> Foreign_volume volume_name)
  | None, None -> Foreign_volume volume_name
;;

type keep_reason =
  | Referenced_by_containers of string list
  | Claimed_by_workspaces of string list
  | Registered_in_this_workspace
  | Unverified of string

type keeper_outcome =
  | Kept of keep_reason
  | Reclaim_candidate
  | Reclaimed
  | Reclaim_failed of string

type keeper_verdict =
  { keeper_name : string
  ; work_volume : string option
  ; build_volume : string option
  ; outcome : keeper_outcome
  }

type report =
  { foreign_volumes : string list
  ; keepers : keeper_verdict list
  }

(* One keeper's volumes as the listing showed them: at least one of the two,
   and each name at most once. *)
let group_keeper_volumes volumes =
  let add name = function
    | None -> Some name
    | Some previous when String.equal previous name -> Some previous
    | Some previous ->
      (* A second, different work or build volume for one keeper name cannot
         be produced by the builders; treat the listing as evidence about
         itself and keep the first spelling rather than guess. *)
      Some previous
  in
  let indexed =
    List.fold_left
      (fun acc -> function
         | Foreign_volume _ -> acc
         | Masc_keeper_volume { role; volume_name; keeper_name } ->
           let entry =
             match List.assoc_opt keeper_name acc with
             | Some (work, build) -> (work, build)
             | None -> (None, None)
           in
           let entry =
             match role with
             | Work_role -> (add volume_name (fst entry), snd entry)
             | Build_role -> (fst entry, add volume_name (snd entry))
           in
           (keeper_name, entry) :: List.remove_assoc keeper_name acc)
      []
      volumes
  in
  List.rev_map (fun (keeper_name, (work, build)) -> keeper_name, work, build) indexed
;;

(* The claims marker of one keeper's work volume, read through the one-shot
   helper. [Ok None] means no claim protects the volume: the marker is
   absent (a legacy volume, claimed by no marker at all) or its array is
   empty (every claim was released). Anything unreadable is [Error] and the
   volumes stay. *)
let bounded_output limit text =
  if String.length text <= limit
  then text
  else String.sub text 0 limit ^ "…"
;;

let work_volume_claimants ~run ~timeout_sec ~keeper_name ~volume_name ~image =
  let status, stdout, stderr =
    run ~timeout_sec
      (Keeper_sandbox_microvm.apple_volume_claims_read_argv
         ~keeper_name ~volume_name ~image)
  in
  match status with
  | Unix.WEXITED 0 ->
    (match Keeper_sandbox_microvm.volume_claims_of_output stdout with
     | Claims_read [] | Marker_absent -> Ok None
     | Claims_read claimants -> Ok (Some claimants)
     | Claims_invalid detail -> Error ("claims marker unreadable: " ^ detail))
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error
      (Printf.sprintf
         "claims read helper failed (%s; stdout: %s; stderr: %s)"
         (Keeper_sandbox_exec_failure.status_label status)
         (bounded_output 200 stdout)
         (bounded_output 200 stderr))
;;

let judge_keeper ~run ~timeout_sec ~registered_keeper ~claims_image
    ~(keeper_name : string) ~work_volume : keeper_outcome
  =
  match
    Keeper_sandbox_microvm.apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name
  with
  | Error detail -> Kept (Unverified detail)
  | Ok (_ :: _ as owners) -> Kept (Referenced_by_containers owners)
  | Ok [] ->
    let after_containers () =
      match claims_image, work_volume with
      | Some image, Some volume_name ->
        (match work_volume_claimants ~run ~timeout_sec ~keeper_name ~volume_name ~image with
         | Ok None -> `No_claims
         | Ok (Some claimants) -> `Claimed claimants
         | Error detail -> `Unverified detail)
      | Some _, None ->
        (* Only a build volume is listed. The build volume is recreated empty
           at every boot, so it carries no marker of its own, and a workspace
           still running this keeper would list its work volume too. *)
        `No_claims
      | None, _ ->
        `Unverified
          "no image given for the claims read helper; claim evidence is \
           unavailable either way"
    in
    (match after_containers () with
     | `Claimed claimants -> Kept (Claimed_by_workspaces claimants)
     | `Unverified detail -> Kept (Unverified detail)
     | `No_claims ->
       if registered_keeper keeper_name
       then Kept Registered_in_this_workspace
       else Reclaim_candidate)
;;

let keep_reason_to_string = function
  | Referenced_by_containers names ->
    Printf.sprintf "containers still reference the keeper: %s" (String.concat ", " names)
  | Claimed_by_workspaces claimants ->
    Printf.sprintf
      "claimed by other workspace(s): %s"
      (String.concat ", " claimants)
  | Registered_in_this_workspace -> "registered in this workspace"
  | Unverified detail -> "unverified: " ^ detail
;;

let keeper_outcome_to_string = function
  | Kept reason -> "kept (" ^ keep_reason_to_string reason ^ ")"
  | Reclaim_candidate -> "reclaim candidate"
  | Reclaimed -> "reclaimed"
  | Reclaim_failed detail -> "reclaim failed: " ^ detail
;;

let apple_keeper_volume_gc ~run ~timeout_sec ~registered_keeper ~claims_image ~execute =
  match run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_list_argv ()) with
  | Unix.WEXITED 0, stdout, _ ->
    (match Yojson.Safe.from_string stdout with
     | exception Yojson.Json_error detail ->
       Error ("volume listing is invalid JSON: " ^ detail)
     | json ->
       (match Keeper_sandbox_microvm.volume_names_of_json json with
        | Error _ as error -> error
        | Ok names ->
          let volumes = List.map masc_keeper_volume_of_name names in
          let foreign =
            List.filter_map
              (function
                 | Masc_keeper_volume _ -> None
                 | Foreign_volume name -> Some name)
              volumes
          in
          let keepers =
            List.map
              (fun (keeper_name, work_volume, build_volume) ->
                 let outcome =
                   judge_keeper ~run ~timeout_sec ~registered_keeper ~claims_image
                     ~keeper_name ~work_volume
                 in
                 let outcome =
                   if execute && (match outcome with Reclaim_candidate -> true | _ -> false)
                   then
                     (match
                        Keeper_sandbox_microvm.remove_apple_keeper_volumes
                          ~run ~timeout_sec ~keeper_name
                      with
                      | Ok () -> Reclaimed
                      | Error detail -> Reclaim_failed detail)
                   else outcome
                 in
                 { keeper_name; work_volume; build_volume; outcome })
              (group_keeper_volumes volumes)
          in
          Ok { foreign_volumes = foreign; keepers }))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status, _, _ ->
    Error
      (Printf.sprintf
         "volume listing failed: %s"
         (Keeper_sandbox_exec_failure.status_label status))
;;
