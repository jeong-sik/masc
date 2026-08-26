(** Runtime skill registry — discover and manage canonical skills at runtime.

    Wraps a [Hashtbl.t] keyed by skill name. Decoding and filesystem effects
    belong to the runtime boundary; the registry owns only CRUD and its JSON
    observation projection.

    Thread-safety note: single-writer assumed (no Eio.Mutex needed).
    The registry is always owned by a single Agent.t instance. *)

type t = { tbl : (string, Skill_document.t) Hashtbl.t }

let create () = { tbl = Hashtbl.create 16 }
let register reg (skill : Skill_document.t) = Hashtbl.replace reg.tbl skill.name skill
let find reg name = Hashtbl.find_opt reg.tbl name
let remove reg name = Hashtbl.remove reg.tbl name

let list reg =
  Hashtbl.fold (fun _name skill acc -> skill :: acc) reg.tbl []
  |> List.sort (fun (a : Skill_document.t) (b : Skill_document.t) ->
    String.compare a.name b.name)
;;

let names reg = list reg |> List.map (fun (s : Skill_document.t) -> s.name)
let count reg = Hashtbl.length reg.tbl
;;

(* ── JSON observation projection ───────────────────────────── *)

let rec extension_value_to_json = function
  | Skill_document.Null -> `Null
  | Boolean value -> `Bool value
  | Number value -> `Float value
  | Text value -> `String value
  | Sequence values -> `List (List.map extension_value_to_json values)
  | Mapping fields ->
    `Assoc
      (List.map
         (fun (key, value) -> key, extension_value_to_json value)
         fields)
;;

let skill_to_json (skill : Skill_document.t) : Yojson.Safe.t =
  let opt_str key = function
    | Some v -> [ key, `String v ]
    | None -> []
  in
  `Assoc
    ([ "name", `String skill.name ]
     @ [ "description", `String skill.description ]
     @ [ "body", `String skill.body ]
     @ opt_str "license" skill.license
     @ opt_str "compatibility" skill.compatibility
     @ opt_str "allowed_tools" skill.allowed_tools
     @ [ ( "metadata"
         , `Assoc
             (List.map
                (fun (key, value) -> key, extension_value_to_json value)
                skill.metadata_values) ) ])
;;

let to_json reg =
  `Assoc
    [ "skills", `List (list reg |> List.map skill_to_json); "count", `Int (count reg) ]
;;
