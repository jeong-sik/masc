module M = Keeper_memory_os_current
let ( let* ) = Result.bind
type token = Offset of int
type pending = { through : int; atom : Yojson.Safe.t option; official : Yojson.Safe.t option }
type state = { after : int; pending : pending option }
let offset (Offset value) = value
let path ~runtime_keepers_dir ~keeper_name =
  Filename.concat (Filename.concat runtime_keepers_dir keeper_name) "librarian-external-read.json"
let optional f = function None -> `Null | Some value -> f value
let json state = `Assoc ["after",`Int state.after; "pending",optional (fun p ->
  `Assoc ["through",`Int p.through; "atom",optional Fun.id p.atom;
          "official",optional Fun.id p.official]) state.pending]
let decode raw =
  let open Yojson.Safe.Util in
  try
    let value = Yojson.Safe.from_string raw in
    let keys expected = function
      | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare expected -> ()
      | value -> raise (Type_error ("unexpected external cursor fields",value)) in
    keys ["after";"pending"] value;
    let after = value |> member "after" |> to_int in
    let pending = match member "pending" value with
      | `Null -> None
      | row ->
        keys ["through";"atom";"official"] row;
        let opt key = match member key row with `Null -> None | value -> Some value in
        Some { through=row |> member "through" |> to_int; atom=opt "atom"; official=opt "official" } in
    if after < 0 || Option.fold ~none:false ~some:(fun p -> p.through < after
      || (p.atom=None && p.official=None)) pending then Error "invalid external read cursor"
    else Ok {after;pending}
  with Yojson.Json_error detail -> Error detail
     | Yojson.Safe.Util.Type_error (detail,_) -> Error detail
let load ~runtime_keepers_dir ~keeper_name =
  try match Fs_compat.load_file_opt (path ~runtime_keepers_dir ~keeper_name) with
    | None -> Ok {after=0;pending=None}
    | Some raw -> decode raw
  with Sys_error detail -> Error detail
     | Unix.Unix_error (e,f,a) -> Error (Printf.sprintf "%s(%s): %s" f a (Unix.error_message e))
let save ~runtime_keepers_dir ~keeper_name state =
  let file = path ~runtime_keepers_dir ~keeper_name in
  try
    Fs_compat.mkdir_p (Filename.dirname file);
    Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (json state))
  with Sys_error detail -> Error detail
     | Unix.Unix_error (e,f,a) -> Error (Printf.sprintf "%s(%s): %s" f a (Unix.error_message e))
let acknowledge ~runtime_keepers_dir ~keeper_name =
  let* state = load ~runtime_keepers_dir ~keeper_name in
  match state.pending with
  | None -> Ok ()
  | Some p -> save ~runtime_keepers_dir ~keeper_name {after=p.through;pending=None}
let read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name =
  let* state = load ~runtime_keepers_dir ~keeper_name in
  match state.pending with
  | None -> Ok (Offset state.after)
  | Some p ->
    let scope = function
      | Some (`Assoc fields) ->
        (match List.assoc_opt "receipt_scope" fields with
         | Some (`String value) -> Ok value
         | _ -> Error "external read receipt has no scope")
      | Some _ -> Error "external read receipt is not an object"
      | None -> Ok runtime_keepers_dir in
    let* atom_scope = scope p.atom in
    let* official_scope = scope p.official in
    let* atom = M.committed_durable_range ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name ~receipt_scope:atom_scope in
    let* official = M.committed_official_range ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name ~receipt_scope:official_scope in
    let matches expected actual = match expected,actual with
      | None,_ -> true | Some a,Some b -> a=b | Some _,None -> false in
    if matches p.atom (Option.map M.durable_range_id_to_json atom)
       && matches p.official (Option.map M.official_range_id_to_json official) then
      let* () = acknowledge ~runtime_keepers_dir ~keeper_name in Ok (Offset p.through)
    else Ok (Offset state.after)
let prepare ~runtime_keepers_dir ~keeper_name (Offset after) ~through ~atom ~official =
  if through < after then Error "external attention log shrank behind its read cursor"
  else if through = after then save ~runtime_keepers_dir ~keeper_name {after;pending=None}
  else if atom=None && official=None then Error "external read has no Memory commit identity"
  else save ~runtime_keepers_dir ~keeper_name
    {after;pending=Some {through;atom=Option.map M.durable_range_id_to_json atom;
                        official=Option.map M.official_range_id_to_json official}}
