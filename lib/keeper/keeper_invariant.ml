open Base

type turn_id = string

type sandbox_path = string

type credential_scope = {
  keeper_id : string;
  github_account : string;
}
[@@deriving sexp, equal]

type tool_name = string

let sandbox_isolation ~turn ~sandbox_paths =
  let expected_prefixes =
    [ "/tmp/masc_sandbox_" ^ turn ^ "/"; "/var/lib/masc/sandbox/" ^ turn ^ "/" ]
  in
  List.find sandbox_paths ~f:(fun path ->
    let norm = Filename.normalize path in
    not
      (List.exists expected_prefixes ~f:(fun prefix ->
         String.is_prefix norm ~prefix)))
  |> Option.map ~f:(fun violating_path ->
       Result.Error
         (Printf.sprintf
            "Sandbox isolation violation: path %s is outside turn %s sandbox"
            violating_path turn))
  |> Option.value ~default:(Result.Ok ())

let credential_isolation ~keeper ~credential ~other_keepers =
  List.find other_keepers ~f:(fun other ->
    String.equal other.keeper_id keeper
    && String.equal other.github_account credential.github_account)
  |> Option.map ~f:(fun conflicting ->
       Result.Error
         (Printf.sprintf
            "Credential isolation violation: keeper %s shares GitHub account %s with \
             keeper %s"
            keeper credential.github_account conflicting.keeper_id))
  |> Option.value ~default:(Result.Ok ())

let tool_surface_monotonicity ~before ~after =
  let before_set = String.Set.of_list before in
  let after_set = String.Set.of_list after in
  let diff = Set.diff after_set before_set in
  if Set.is_empty diff then Result.Ok ()
  else
    let added = Set.to_list diff in
    Result.Error
      (Printf.sprintf
         "Tool surface monotonicity violation: tools added without explicit \
          configuration: %s"
         (String.concat ~sep:", " added))

let check_all ~turn ~sandbox_paths ~keeper ~credential ~other_keepers ~before_tools
  ~after_tools
  =
  let ( let* ) = Result.( >>= ) in
  let* () = sandbox_isolation ~turn ~sandbox_paths in
  let* () = credential_isolation ~keeper ~credential ~other_keepers in
  let* () = tool_surface_monotonicity ~before:before_tools ~after:after_tools in
  Result.Ok ()
