(** Reclamation of retired keepers' Apple volumes: report first, then delete
    only the keepers a request names. See the interface for the contract;
    the ordering of the checks below is the safety story: containers first
    (the strongest live evidence), then local registration and the claims
    marker. Only a build-only volume with no observed reference becomes a
    candidate, and a candidate is deleted only when the request names it and
    a fresh listing confirms the build-only shape at delete time. Past that
    confirmation the fence is the platform, which refuses to delete a volume
    a container references, plus the absence check after the delete. All
    effects run through the injected [run]. *)

type volume_role =
  | Work_role
  | Build_role

type volume_ownership =
  | Legacy_shared
  | Workspace_scoped of string

type listed_volume =
  | Masc_keeper_volume of
      { role : volume_role
      ; ownership : volume_ownership
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
  match under "masc-keeper-ws-" with
  | Some rest ->
    let hash_len = Keeper_sandbox_microvm_work_volume.workspace_volume_hash_length in
    if String.length rest > hash_len + 1 && Char.equal rest.[hash_len] '-'
    then (
      let workspace_hash = String.sub rest 0 hash_len in
      let tail = String.sub rest (hash_len + 1) (String.length rest - hash_len - 1) in
      let under_tail prefix =
        let prefix_length = String.length prefix in
        if String.length tail > prefix_length && String.starts_with ~prefix tail
        then Some (String.sub tail prefix_length (String.length tail - prefix_length))
        else None
      in
      match under_tail "work-", under_tail "build-" with
      | Some keeper_name, _ ->
        (match
           round_trip
             (Keeper_sandbox_microvm.scoped_work_volume_name_with_hash
                ~workspace_hash ~keeper_name)
         with
         | Some _ ->
           Masc_keeper_volume
             { role = Work_role
             ; ownership = Workspace_scoped workspace_hash
             ; volume_name
             ; keeper_name
             }
         | None -> Foreign_volume volume_name)
      | _, Some keeper_name ->
        (match
           round_trip
             (Keeper_sandbox_microvm.scoped_build_volume_name_with_hash
                ~workspace_hash ~keeper_name)
         with
         | Some _ ->
           Masc_keeper_volume
             { role = Build_role
             ; ownership = Workspace_scoped workspace_hash
             ; volume_name
             ; keeper_name
             }
         | None -> Foreign_volume volume_name)
      | None, None -> Foreign_volume volume_name)
    else Foreign_volume volume_name
  | None ->
    (match (under "masc-keeper-work-", under "masc-keeper-build-") with
     | Some keeper_name, _ ->
       (match round_trip (Keeper_sandbox_microvm.work_volume_name ~keeper_name) with
        | Some _ ->
          Masc_keeper_volume
            { role = Work_role; ownership = Legacy_shared; volume_name; keeper_name }
        | None -> Foreign_volume volume_name)
     | _, Some keeper_name ->
       (match round_trip (Keeper_sandbox_microvm.build_volume_name ~keeper_name) with
        | Some _ ->
          Masc_keeper_volume
            { role = Build_role; ownership = Legacy_shared; volume_name; keeper_name }
        | None -> Foreign_volume volume_name)
     | None, None -> Foreign_volume volume_name)
;;

type keep_reason =
  | Referenced_by_containers of string list
  | Claimed_by_workspaces of string list
  | Owned_by_other_workspace of string
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

type request =
  | Report_only
  | Reclaim_named of string list

type report =
  { foreign_volumes : string list
  ; keepers : keeper_verdict list
  ; unlisted_keepers : string list
  }

(* One keeper's volumes per ownership scope as the listing showed them: at
   least one of the two, and each name at most once. Grouping by
   [(ownership, keeper_name)] keeps two workspaces' same-named keepers apart. *)
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
         | Masc_keeper_volume { role; ownership; volume_name; keeper_name } ->
           let key = ownership, keeper_name in
           let entry =
             match List.assoc_opt key acc with
             | Some (work, build) -> (work, build)
             | None -> (None, None)
           in
           let entry =
             match role with
             | Work_role -> (add volume_name (fst entry), snd entry)
             | Build_role -> (fst entry, add volume_name (snd entry))
           in
           (key, entry) :: List.remove_assoc key acc)
      []
      volumes
  in
  List.rev_map
    (fun ((ownership, keeper_name), (work, build)) -> ownership, keeper_name, work, build)
    indexed
;;

(* A missing or empty marker cannot exclude an unrecorded owner in another
   workspace, including a paused legacy keeper with no container. Keep the
   work volume until ownership can be established independently. *)
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
     | Marker_absent -> Error "claims marker absent; unrecorded owners cannot be excluded"
     | Claims_read [] -> Error "claims marker empty; unrecorded owners cannot be excluded"
     | Claims_read claimants -> Ok claimants
     | Claims_invalid detail -> Error ("claims marker unreadable: " ^ detail))
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error
      (Printf.sprintf
         "claims read helper failed (%s; stdout: %s; stderr: %s)"
         (Keeper_sandbox_exec_failure.status_label status)
         (bounded_output 200 stdout)
         (bounded_output 200 stderr))
;;

let judge_keeper ~workspace_hash ~run ~timeout_sec ~registered_keeper ~claims_image
    ~(ownership : volume_ownership) ~(keeper_name : string) ~work_volume : keeper_outcome
  =
  match ownership with
  | Workspace_scoped volume_hash ->
    (match workspace_hash with
     | None ->
       Kept
         (Unverified
            "workspace hash not supplied; workspace-scoped volume ownership cannot be verified")
     | Some current_hash when not (String.equal current_hash volume_hash) ->
       Kept (Owned_by_other_workspace volume_hash)
     | Some current_hash ->
       (match
          Keeper_sandbox_microvm.apple_keeper_workspace_owner_containers
            ~run ~timeout_sec ~workspace_hash:current_hash ~keeper_name
        with
        | Error detail -> Kept (Unverified detail)
        | Ok (_ :: _ as owners) -> Kept (Referenced_by_containers owners)
        | Ok [] when registered_keeper keeper_name -> Kept Registered_in_this_workspace
        | Ok [] -> Reclaim_candidate))
  | Legacy_shared ->
    (match
       Keeper_sandbox_microvm.apple_keeper_owner_containers ~run ~timeout_sec ~keeper_name
     with
     | Error detail -> Kept (Unverified detail)
     | Ok (_ :: _ as owners) -> Kept (Referenced_by_containers owners)
     | Ok [] when registered_keeper keeper_name -> Kept Registered_in_this_workspace
     | Ok [] ->
       let after_containers () =
         match claims_image, work_volume with
         | Some image, Some volume_name ->
           (match work_volume_claimants ~run ~timeout_sec ~keeper_name ~volume_name ~image with
            | Ok claimants -> `Claimed claimants
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
        | `No_claims -> Reclaim_candidate))
;;

let keep_reason_to_string = function
  | Referenced_by_containers names ->
    Printf.sprintf "containers still reference the keeper: %s" (String.concat ", " names)
  | Claimed_by_workspaces claimants ->
    Printf.sprintf
      "claimed by other workspace(s): %s"
      (String.concat ", " claimants)
  | Owned_by_other_workspace hash ->
    Printf.sprintf "owned by another workspace (%s)" hash
  | Registered_in_this_workspace -> "registered in this workspace"
  | Unverified detail -> "unverified: " ^ detail
;;

let keeper_outcome_to_string = function
  | Kept reason -> "kept (" ^ keep_reason_to_string reason ^ ")"
  | Reclaim_candidate -> "reclaim candidate"
  | Reclaimed -> "reclaimed"
  | Reclaim_failed detail -> "reclaim failed: " ^ detail
;;

(* A candidate is judged from the initial listing, which can predate a
   concurrent boot by the whole judging loop: a fresh boot ensures its work
   volume before it touches the build volume, so a work volume that appears
   after the verdict (or a build volume that disappears) means another
   workspace is moving and the verdict is stale. Confirm the exact
   build-only shape with a fresh listing immediately before the delete; any
   change, or an unreadable confirmation, preserves the keeper. A boot that
   starts after this listing is fenced by the platform instead, which
   refuses to delete a volume a container references. *)
let check_delete_time_registration ~registered_keeper ~revalidate ~keeper_name =
  match revalidate () with
  | Error detail ->
    Error
      (Printf.sprintf
         "keeper declarations changed or became unreadable before deletion of %s: %s"
         keeper_name
         detail)
  | Ok () ->
    if registered_keeper keeper_name
    then
      Error
        (Printf.sprintf
           "keeper %s became registered before volume deletion; preserved without deleting"
           keeper_name)
    else Ok ()
;;

let confirm_build_only_shape
      ~run
      ~timeout_sec
      ~registered_keeper
      ~revalidate
      ~keeper_name
      ~volume_name
  =
  let open Result.Syntax in
  let* () = check_delete_time_registration ~registered_keeper ~revalidate ~keeper_name in
  match run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_list_argv ()) with
  | Unix.WEXITED 0, listing, _ ->
    (match Yojson.Safe.from_string listing with
     | exception Yojson.Json_error detail ->
       Error ("reclamation confirmation listing is invalid JSON: " ^ detail)
     | json ->
       (match Keeper_sandbox_microvm.volume_names_of_json json with
        | Error _ as error -> error
        | Ok names ->
          let current =
            List.find_opt
              (fun (ownership, name, _, _) ->
                 ownership = Legacy_shared && String.equal name keeper_name)
              (group_keeper_volumes (List.map masc_keeper_volume_of_name names))
          in
          (match current with
           | None ->
             Error
               (Printf.sprintf
                  "keeper %s is absent from the delete-time listing; preserved without deleting"
                  keeper_name)
           | Some (_, _, Some work_now, _) ->
             Error
               (Printf.sprintf
                  "work volume %s appeared after the verdict; preserved without deleting"
                  work_now)
           | Some (_, _, None, Some build_now) when String.equal build_now volume_name ->
             check_delete_time_registration ~registered_keeper ~revalidate ~keeper_name
           | Some (_, _, None, _) ->
             Error
               (Printf.sprintf
                  "listed build volume %s changed before the delete; preserved without deleting"
                  volume_name))))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as confirmation_status, _, _ ->
    Error
      (Printf.sprintf "cannot confirm volume %s is still build-only (%s)" volume_name
         (Keeper_sandbox_exec_failure.status_label confirmation_status))
;;

let confirm_scoped_shape
      ~run
      ~timeout_sec
      ~registered_keeper
      ~revalidate
      ~workspace_hash
      ~keeper_name
      ~work_volume
      ~build_volume
  =
  let open Result.Syntax in
  let* () = check_delete_time_registration ~registered_keeper ~revalidate ~keeper_name in
  match
    Keeper_sandbox_microvm.apple_keeper_workspace_owner_containers
      ~run ~timeout_sec ~workspace_hash ~keeper_name
  with
  | Error detail -> Error ("cannot confirm containers before scoped reclamation: " ^ detail)
  | Ok (_ :: _ as owners) ->
    Error
      (Printf.sprintf
         "containers appeared before scoped volume deletion: %s"
         (String.concat ", " owners))
  | Ok [] ->
    (match run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_list_argv ()) with
     | Unix.WEXITED 0, listing, _ ->
       (match Yojson.Safe.from_string listing with
        | exception Yojson.Json_error detail ->
          Error ("reclamation confirmation listing is invalid JSON: " ^ detail)
        | json ->
          (match Keeper_sandbox_microvm.volume_names_of_json json with
           | Error _ as error -> error
           | Ok names ->
             let current =
               List.find_opt
                 (fun (ownership, name, _, _) ->
                    ownership = Workspace_scoped workspace_hash
                    && String.equal name keeper_name)
                 (group_keeper_volumes (List.map masc_keeper_volume_of_name names))
             in
             (match current with
              | None ->
                Error
                  (Printf.sprintf
                     "keeper %s is absent from the delete-time listing; preserved without deleting"
                     keeper_name)
              | Some (_, _, work_now, build_now)
                when Option.equal String.equal work_now work_volume
                     && Option.equal String.equal build_now build_volume ->
                check_delete_time_registration ~registered_keeper ~revalidate ~keeper_name
              | Some _ ->
                Error
                  (Printf.sprintf
                     "listed scoped volumes for %s changed before the delete; preserved without deleting"
                     keeper_name))))
     | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as confirmation_status, _, _ ->
       Error
         (Printf.sprintf "cannot confirm scoped volumes for %s (%s)" keeper_name
            (Keeper_sandbox_exec_failure.status_label confirmation_status)))
;;

let remove_listed_build_volume ~run ~timeout_sec ~volume_name =
  let status, stdout, stderr =
    run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_delete_argv ~volume_name)
  in
  match run ~timeout_sec (Keeper_sandbox_microvm.apple_volume_list_argv ()) with
  | Unix.WEXITED 0, listing, _ ->
    (match Yojson.Safe.from_string listing with
     | exception Yojson.Json_error detail ->
       Error ("keeper volume inventory is invalid JSON: " ^ detail)
     | json ->
       (match Keeper_sandbox_microvm.volume_names_of_json json with
        | Error _ as error -> error
        | Ok names ->
          if List.exists (String.equal volume_name) names
          then
            Error
              (Printf.sprintf "volume %s remains after removal (%s; stdout: %s; stderr: %s)"
                 volume_name
                 (Keeper_sandbox_exec_failure.status_label status)
                 (bounded_output 200 stdout)
                 (bounded_output 200 stderr))
          else Ok ()))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as listing_status, _, _ ->
    Error
      (Printf.sprintf "cannot verify volume %s was removed (%s)"
         volume_name (Keeper_sandbox_exec_failure.status_label listing_status))
;;

let named request keeper_name =
  match request with
  | Report_only -> false
  | Reclaim_named requested -> List.exists (String.equal keeper_name) requested
;;

let reclaim_listed_candidate
      ~run
      ~timeout_sec
      ~registered_keeper
      ~revalidate
      ~ownership
      ~keeper_name
      ~work_volume
      ~build_volume
  =
  match ownership with
  | Workspace_scoped workspace_hash ->
    let volume_names =
      List.filter_map Fun.id [ work_volume; build_volume ]
    in
    (match volume_names with
     | [] -> Reclaim_failed "reclaim candidate lists no volumes"
     | _ :: _ ->
       (match
          confirm_scoped_shape
            ~run
            ~timeout_sec
            ~registered_keeper
            ~revalidate
            ~workspace_hash
            ~keeper_name
            ~work_volume
            ~build_volume
        with
        | Error detail -> Kept (Unverified detail)
        | Ok () ->
          (match
             Keeper_sandbox_microvm.remove_apple_volumes_by_names
               ~run ~timeout_sec ~volume_names
           with
           | Ok () -> Reclaimed
           | Error detail -> Reclaim_failed detail)))
  | Legacy_shared ->
    (match work_volume, build_volume with
     | None, Some volume_name ->
       (match
          confirm_build_only_shape
            ~run ~timeout_sec ~registered_keeper ~revalidate ~keeper_name ~volume_name
        with
        | Error detail -> Kept (Unverified detail)
        | Ok () ->
          (match remove_listed_build_volume ~run ~timeout_sec ~volume_name with
           | Ok () -> Reclaimed
           | Error detail -> Reclaim_failed detail))
     | Some _, _ | None, None ->
       Reclaim_failed "reclaim candidate is not a listed build-only volume")
;;

let apple_keeper_volume_gc_internal
      ~workspace_hash
      ~revalidate
      ~run
      ~timeout_sec
      ~registered_keeper
      ~claims_image
      ~request
  =
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
          let grouped = group_keeper_volumes volumes in
          let keepers =
            List.map
              (fun (ownership, keeper_name, work_volume, build_volume) ->
                 let outcome =
                   match
                     judge_keeper ~workspace_hash ~run ~timeout_sec ~registered_keeper ~claims_image
                       ~ownership ~keeper_name ~work_volume
                   with
                   | Reclaim_candidate when named request keeper_name ->
                     reclaim_listed_candidate
                       ~run
                       ~timeout_sec
                       ~registered_keeper
                       ~revalidate
                       ~ownership
                       ~keeper_name
                       ~work_volume
                       ~build_volume
                   | (Kept _ | Reclaim_candidate | Reclaimed | Reclaim_failed _) as judged ->
                     judged
                 in
                 { keeper_name; work_volume; build_volume; outcome })
              grouped
          in
          let unlisted_keepers =
            match request with
            | Report_only -> []
            | Reclaim_named requested ->
              List.filter
                (fun name ->
                   not
                     (List.exists
                        (fun (_, keeper_name, _, _) -> String.equal keeper_name name)
                        grouped))
                requested
          in
          Ok { foreign_volumes = foreign; keepers; unlisted_keepers }))
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status, _, _ ->
    Error
      (Printf.sprintf
         "volume listing failed: %s"
         (Keeper_sandbox_exec_failure.status_label status))
;;

let apple_keeper_volume_gc ~run ~timeout_sec ~registered_keeper ~claims_image ~request =
  apple_keeper_volume_gc_internal
    ~workspace_hash:None
    ~revalidate:(fun () -> Ok ())
    ~run
    ~timeout_sec
    ~registered_keeper
    ~claims_image
    ~request
;;

let apple_keeper_volume_gc_for_workspace
      ~workspace_hash
      ?(revalidate = fun () -> Ok ())
      ~run
      ~timeout_sec
      ~registered_keeper
      ~claims_image
      ~request
      ()
  =
  if not (Keeper_sandbox_microvm_work_volume.valid_workspace_volume_hash workspace_hash)
  then
    Error
      (Printf.sprintf
         "invalid workspace volume hash %S: expected %d lowercase hex characters"
         workspace_hash
         Keeper_sandbox_microvm_work_volume.workspace_volume_hash_length)
  else
    apple_keeper_volume_gc_internal
      ~workspace_hash:(Some workspace_hash)
      ~revalidate
      ~run
      ~timeout_sec
      ~registered_keeper
      ~claims_image
      ~request
;;
