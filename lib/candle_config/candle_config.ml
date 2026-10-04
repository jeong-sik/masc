(* See candle_config.mli. *)

type payout_policy = {
  grades : (Candle_grade.t * int * string) list;
  distribution : Candle_math.distribution;
  weight_max : int; deduction_rate : int; deduction_floor : int;
}

let grade_amount_milli policy grade =
  List.find_map (fun (candidate, amount, _) ->
    if candidate = grade then Some amount else None) policy.grades

type policy = {
  payout : payout_policy;
  prices : (Keeper_portrait_item.t * int) list;
  half_life : Candle_decay.half_life;
}
type price = Unpriced | Priced of int
let price policy item =
  match List.assoc_opt item policy.prices with None -> Unpriced | Some amount -> Priced amount

 type t =
  | Off
  | Enabled of policy
  | Disabled of { reason : string }

let table_fields = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Some fields
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> None
;;

let ( let* ) = Result.bind

let exact_table context allowed value =
  match table_fields value with
  | None -> Error (context ^ " must be a table")
  | Some fields ->
    match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
    | Some (key, _) -> Error (context ^ " has unknown key " ^ key)
    | None -> Ok fields

let required context fields key =
  match List.assoc_opt key fields with
  | None -> Error (context ^ "." ^ key ^ " is required")
  | Some value -> Ok value

let integer context fields key low high =
  let* value = required context fields key in
  match value with
  | Otoml.TomlInteger n when n >= low && n <= high -> Ok n
  | Otoml.TomlInteger _ | Otoml.TomlString _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
    Error (Printf.sprintf "%s.%s must be an integer in %d..%d" context key low high)

let payout_of_toml payout =
  let* fields = exact_table "payout"
      ["grades_milli"; "grade_criteria"; "weight_max"; "deduction_rate"; "deduction_floor";
       "share_rounding"; "remainder_tie_break"; "deduction_rounding"] payout in
  let* weight_max = integer "payout" fields "weight_max" 1 max_int in
  let* deduction_rate = integer "payout" fields "deduction_rate" 0 1000 in
  let* deduction_floor = integer "payout" fields "deduction_floor" 0 1000 in
  let choice key choices =
    let* value = required "payout" fields key in
    match value with
    | Otoml.TomlString value ->
      (match List.assoc_opt value choices with
       | Some policy -> Ok policy | None -> Error ("unknown payout." ^ key))
    | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> Error ("payout." ^ key ^ " must be a string") in
  let* share_rounding = choice "share_rounding"
      ["largest_remainder", Candle_math.Largest_remainder; "down", Candle_math.Down] in
  let* tie_break = choice "remainder_tie_break"
      ["name_ascending", Candle_math.Name_ascending; "name_descending", Candle_math.Name_descending] in
  let* deduction_rounding = choice "deduction_rounding"
      ["down", Candle_math.Floor; "up", Candle_math.Ceil] in
  let* raw_grades = required "payout" fields "grades_milli" in
  let* grades = match table_fields raw_grades with
    | Some (_ :: _ as grades) -> Ok grades
    | _ -> Error "payout.grades_milli must be a nonempty table" in
  let* raw_criteria = required "payout" fields "grade_criteria" in
  let names = List.map fst grades in
  let* criteria = exact_table "payout.grade_criteria" names raw_criteria in
  let* grades = List.fold_right (fun (name, _) result ->
    let* result = result in
    let* grade = match Candle_grade.of_string name with
      | Some grade -> Ok grade | None -> Error ("invalid grade identifier: " ^ name) in
    let* amount = integer "payout.grades_milli" grades name 0 max_int in
    let* criterion = required "payout.grade_criteria" criteria name in
    let* criterion = match criterion with
      | Otoml.TomlString text when String.trim text <> "" -> Ok text
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> Error ("payout.grade_criteria." ^ name ^ " must be nonblank text") in
    Ok ((grade, amount, criterion) :: result)) grades (Ok []) in
  Ok {grades; distribution={Candle_math.share_rounding; tie_break; deduction_rounding};
      weight_max; deduction_rate; deduction_floor}

let prices_of_toml shop =
  let* shop = exact_table "shop" ["prices_milli"] shop in
  let* fields = match List.assoc_opt "prices_milli" shop with
    | None -> Ok []
    | Some prices -> exact_table "shop.prices_milli"
        (List.map Keeper_portrait_item.id Keeper_portrait_item.all) prices in
  List.fold_right (fun item result ->
    let* prices = result in
    let key = Keeper_portrait_item.id item in
    match List.assoc_opt key fields with
    | None -> Ok prices
    | Some _ ->
      let* amount = integer "shop.prices_milli" fields key 0 max_int in
      Ok ((item, amount) :: prices)) Keeper_portrait_item.all (Ok [])

let policy_of_toml toml =
  let* root = exact_table "candle.toml" ["payout"; "shop"; "half_life"] toml in
  let* raw_half_life = required "candle.toml" root "half_life" in
  let* half_life = match raw_half_life with
    | Otoml.TomlString "off" -> Ok Candle_decay.Off
    | Otoml.TomlInteger hours -> Candle_decay.half_life_of_hours hours
    | Otoml.TomlString _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
      Error "candle.toml.half_life must be off or positive integer hours" in
  let* payout = required "candle.toml" root "payout" in
  let* payout = payout_of_toml payout in
  let* prices = match List.assoc_opt "shop" root with
    | None -> Ok []
    | Some shop -> prices_of_toml shop in
  Ok {payout;prices;half_life}

let of_toml_string text =
  match Otoml.Parser.from_string_result text with
  | Error message -> Disabled { reason = "candle.toml is not valid TOML: " ^ message }
  | Ok toml ->
    match policy_of_toml toml with
    | Ok policy -> Enabled policy
    | Error reason -> Disabled { reason }
;;

let could_not_be_examined error =
  Disabled
    { reason =
        Printf.sprintf "candle.toml could not be examined: %s" (Unix.error_message error)
    }
;;

(* [Sys.file_exists] answers false for every failed stat, not only for a file
   that is not there, so an enabled Candle would turn off without a word when
   the config directory stopped being searchable. Only ENOENT is absence. [stat]
   follows a link, so a link to a file that is gone also ends in ENOENT. The
   link is there, and the operator wrote it, so that is not absence either. *)
let load_file ~path =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Unix.lstat path with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Off
     | exception Unix.Unix_error (error, _, _) -> could_not_be_examined error
     | (_ : Unix.stats) ->
       Disabled { reason = "candle.toml is a link to a file that does not exist" })
  | exception Unix.Unix_error (error, _, _) -> could_not_be_examined error
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (match In_channel.with_open_bin path In_channel.input_all with
     | text -> of_toml_string text
     | exception Sys_error detail ->
       Disabled { reason = Printf.sprintf "candle.toml could not be read: %s" detail })
  | { Unix.st_kind =
        Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK
    ; _
    } ->
    (* Opening a FIFO waits for a writer, and reading a device may never end.
       Either one would hold up everything that asked. *)
    Disabled { reason = "candle.toml could not be read: it is not a regular file" }
;;

let load ~base_path =
  load_file ~path:(Config_dir_resolver.candle_toml_path_for_base_path ~base_path)
;;

let to_string = function
  | Off -> "candle off (no candle.toml)"
  | Enabled _ -> "candle enabled"
  | Disabled { reason } -> Printf.sprintf "candle disabled: %s" reason
;;
