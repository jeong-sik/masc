let store_subdir = ".masc-ide"

let store_path ~base_dir = Filename.concat base_dir store_subdir

let by_url_subdir = "by-url"
let orphan_subdir = "_orphan"

let by_url_path ~base_dir ~canonical_url =
  Filename.concat (Filename.concat (store_path ~base_dir) by_url_subdir) canonical_url
;;

let orphan_path ~base_dir = Filename.concat (store_path ~base_dir) orphan_subdir

(* RFC-0128 §4.1 — canonical URL slug derivation.

   Accepted shapes:
     - https://github.com/owner/repo
     - https://github.com/owner/repo.git
     - http://host/owner/repo
     - ssh://git@host/owner/repo.git
     - git@host:owner/repo.git
     - git@host:owner/repo

   Output: lowercase host + path joined by '_'. Returns None if input is
   empty, lacks host or path, or any segment contains characters outside
   [a-z0-9._-]. The slug is deterministic so the same upstream resolves
   to the same bucket regardless of which transport the remote was
   registered with. *)

let starts_with ~prefix s =
  let n = String.length prefix in
  String.length s >= n && String.sub s 0 n = prefix
;;

let strip_prefix ~prefix s =
  let n = String.length prefix in
  String.sub s n (String.length s - n)
;;

let strip_suffix ~suffix s =
  let ns = String.length s in
  let nf = String.length suffix in
  if ns >= nf && String.sub s (ns - nf) nf = suffix
  then String.sub s 0 (ns - nf)
  else s
;;

let split_host_path s =
  match String.index_opt s '/' with
  | None -> (s, "")
  | Some i ->
    let host = String.sub s 0 i in
    let path = String.sub s (i + 1) (String.length s - i - 1) in
    (host, path)
;;

(* SCP-style "user@host:path" → "host/path". Rewrite only when ':'
   appears before the first '/' (otherwise ':' is path content). *)
let normalize_scp_like s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    let after = String.sub s (at + 1) (String.length s - at - 1) in
    (match String.index_opt after ':' with
     | None -> s
     | Some colon ->
       (match String.index_opt after '/' with
        | Some slash when slash < colon -> s
        | _ ->
          let host = String.sub after 0 colon in
          let path = String.sub after (colon + 1) (String.length after - colon - 1) in
          host ^ "/" ^ path))
;;

let strip_scheme s =
  let candidates = [ "https://"; "http://"; "ssh://"; "git://" ] in
  match List.find_opt (fun p -> starts_with ~prefix:p s) candidates with
  | Some p -> strip_prefix ~prefix:p s
  | None -> s
;;

(* Strip leading "user@" credential when it precedes the host. *)
let strip_userinfo s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    (match String.index_opt s '/' with
     | Some slash when slash < at -> s
     | _ -> String.sub s (at + 1) (String.length s - at - 1))
;;

let is_slug_char c =
  (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'
  || c = '.'
;;

let path_segment_to_slug seg =
  if seg = "" then None
  else if String.length seg >= 2 && String.sub seg 0 2 = ".."
  then None
  else if String.for_all is_slug_char seg
  then Some seg
  else None
;;

let canonical_url_of_remote raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None
  else
    let s = String.lowercase_ascii trimmed in
    let s = normalize_scp_like s in
    let s = strip_scheme s in
    let s = strip_userinfo s in
    let host, path = split_host_path s in
    if host = "" || path = "" then None
    else
      let path = strip_suffix ~suffix:".git" path in
      let segments =
        String.split_on_char '/' path |> List.filter (fun seg -> seg <> "")
      in
      if segments = [] then None
      else
        match path_segment_to_slug host with
        | None -> None
        | Some host_slug ->
          let rec collect acc = function
            | [] -> Some (List.rev acc)
            | seg :: rest ->
              (match path_segment_to_slug seg with
               | None -> None
               | Some s -> collect (s :: acc) rest)
          in
          (match collect [] segments with
           | None -> None
           | Some segs -> Some (String.concat "_" (host_slug :: segs)))
;;
