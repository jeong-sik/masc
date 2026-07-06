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

module Make (Store : Store) = struct
  let find_url_by_id_result ~base_path id =
    match Store.load_all ~base_path with
    | Error msg -> Error msg
    | Ok repos -> (
        match
          List.find_opt
            (fun (repo : repository) -> String.equal repo.id id)
            repos
        with
        | Some repo when not (String.equal repo.url "") -> Ok (Some repo.url)
        | Some _ | None -> Ok None)

  let find_url_by_id ~base_path id =
    match find_url_by_id_result ~base_path id with
    | Ok value -> value
    | Error msg ->
      Log.Misc.warn
        "Repo_store.find_url_by_id failed to read repository store: base_path=%S id=%S error=%s"
        base_path id msg;
      None

  let find_repo_by_path_prefix_result ~base_path abs_path =
    match Store.load_all ~base_path with
    | Error msg -> Error msg
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
        |> fun value -> Ok value

  let find_repo_by_path_prefix ~base_path abs_path =
    match find_repo_by_path_prefix_result ~base_path abs_path with
    | Ok value -> value
    | Error msg ->
      Log.Misc.warn
        "Repo_store.find_repo_by_path_prefix failed to read repository store: base_path=%S path=%S error=%s"
        base_path abs_path msg;
      None
end
