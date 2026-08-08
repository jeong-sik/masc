(** Runtime skill registry — discover and manage skills at runtime.

    Wraps a [Hashtbl.t] keyed by skill name.  Unlike {!Skill} which is
    pure data, the registry provides CRUD, bulk loading from a directory,
    and JSON round-trip for persistence / agent card export.

    Thread-safety note: single-writer assumed (no Eio.Mutex needed).
    The registry is always owned by a single Agent.t instance. *)

type t = { tbl : (string, Skill.t) Hashtbl.t }

let create () = { tbl = Hashtbl.create 16 }
let register reg (skill : Skill.t) = Hashtbl.replace reg.tbl skill.name skill
let find reg name = Hashtbl.find_opt reg.tbl name
let remove reg name = Hashtbl.remove reg.tbl name

let list reg =
  Hashtbl.fold (fun _name skill acc -> skill :: acc) reg.tbl []
  |> List.sort (fun (a : Skill.t) (b : Skill.t) -> String.compare a.name b.name)
;;

let names reg = list reg |> List.map (fun (s : Skill.t) -> s.name)
let count reg = Hashtbl.length reg.tbl

let load_from_dir reg ?scope dir =
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then
    Error
      (Error.Io
         (FileOpFailed
            { op = "load_from_dir"; path = dir; detail = "directory does not exist" }))
  else (
    let skills = Skill.load_dir ?scope dir in
    List.iter (fun skill -> register reg skill) skills;
    Ok (List.length skills))
;;

(* ── JSON round-trip ───────────────────────────────────────── *)

let skill_to_json (skill : Skill.t) : Yojson.Safe.t =
  let opt_str key = function
    | Some v -> [ key, `String v ]
    | None -> []
  in
  let opt_scope key = function
    | Some s -> [ key, `String (Skill.show_scope s) ]
    | None -> []
  in
  `Assoc
    ([ "name", `String skill.name ]
     @ opt_str "description" skill.description
     @ [ "body", `String skill.body ]
     @ opt_str "path" skill.path
     @ opt_scope "scope" skill.scope
     @ (match skill.allowed_tools with
        | [] -> []
        | tools -> [ "allowed_tools", Util.json_of_string_list tools ])
     @ opt_str "argument_hint" skill.argument_hint
     @ opt_str "model" skill.model
     @
     match skill.supporting_files with
     | [] -> []
     | files -> [ "supporting_files", Util.json_of_string_list files ])
;;

let to_json reg =
  `Assoc
    [ "skills", `List (list reg |> List.map skill_to_json); "count", `Int (count reg) ]
;;

let skill_of_json (json : Yojson.Safe.t) : (Skill.t, Error.sdk_error) result =
  let open Yojson.Safe.Util in
  try
    let name = json |> member "name" |> to_string in
    let description =
      match json |> member "description" with
      | `Null -> None
      | v -> Some (to_string v)
    in
    let body = json |> member "body" |> to_string in
    let path =
      match json |> member "path" with
      | `Null -> None
      | v -> Some (to_string v)
    in
    let scope = None in
    (* scope is informational; not round-tripped *)
    let allowed_tools =
      match json |> member "allowed_tools" with
      | `Null -> []
      | `List items -> Util.string_list_of_json items
      | _ -> []
    in
    let argument_hint =
      match json |> member "argument_hint" with
      | `Null -> None
      | v -> Some (to_string v)
    in
    let model =
      match json |> member "model" with
      | `Null -> None
      | v -> Some (to_string v)
    in
    let supporting_files =
      match json |> member "supporting_files" with
      | `Null -> []
      | `List items -> Util.string_list_of_json items
      | _ -> []
    in
    Ok
      { Skill.name
      ; description
      ; body
      ; path
      ; scope
      ; allowed_tools
      ; argument_hint
      ; model
      ; supporting_files
      ; metadata = []
      }
  with
  | Type_error (msg, _) ->
    Error (Error.Internal (Printf.sprintf "Skill_registry.skill_of_json: %s" msg))
;;

let of_json (json : Yojson.Safe.t) : (t, Error.sdk_error) result =
  let open Yojson.Safe.Util in
  try
    let skills_json = json |> member "skills" |> to_list in
    let reg = create () in
    let rec load = function
      | [] -> Ok reg
      | j :: rest ->
        (match skill_of_json j with
         | Ok skill ->
           register reg skill;
           load rest
         | Error _ as err -> err)
    in
    load skills_json
  with
  | Type_error (msg, _) ->
    Error (Error.Internal (Printf.sprintf "Skill_registry.of_json: %s" msg))
;;
