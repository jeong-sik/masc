(* See candle_config.mli. *)

type payout_policy = {
  trivial_milli : int; small_milli : int; medium_milli : int;
  large_milli : int; epic_milli : int;
  weight_max : int; deduction_rate : int; deduction_floor : int;
}

let grade_amount_milli policy = function
 | Candle_grade.Trivial -> policy.trivial_milli
 | Small -> policy.small_milli | Medium -> policy.medium_milli
 | Large -> policy.large_milli | Epic -> policy.epic_milli

 type t =
  | Off
  | Enabled of payout_policy
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
  | _ -> Error (Printf.sprintf "%s.%s must be an integer in %d..%d" context key low high)

let policy_of_toml toml =
  let* root = exact_table "candle.toml" ["payout"] toml in
  let* payout = required "candle.toml" root "payout" in
  let* fields = exact_table "payout"
      ["grades_milli"; "weight_max"; "deduction_rate"; "deduction_floor"] payout in
  let* weight_max = integer "payout" fields "weight_max" 1 max_int in
  let* deduction_rate = integer "payout" fields "deduction_rate" 0 1000 in
  let* deduction_floor = integer "payout" fields "deduction_floor" 0 1000 in
  let* grades = required "payout" fields "grades_milli" in
  let* grades = exact_table "payout.grades_milli"
      (List.map Candle_grade.to_string Candle_grade.all) grades in
  let amount grade = integer "payout.grades_milli" grades (Candle_grade.to_string grade)
      0 (min (max_int / weight_max) (max_int / 1000)) in
  let* trivial_milli = amount Candle_grade.Trivial in
  let* small_milli = amount Candle_grade.Small in
  let* medium_milli = amount Candle_grade.Medium in
  let* large_milli = amount Candle_grade.Large in
  let* epic_milli = amount Candle_grade.Epic in
  Ok {trivial_milli; small_milli; medium_milli; large_milli; epic_milli;
      weight_max; deduction_rate; deduction_floor}

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
