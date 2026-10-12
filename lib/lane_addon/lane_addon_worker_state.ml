type owner = { workspace : string; installation : string; package : string }

let create_owner ~workspace_root ~installation_id ~package_id =
  if String.trim installation_id = "" || String.trim package_id = "" then
    Error "persistent state requires installation and package identities"
  else
    try Ok { workspace = Unix.realpath workspace_root;
             installation = installation_id; package = package_id }
    with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)

let belongs_to owner ~package_id = String.equal owner.package package_id

let identity owner =
  Yojson.Safe.to_string (`List [ `String owner.workspace;
    `String owner.installation; `String owner.package ])

let volume_name owner =
  "masc-lane-state-" ^ Digestif.SHA256.(to_hex (digest_string (identity owner)))

(* Docker reserves a container name atomically, even before start. All writers
   of one logical volume use this slot; worker incarnations still have distinct
   labels so a losing attach cannot remove the winning worker. *)
let container_name owner = volume_name owner ^ "-writer"

let label = "masc.lane.state.owner"
let ( let* ) = Result.bind

let inspect ~run owner =
  let name = volume_name owner in
  let* raw = run ~operation:"inspect persistent state" ["volume"; "inspect"; name] in
  try
    match Yojson.Safe.from_string raw with
    | `List [`Assoc fields] ->
        (match List.assoc_opt "Name" fields, List.assoc_opt "Labels" fields with
         | Some (`String actual), Some (`Assoc labels)
           when String.equal actual name
             && List.assoc_opt label labels = Some (`String (identity owner)) -> Ok ()
         | _ -> Error "persistent state volume belongs to a different owner")
    | _ -> Error "unexpected persistent state volume inspection"
  with Yojson.Json_error message -> Error message

let ensure ~run owner =
  let name = volume_name owner in
  let* raw = run ~operation:"find persistent state"
      ["volume"; "ls"; "--filter"; "name=^" ^ name ^ "$";
       "--format"; "{{json .Name}}"] in
  let* () =
    if String.trim raw = "" then
      let* _ = run ~operation:"create persistent state"
          ["volume"; "create"; "--label"; label ^ "=" ^ identity owner; name] in
      Ok ()
    else
      try match Yojson.Safe.from_string raw with
        | `String actual when String.equal actual name -> Ok ()
        | _ -> Error "ambiguous persistent state volume identity"
      with Yojson.Json_error message -> Error message
  in
  (* Create may race with another owner. Neither its exit status nor a
     deterministic name grants ownership; inspect before granting a mount. *)
  let* () = inspect ~run owner in
  Ok ("type=volume,src=" ^ name ^ ",dst=/state,volume-nocopy")
