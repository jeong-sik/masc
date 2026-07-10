open Repo_manager_types

module type Store = sig
  val load_all : base_path:string -> (repository list, string) result
  val local_path : base_path:string -> repository -> string
end

let strip_trailing_slash s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s

let is_path_prefix ~prefix path =
  let prefix = strip_trailing_slash prefix in
  let plen = String.length prefix in
  if plen = 0 then false
  else if String.length path = plen && String.equal path prefix then true
  else
    String.length path > plen
    && String.equal (String.sub path 0 plen) prefix
    && Char.equal path.[plen] '/'

let rel_under_path ~prefix path =
  let prefix = strip_trailing_slash prefix in
  let plen = String.length prefix in
  if String.length path = plen then ""
  else String.sub path (plen + 1) (String.length path - plen - 1)

let longest_local_path = function
  | [] -> None
  | first :: rest ->
      Some
        (List.fold_left
           (fun ((_, best_local, _) as best) ((_, local, _) as candidate) ->
             if String.length local > String.length best_local then candidate
             else best)
           first rest)

let repository_identity_tokens (repo : repository) =
  repo.id :: repo.name :: repo.aliases
  |> List.map String.trim
  |> List.filter (fun token -> not (String.equal token ""))
  |> List.sort_uniq String.compare

let repository_matches_identity token repo =
  List.exists (String.equal token) (repository_identity_tokens repo)

let unique_repository_by_identity token repos =
  match List.filter (repository_matches_identity token) repos with
  | [ repo ] -> Some repo
  | [] | _ :: _ :: _ -> None

module Make (Store : Store) = struct
  let find_url_by_id ~base_path id =
    match Store.load_all ~base_path with
    | Error _ -> None
    | Ok repos -> (
        match
          List.find_opt
            (fun (repo : repository) -> String.equal repo.id id)
            repos
        with
        | Some repo when not (String.equal repo.url "") -> Some repo.url
        | Some _ | None -> None)

  let find_url_by_identity ~base_path token =
    match Store.load_all ~base_path with
    | Error _ -> None
    | Ok repos -> (
        match unique_repository_by_identity (String.trim token) repos with
        | Some repo when not (String.equal repo.url "") -> Some repo.url
        | Some _ | None -> None)

  let find_repo_by_path_prefix ~base_path abs_path =
    match Store.load_all ~base_path with
    | Error _ -> None
    | Ok repos ->
        let candidates =
          List.filter_map
            (fun (repo : repository) ->
              let local = Store.local_path ~base_path repo in
              if is_path_prefix ~prefix:local abs_path then
                Some (repo, local, rel_under_path ~prefix:local abs_path)
              else None)
            repos
        in
        candidates
        |> longest_local_path
        |> Option.map (fun (repo, _, rel) -> (repo, rel))
end
