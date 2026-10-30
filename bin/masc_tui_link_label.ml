(* What a URL is, said in the words the reader would have used, from the URL
   alone. No fetch: a keeper writes these links, and following one because it
   appeared in a message would make anything a keeper says into a request this
   process sends. The name a GitHub URL carries is already in its path, so for
   the links masc actually trades in there is nothing to ask anyone.

   A link nothing can be said about gets no label rather than a restatement of
   its own host: a line that says "github.com" under a github.com URL costs a
   row and answers nothing. *)

let github_host = "github.com"

let is_web_scheme = function
  | Some ("http" | "https") -> true
  | Some _ | None -> false

let path_segments uri =
  (* [Uri.path] keeps percent encoding, so an encoded slash stays inside its
     segment rather than becoming another level in the GitHub route. *)
  Uri.path uri
  |> String.split_on_char '/'
  |> List.filter (fun segment -> not (String.equal segment ""))

(* Seven characters is what git itself prints, and what a commit is called in
   conversation. *)
let short_sha_length = 7

let short_sha sha =
  if String.length sha <= short_sha_length then sha
  else String.sub sha 0 short_sha_length

let label url =
  let uri = Uri.of_string url in
  match (Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.port uri) with
  | scheme, Some host, None, None
    when is_web_scheme scheme && String.equal host github_host -> (
    match path_segments uri with
    | owner :: repo :: rest -> (
      match rest with
      | [ "pull"; number ] -> Some (Printf.sprintf "%s PR #%s" repo number)
      | [ "issues"; number ] ->
          Some (Printf.sprintf "%s issue #%s" repo number)
      | [ "commit"; sha ] ->
          Some (Printf.sprintf "%s commit %s" repo (short_sha sha))
      | "actions" :: "runs" :: number :: _ ->
          Some (Printf.sprintf "%s CI run %s" repo number)
      | "blob" :: _ :: (_ :: _ as path) | "tree" :: _ :: (_ :: _ as path) ->
          (* The file, not the branch it was read on: a reader following this
             wants to know which file. The line range comes with it, since a
             link that carries one is pointing at the range. *)
          let last = List.nth path (List.length path - 1) in
          Some
            (match Uri.fragment uri with
             | None -> Printf.sprintf "%s %s" repo last
             | Some lines -> Printf.sprintf "%s %s %s" repo last lines)
      | [] -> Some (Printf.sprintf "%s/%s" owner repo)
      | _ -> None)
    | _ -> None)
  | _ -> None
