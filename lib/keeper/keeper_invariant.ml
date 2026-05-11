module StringSet = Set.Make (String)

type turn_id = string
type sandbox_path = string

type credential_scope =
  { keeper_id : string
  ; github_account : string
  }

type tool_name = string

let normalize_path path =
  let rec collapse acc = function
    | [] -> List.rev acc
    | ".." :: rest when acc <> [] -> collapse (List.tl acc) rest
    | "." :: rest -> collapse acc rest
    | "" :: rest -> collapse acc rest
    | segment :: rest -> collapse (segment :: acc) rest
  in
  let parts = String.split_on_char '/' path in
  "/" ^ String.concat "/" (collapse [] parts)
;;

let sandbox_isolation ~sandbox_roots ~sandbox_paths =
  if sandbox_roots = []
  then Error "Sandbox isolation: no sandbox roots configured"
  else (
    match
      List.find_opt
        (fun path ->
           let norm = normalize_path path in
           not
             (List.exists
                (fun root ->
                   let root_norm = normalize_path root in
                   (* A path equal to the sandbox root itself is treated as
                      in-sandbox, matching [container_path_of_host] in
                      keeper_turn_sandbox_runtime.ml which accepts host_root
                      as a valid sandbox path. When [root_norm] is "/", every
                      absolute path is inside it; using "/" directly as the
                      prefix (instead of "//") avoids the degenerate
                      double-slash that would otherwise reject all non-root
                      paths. *)
                   let prefix =
                     if String.equal root_norm "/" then "/" else root_norm ^ "/"
                   in
                   String.equal norm root_norm
                   || String.starts_with ~prefix norm)
                sandbox_roots))
        sandbox_paths
    with
    | Some violating_path ->
      Error
        (Printf.sprintf
           "Sandbox isolation violation: path %s is outside all configured sandbox roots"
           violating_path)
    | None -> Ok ())
;;

let credential_isolation ~keeper:_ ~credential ~other_keepers =
  (* Cross-persona credential isolation: a GitHub account used by one keeper
     must not appear under a different keeper_id. The [~keeper] parameter is
     retained for API stability; the authoritative identity is
     [credential.keeper_id], so a divergent [~keeper] cannot mask a real
     conflict. Same-keeper entries (e.g., a keeper holding multiple github
     accounts, or repeated self-entries) are not violations. *)
  match
    List.find_opt
      (fun other ->
         (not (String.equal other.keeper_id credential.keeper_id))
         && String.equal other.github_account credential.github_account)
      other_keepers
  with
  | Some conflicting ->
    Error
      (Printf.sprintf
         "Credential isolation violation: keeper %s shares GitHub account %s with keeper \
          %s"
         credential.keeper_id
         credential.github_account
         conflicting.keeper_id)
  | None -> Ok ()
;;

let tool_surface_monotonicity ~before ~after =
  let before_set = StringSet.of_list before in
  let after_set = StringSet.of_list after in
  let diff = StringSet.diff after_set before_set in
  if StringSet.is_empty diff
  then Ok ()
  else (
    let added = StringSet.elements diff in
    Error
      (Printf.sprintf
         "Tool surface monotonicity violation: tools added without explicit \
          configuration: %s"
         (String.concat ", " added)))
;;

let check_all
      ~sandbox_roots
      ~sandbox_paths
      ~keeper
      ~credential
      ~other_keepers
      ~before_tools
      ~after_tools
  =
  match sandbox_isolation ~sandbox_roots ~sandbox_paths with
  | Error _ as e -> e
  | Ok () ->
    (match credential_isolation ~keeper ~credential ~other_keepers with
     | Error _ as e -> e
     | Ok () ->
       (match tool_surface_monotonicity ~before:before_tools ~after:after_tools with
        | Error _ as e -> e
        | Ok () -> Ok ()))
;;
