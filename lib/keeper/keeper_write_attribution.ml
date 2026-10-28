module Reason = Agent_observation.Unattributed

open Result.Syntax

let root_prefix root = if String.equal root "/" then root else root ^ "/"

let inspect budget ~unavailable read =
  match Repo_git.Inspection_budget.remaining_timeout budget with
  | Error _ -> Error Reason.Origin_lookup_timed_out
  | Ok timeout_sec -> Result.map_error (fun _ -> unavailable) (read timeout_sec)
;;

let realpath path =
  try Ok (Unix.realpath path) with
  | Unix.Unix_error _ | Sys_error _ -> Error Reason.Checkout_unavailable
;;

type origin = Remote of string | Local of string

let parse_origin ~checkout raw =
  if Agent_observation.remote_url_syntax raw then
    match Agent_observation.canonical_url_of_remote raw with
    | Some slug -> Ok (Remote slug)
    | None -> Error (Reason.Unparseable_remote_url raw)
  else
    let uri = Uri.of_string raw in
    let* path =
      match Uri.scheme uri with
      | None -> Ok raw
      | Some "file" ->
        (match Uri.host uri with
         | None | Some "" | Some "localhost" -> Ok (Uri.pct_decode (Uri.path uri))
         | Some _ -> Error (Reason.Unparseable_remote_url raw))
      | Some _ -> Error (Reason.Unparseable_remote_url raw)
    in
    if String.equal path "" then Error Reason.Blank_remote_url
    else
      let path = if Filename.is_relative path then Filename.concat checkout path else path in
      let* path = realpath path in
      Ok (Local path)
;;

let catalog_slug (repo : Repo_manager_types.repository) =
  if String.equal (String.trim repo.url) "" then Error Reason.Blank_remote_url
  else
    match Agent_observation.canonical_url_of_remote repo.url with
    | None -> Error (Reason.Unparseable_remote_url repo.url)
    | Some slug -> Ok slug
;;

let catalog_root ~base_dir (repo : Repo_manager_types.repository) =
  let path = Repo_store.local_path ~base_path:base_dir repo in
  try Ok (Some (Unix.realpath path)) with
  | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok None
  | Unix.Unix_error _ | Sys_error _ -> Error Reason.Repository_catalog_unavailable
;;

let local_matches ~base_dir ~budget ~origin repositories =
  let* origin_common =
    inspect budget ~unavailable:Reason.Origin_lookup_failed
      (fun timeout_sec -> Repo_git.common_dir ~timeout_sec ~local_path:origin ())
  in
  let rec collect matches = function
    | [] -> Ok (List.rev matches)
    | repo :: rest ->
      let* root = catalog_root ~base_dir repo in
      (match root with
       | None -> collect matches rest
       | Some root ->
         (* A linked worktree may live anywhere. Compare every available
            registered checkout's physical Git identity: path ancestry is
            neither required nor sufficient for local-origin ownership.
            An unreadable candidate leaves identity unknown, even if an
            earlier candidate matched, so the inspection failure propagates. *)
         let* identity =
           inspect budget ~unavailable:Reason.Checkout_unavailable
             (fun timeout_sec -> Repo_git.checkout_identity ~timeout_sec ~local_path:root ())
         in
         if String.equal origin_common identity.Repo_git.git_common_dir
         then collect (repo :: matches) rest
         else collect matches rest)
  in
  collect [] repositories
;;

let choose_identity repositories =
  let rec slugs acc = function
    | [] -> Ok (List.sort_uniq String.compare acc)
    | repo :: rest ->
      let* slug = catalog_slug repo in
      slugs (slug :: acc) rest
  in
  let* identities = slugs [] repositories in
  match identities with
  | [] -> Error Reason.Unregistered_origin
  | [ slug ] -> Ok slug
  | _ :: _ :: _ -> Error Reason.Ambiguous_origin
;;

let resolve_observed ~base_dir ~file_path =
  let* repositories =
    Result.map_error (fun _ -> Reason.Repository_catalog_unavailable)
      (Repo_store.load_all ~base_path:base_dir)
  in
  let abs = if Filename.is_relative file_path then Filename.concat base_dir file_path else file_path in
  (* Resolve the existing parent, not the file: a completed delete may name a
     missing leaf. This also aligns symlinked temp/base paths with Git's roots. *)
  let* parent = realpath (Filename.dirname abs) in
  let abs = Filename.concat parent (Filename.basename abs) in
  let budget = Repo_git.Inspection_budget.create () in
  let* identity =
    inspect budget ~unavailable:Reason.Checkout_unavailable
      (fun timeout_sec -> Repo_git.checkout_identity ~timeout_sec ~local_path:parent ())
  in
  let* timeout_sec =
    Result.map_error (fun _ -> Reason.Origin_lookup_timed_out)
      (Repo_git.Inspection_budget.remaining_timeout budget)
  in
  let* raw_origin =
    Result.map_error
      (function
        | Repo_git.Origin_missing -> Reason.Origin_missing
        | Repo_git.Origin_lookup_timed_out _ -> Reason.Origin_lookup_timed_out
        | Repo_git.Origin_lookup_failed _ -> Reason.Origin_lookup_failed)
      (Repo_git.get_origin_url ~timeout_sec ~local_path:identity.toplevel ())
  in
  let* origin = parse_origin ~checkout:identity.toplevel raw_origin in
  let* matches =
    match origin with
    | Remote slug ->
      Ok (List.filter (fun repo ->
        match catalog_slug repo with
        | Ok candidate -> String.equal candidate slug
        | Error _ -> false) repositories)
    | Local origin -> local_matches ~base_dir ~budget ~origin repositories
  in
  let* slug = choose_identity matches in
  let prefix = root_prefix identity.toplevel in
  if not (String.starts_with ~prefix abs) then Error Reason.Unregistered_path
  else
    let rel = String.sub abs (String.length prefix) (String.length abs - String.length prefix) in
    let* address =
      Result.map_error (fun invalid -> Reason.Unmintable invalid)
        (Agent_observation.Code_address.v ~codebase:slug ~path:rel)
    in
    Ok { Agent_observation.address; checkout = Some identity.toplevel }
;;

let resolve ~base_dir ~file_path =
  let observed =
    try resolve_observed ~base_dir ~file_path with
    | Eio.Cancel.Cancelled _ as ex -> raise ex
    | ex ->
      Log.Keeper.warn "write attribution inspection failed: %s" (Printexc.to_string ex);
      Error Reason.Checkout_unavailable
  in
  match observed with
  | Ok addressed -> Agent_observation.Addressed addressed
  | Error reason -> Agent_observation.Unaddressed { reason; attempted_path = file_path }
;;
