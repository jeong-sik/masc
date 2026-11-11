type turn_id = string
type sandbox_path = string

let normalize_path path =
  let rec collapse acc = function
    | [] -> List.rev acc
    | ".." :: rest ->
      (* Preserve fall-through behaviour: when acc is empty (we are at
         the path root), [".."] is treated as a literal segment and
         pushed onto acc.  When acc has at least one element, pop it. *)
      (match acc with
       | [] -> collapse (".." :: acc) rest
       | _ :: tl -> collapse tl rest)
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
                      keeper_turn_sandbox_runtime_run_argv.ml which accepts
                      host_root as a valid sandbox path. When [root_norm] is
                      "/", every absolute path is inside it; using "/"
                      directly as the prefix (instead of "//") avoids the
                      degenerate double-slash that would otherwise reject all
                      non-root paths. *)
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
