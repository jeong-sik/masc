type turn_id = string

type sandbox_path = string

type credential_scope = {
  keeper_id : string;
  github_account : string;
}
[@@deriving eq]

type tool_name = string

let sandbox_isolation ~turn ~sandbox_paths =
  let expected_prefixes =
    [ "/tmp/masc_sandbox_" ^ turn ^ "/"; "/var/lib/masc/sandbox/" ^ turn ^ "/" ]
  in
  match
    List.find_opt
      (fun path ->
        not
          (List.exists
             (fun prefix -> String.starts_with ~prefix path)
             expected_prefixes))
      sandbox_paths
  with
  | Some violating_path ->
      Result.Error
        (Printf.sprintf
           "Sandbox isolation violation: path %s is outside turn %s sandbox"
           violating_path turn)
  | None -> Result.Ok ()

let credential_isolation ~keeper ~credential ~other_keepers =
  match
    List.find_opt
      (fun other ->
        other.keeper_id = keeper
        && other.github_account = credential.github_account)
      other_keepers
  with
  | Some conflicting ->
      Result.Error
        (Printf.sprintf
           "Credential isolation violation: keeper %s shares GitHub account %s with \
            keeper %s"
           keeper credential.github_account conflicting.keeper_id)
  | None -> Result.Ok ()

let tool_surface_monotonicity ~before ~after =
  let before_set = List.sort_uniq String.compare before in
  let added = List.filter (fun t -> not (List.mem t before_set)) after in
  match added with
  | [] -> Result.Ok ()
  | _ ->
      Result.Error
        (Printf.sprintf
           "Tool surface monotonicity violation: tools added without explicit \
            configuration: %s"
           (String.concat ", " added))

let check_all ~turn ~sandbox_paths ~keeper ~credential ~other_keepers ~before_tools
    ~after_tools
  =
  let ( let* ) = Result.bind in
  let* () = sandbox_isolation ~turn ~sandbox_paths in
  let* () = credential_isolation ~keeper ~credential ~other_keepers in
  let* () = tool_surface_monotonicity ~before:before_tools ~after:after_tools in
  Result.Ok ()
