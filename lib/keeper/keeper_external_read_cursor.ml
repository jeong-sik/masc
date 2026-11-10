module M = Keeper_memory_os_current
open Result.Syntax
type token = Offset of int
type pending =
  { through : int; atom : M.durable_range_id option; official : M.official_range_id option }
type state = { after : int; pending : pending option }
let offset (Offset value) = value
let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat (Filename.concat keepers_dir keeper_id) "librarian-external-read.json"
let path ~runtime_keepers_dir ~keeper_name =
  path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
let optional f = function None -> `Null | Some value -> f value
let json state = `Assoc ["after",`Int state.after; "pending",optional (fun p ->
  `Assoc ["through",`Int p.through; "atom",optional M.durable_range_id_to_json p.atom;
          "official",optional M.official_range_id_to_json p.official]) state.pending]
let decode_value (value : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  try
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
        Some (row |> member "through" |> to_int, opt "atom", opt "official") in
    if after < 0 || Option.fold ~none:false ~some:(fun (through, atom, official) -> through < after
      || (atom=None && official=None)) pending then Error "invalid external read cursor"
    else
      let identity decode = function
        | None -> Ok None
        | Some value ->
          (match decode value with
           | Ok range -> Ok (Some range)
           | Error _ -> Error "invalid external cursor Memory receipt identity") in
      match pending with
      | None -> Ok {after;pending=None}
      | Some (through, atom, official) ->
        let* atom = identity M.durable_range_id_of_json atom in
        let* official = identity M.official_range_id_of_json official in
        Ok {after;pending=Some {through;atom;official}}
  with Yojson.Safe.Util.Type_error (detail,_) -> Error detail
let decode raw =
  try decode_value (Yojson.Safe.from_string raw)
  with Yojson.Json_error detail -> Error detail
let load ~runtime_keepers_dir ~keeper_name =
  try match Fs_compat.load_file_opt (path ~runtime_keepers_dir ~keeper_name) with
    | None -> Ok {after=0;pending=None}
    | Some raw -> decode raw
  with Sys_error detail -> Error detail
     | Unix.Unix_error (e,f,a) -> Error (Printf.sprintf "%s(%s): %s" f a (Unix.error_message e))
type observation = Observed of state
let observe ~runtime_keepers_dir ~keeper_name =
  load ~runtime_keepers_dir ~keeper_name |> Result.map (fun state -> Observed state)
let observation_to_json (Observed state) = json state
let observation_of_json value =
  decode_value value |> Result.map (fun state -> Observed state)
let observation_offset (Observed state) = state.after
let observation_matches_preparation (Observed state) ~after ~through ~atom ~official =
  let same encode left right = Yojson.Safe.equal (optional encode left) (optional encode right) in
  state.after = after && through >= after &&
  match state.pending with
  | None -> through = after
  | Some pending -> through > after && pending.through = through
    && same M.durable_range_id_to_json atom pending.atom
    && same M.official_range_id_to_json official pending.official

let observation_matches_floor_preparation (Observed state) ~after ~through ~atom ~official =
  let without_atom_holes (range : M.durable_range_id) = {range with unread_messages=[]} in
  let without_official_holes (range : M.official_range_id) = {range with unread_messages=[]} in
  match state.pending with
  | None -> false
  | Some pending ->
    state.after = after && pending.through = through && through > after
    && Option.map without_atom_holes atom = Option.map without_atom_holes pending.atom
    && Option.map without_official_holes official = Option.map without_official_holes pending.official

let save ~runtime_keepers_dir ~keeper_name state =
  let file = path ~runtime_keepers_dir ~keeper_name in
  try
    Fs_compat.mkdir_p (Filename.dirname file);
    Fs_compat.save_file_atomic_strict file (Yojson.Safe.to_string (json state))
  with Sys_error detail -> Error detail
     | Unix.Unix_error (e,f,a) -> Error (Printf.sprintf "%s(%s): %s" f a (Unix.error_message e))
let restore_original_preparation ~runtime_keepers_dir ~keeper_name
    ~expected:(Observed expected) ~original:(Observed original) =
  let* current=load ~runtime_keepers_dir ~keeper_name in
  if current<>expected || current.after<>original.after then
    Error "Original external preparation observation or offset changed"
  else if current=original then Ok () else
    let* ()=save ~runtime_keepers_dir ~keeper_name original in
    let* observed=load ~runtime_keepers_dir ~keeper_name in
    if observed=original then Ok () else Error "Original external preparation readback differs"
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
    let* _ = M.committed_unread_messages ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name in
    let atom_scope = match p.atom with
      | Some (range : M.durable_range_id) -> range.receipt_scope
      | None -> runtime_keepers_dir in
    let official_scope = match p.official with
      | Some (range : M.official_range_id) -> range.receipt_scope
      | None -> runtime_keepers_dir in
    let* atom = M.committed_durable_coverage ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name ~receipt_scope:atom_scope in
    let* official = M.committed_official_coverage ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name ~receipt_scope:official_scope in
    let matches encode expected actual = match expected,actual with
      | None,_ -> true | Some a,Some b -> encode a = encode b | Some _,None -> false in
    if matches M.durable_range_id_to_json p.atom atom
       && matches M.official_range_id_to_json p.official official then
      let* () = acknowledge ~runtime_keepers_dir ~keeper_name in Ok (Offset p.through)
    else Ok (Offset state.after)

let require_uncommitted ~memory_keepers_dir ~keeper_name ~atom ~official =
  let* prior_atom = match atom with
    | None -> Ok None
    | Some (range : M.durable_range_id) -> M.committed_durable_coverage
        ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name ~receipt_scope:range.receipt_scope in
  let* prior_official = match official with
    | None -> Ok None
    | Some (range : M.official_range_id) -> M.committed_official_coverage
        ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name ~receipt_scope:range.receipt_scope in
  let same encode requested committed = match requested,committed with
    | Some left,Some right -> encode left = encode right
    | None,_ | Some _,None -> false in
  if same M.durable_range_id_to_json atom prior_atom
     || same M.official_range_id_to_json official prior_official then
    Error "a committed Memory range cannot acknowledge a new external snapshot"
  else Ok ()

let prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name (Offset after) ~through ~atom ~official =
  let* () =
    if through < after then Error "external attention log shrank behind its read cursor"
    else if through > after && atom=None && official=None then
      Error "external read has no Memory commit identity"
    else Ok () in
  let* state = load ~runtime_keepers_dir ~keeper_name in
  (* A committed range cannot name a new advancing snapshot. When another
     preparation is pending, reject an observed committed range before [read]
     can recover its ACK. The second check can catch a later Memory commit
     before saving a new preparation, but cannot undo an ACK by [read]. The
     caller still serializes this Keeper's cursor. *)
  let* () = match state.pending with
    | Some _ when through > after ->
      require_uncommitted ~memory_keepers_dir ~keeper_name ~atom ~official
    | None | Some _ -> Ok () in
  let* current = read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name in
  if offset current <> after then Error "external admission cursor changed before preparation"
  else if through = after then save ~runtime_keepers_dir ~keeper_name {after;pending=None}
  else
    let* () = require_uncommitted ~memory_keepers_dir ~keeper_name ~atom ~official in
    save ~runtime_keepers_dir ~keeper_name
      {after;pending=Some {through;atom;official}}

let inspect ~keepers_dir ~keeper_id =
  let runtime_keepers_dir = keepers_dir and keeper_name = keeper_id in
  let file = path ~runtime_keepers_dir ~keeper_name in
  try match Fs_compat.load_file_opt file with
    | None -> Ok false
    | Some raw -> Result.map (fun _ -> true) (decode raw)
  with Sys_error detail -> Error detail
     | Unix.Unix_error (e,f,a) -> Error (Printf.sprintf "%s(%s): %s" f a (Unix.error_message e))
