type origin = {
  scheme : string;
  host : string;
  port : int option;
}

type parse_error =
  | Blank
  | Bad_scheme of string option
  | Missing_host
  | Bad_port
  | Has_userinfo
  | Has_path of string
  | Has_query
  | Has_fragment
  | Has_whitespace

let parse_error_to_string = function
  | Blank -> "origin must not be blank"
  | Bad_scheme None -> "origin must carry an http(s)/ws(s) scheme"
  | Bad_scheme (Some s) -> Printf.sprintf "origin scheme %S is not admitted here" s
  | Missing_host -> "origin must name a host"
  | Bad_port -> "origin port out of range"
  | Has_userinfo -> "origin must not carry userinfo"
  | Has_path p -> Printf.sprintf "origin must not carry a path (%S)" p
  | Has_query -> "origin must not carry a query"
  | Has_fragment -> "origin must not carry a fragment"
  | Has_whitespace -> "origin must not contain whitespace"
;;

let has_inner_whitespace s =
  String.contains s ' ' || String.contains s '\t' || String.contains s '\n' || String.contains s '\r'
;;

let parse ~schemes raw =
  let trimmed = String.trim raw in
  if String.equal trimmed ""
  then Error Blank
  else if has_inner_whitespace trimmed
  then Error Has_whitespace
  else (
    let uri = Uri.of_string trimmed in
    let scheme = Option.map String.lowercase_ascii (Uri.scheme uri) in
    match scheme with
    | None -> Error (Bad_scheme None)
    | Some s when not (List.exists (String.equal s) schemes) ->
      Error (Bad_scheme (Some s))
    | Some scheme -> (
      match Uri.userinfo uri with
      | Some _ -> Error Has_userinfo
      | None -> (
        match Uri.host uri with
        | None -> Error Missing_host
        | Some "" -> Error Missing_host
        | Some host -> (
          (* A colon in the authority with no parsed port is a mangled
             port ("h:", "h:abc"), not an absent one: refuse it rather
             than stripping it. Bracketed literals hold colons of their
             own, so only the text past ']' counts there. *)
          let authority_claims_port =
            (* Past the scheme separator: the "://" slashes are not the
               authority's end. *)
            let scheme_end =
              match String.index_opt trimmed ':' with
              | None -> 0
              | Some c -> c + 3
            in
            let index_from_opt c =
              match String.index_from_opt trimmed scheme_end c with
              | None -> String.length trimmed
              | Some i -> i
            in
            let auth_end =
              min (index_from_opt '/') (min (index_from_opt '?') (index_from_opt '#'))
            in
            let authority =
              if scheme_end >= auth_end
              then ""
              else String.sub trimmed scheme_end (auth_end - scheme_end)
            in
            if String.starts_with ~prefix:"[" authority
            then (
              match String.index_opt authority ']' with
              | None -> false
              | Some close ->
                close + 1 < String.length authority
                && authority.[close + 1] = ':')
            else String.contains authority ':'
          in
          match Uri.port uri with
          | Some p when p < 1 || p > 65535 -> Error Bad_port
          | None when authority_claims_port -> Error Bad_port
          | port -> (
            match Uri.path uri with
            | "" | "/" -> (
              match Uri.verbatim_query uri with
              | Some _ -> Error Has_query
              | None -> (
                match Uri.fragment uri with
                | Some _ -> Error Has_fragment
                | None -> Ok { scheme; host; port }))
            | path -> Error (Has_path path))))))
;;

let to_string { scheme; host; port } =
  let rendered_host =
    match Ipaddr.V6.of_string host with
    | Ok _ -> "[" ^ host ^ "]"
    | Error _ -> host
  in
  let rendered_port =
    match port with
    | None -> ""
    | Some p -> Printf.sprintf ":%d" p
  in
  Printf.sprintf "%s://%s%s" scheme rendered_host rendered_port
;;
