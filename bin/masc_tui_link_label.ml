(* What a URL is, said in the words the reader would have used, from the URL
   alone. No fetch: a keeper writes these links, and following one because it
   appeared in a message would make anything a keeper says into a request this
   process sends. The name a GitHub URL carries is already in its path, so for
   the links masc actually trades in there is nothing to ask anyone.

   A link nothing can be said about gets no label rather than a restatement of
   its own host: a line that says "github.com" under a github.com URL costs a
   row and answers nothing. *)

let github_host = "github.com"

let split_path url =
  match String.index_opt url ':' with
  | None -> []
  | Some colon ->
      let rest =
        String.sub url (colon + 1) (String.length url - colon - 1)
      in
      (* Past the "//", then the host, then the path. Empty segments are
         dropped, which is also what removes the "//". *)
      String.split_on_char '/' rest
      |> List.filter (fun segment -> not (String.equal segment ""))

(* Trailing "#L12-L20" and "?w=1" belong to the link, not to the name of the
   thing it points at. *)
let strip_suffix segment =
  let cut_at index = String.sub segment 0 index in
  match (String.index_opt segment '#', String.index_opt segment '?') with
  | Some hash, Some query -> cut_at (min hash query)
  | Some hash, None -> cut_at hash
  | None, Some query -> cut_at query
  | None, None -> segment

let fragment_of segment =
  match String.index_opt segment '#' with
  | None -> None
  | Some hash ->
      let rest =
        String.sub segment (hash + 1) (String.length segment - hash - 1)
      in
      if String.equal rest "" then None else Some rest

(* Seven characters is what git itself prints, and what a commit is called in
   conversation. *)
let short_sha_length = 7

let short_sha sha =
  if String.length sha <= short_sha_length then sha
  else String.sub sha 0 short_sha_length

let label url =
  match split_path url with
  | host :: owner :: repo :: rest when String.equal host github_host -> (
      let repo = strip_suffix repo in
      match rest with
      | [ "pull"; number ] -> Some (Printf.sprintf "%s PR #%s" repo (strip_suffix number))
      | [ "issues"; number ] ->
          Some (Printf.sprintf "%s issue #%s" repo (strip_suffix number))
      | [ "commit"; sha ] ->
          Some (Printf.sprintf "%s commit %s" repo (short_sha (strip_suffix sha)))
      | "actions" :: "runs" :: number :: _ ->
          Some (Printf.sprintf "%s CI run %s" repo (strip_suffix number))
      | "blob" :: _ :: (_ :: _ as path) | "tree" :: _ :: (_ :: _ as path) ->
          (* The file, not the branch it was read on: a reader following this
             wants to know which file. The line range comes with it, since a
             link that carries one is pointing at the range. *)
          let last = List.nth path (List.length path - 1) in
          let name = strip_suffix last in
          Some
            (match fragment_of last with
             | None -> Printf.sprintf "%s %s" repo name
             | Some lines -> Printf.sprintf "%s %s %s" repo name lines)
      | [] -> Some (Printf.sprintf "%s/%s" owner repo)
      | _ -> None)
  | _ -> None
