(* Fusion 설정 작성기 (구현). 계약: fusion_config_writer.mli *)

module E = Toml_line_editor

type error =
  | Preset_absent of string
  | Preset_exists of string
  | Unaddressable_preset of string

let error_message = function
  | Preset_absent name -> Printf.sprintf "preset %s does not exist" name
  | Preset_exists name -> Printf.sprintf "preset %s already exists" name
  | Unaddressable_preset name ->
    Printf.sprintf
      "preset %s is not one [fusion.presets.%s] table with only its panels and judges \
       entries right below it; edit it in the raw runtime.toml"
      name name
;;

type settings =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  }

(* ── line classification ─────────────────────────────────────────────── *)

type line_kind =
  | Header of E.header
  | Key of string
  | Comment
  | Blank
  | Data  (** inside a value opened on an earlier line, or no structure at all *)

let is_blank line = String.equal (String.trim line) ""

let is_comment line =
  let trimmed = String.trim line in
  String.length trimmed > 0 && Char.equal trimmed.[0] '#'
;;

(* A header, key or comment counts only on a structural line: the same text
   inside a triple-quoted prompt is data. *)
let classify lines =
  List.map2
    (fun structural line ->
       if not structural
       then Data
       else (
         match E.header_of_line line with
         | Some header -> Header header
         | None ->
           if is_blank line
           then Blank
           else if is_comment line
           then Comment
           else (
             match E.key_of_line line with
             | Some key -> Key key
             | None -> Data)))
    (E.structural_lines lines)
    lines
;;

let header_path = function
  | E.Table path | E.Table_array path -> path
;;

let rec has_prefix ~prefix path =
  match prefix, path with
  | [], _ -> true
  | expected :: prefix, segment :: path ->
    String.equal expected segment && has_prefix ~prefix path
  | _ :: _, [] -> false
;;

let preset_path name = [ "fusion"; "presets"; name ]
let panels_path name = preset_path name @ [ "panels" ]
let judges_path name = preset_path name @ [ "judges" ]

let render_path path = String.concat "." (List.map E.render_key path)
let table_header path = "[" ^ render_path path ^ "]"
let table_array_header path = "[[" ^ render_path path ^ "]]"

(* ── the preset region ─────────────────────────────────────────────────── *)

(* [\[start, stop)]: [start] is the preset header. The region runs to the next
   header outside the preset, minus the comments and blanks right above that
   header, which document it. *)
type region =
  { start : int
  ; stop : int
  }

let find_region kinds name =
  let prefix = preset_path name in
  let count = Array.length kinds in
  let rec find_header index =
    if index >= count
    then None
    else (
      match kinds.(index) with
      | Header (E.Table path) when List.equal String.equal path prefix -> Some index
      | Header _ | Key _ | Comment | Blank | Data -> find_header (index + 1))
  in
  match find_header 0 with
  | None -> None
  | Some start ->
    let rec find_next index =
      if index >= count
      then count
      else (
        match kinds.(index) with
        | Header header when not (has_prefix ~prefix (header_path header)) -> index
        | Header _ | Key _ | Comment | Blank | Data -> find_next (index + 1))
    in
    let rec back index =
      if index > start + 1
      then (
        match kinds.(index - 1) with
        | Comment | Blank -> back (index - 1)
        | Header _ | Key _ | Data -> index)
      else index
    in
    Some { start; stop = back (find_next (start + 1)) }
;;

(* A preset the region cannot hold: a header under the preset outside the
   region, or a sub-table the loader does not read. Editing around either would
   leave half the preset behind. *)
let region_is_whole kinds region name =
  let prefix = preset_path name in
  let inside index = index >= region.start && index < region.stop in
  let ok = ref true in
  Array.iteri
    (fun index kind ->
       match kind with
       | Header header when has_prefix ~prefix (header_path header) ->
         if not (inside index)
         then ok := false
         else (
           match header with
           | E.Table path when List.equal String.equal path prefix -> ()
           | E.Table_array path
             when List.equal String.equal path (panels_path name)
                  || List.equal String.equal path (judges_path name) -> ()
           | E.Table _ | E.Table_array _ -> ok := false)
       | Header _ | Key _ | Comment | Blank | Data -> ())
    kinds;
  !ok
;;

let preset_declared content name =
  match Otoml.Parser.from_string content with
  | exception Otoml.Parse_error _ -> false
  | toml -> Option.is_some (Otoml.find_opt toml Fun.id (preset_path name))
;;

(* ── comment anchors ───────────────────────────────────────────────────── *)

type section =
  | Preset_body
  | Panel_entry of string
  | Judge_entry of string

type anchor =
  | Key_in of section * string
  | Entry_head of section

let panel_entry_id (group : Fusion_policy.panel_group) =
  match group.label, group.models with
  | "", first :: _ -> first
  | label, _ -> label
;;

let judge_entry_id (judge : Fusion_policy.judge_spec) =
  Fusion_policy.panelist_id ~label:judge.jlabel ~model:judge.jmodel
;;

(* An entry is recognised by what it names, read from its own body. A body the
   parser refuses has no identity, and its comments are not carried. *)
let entry_section ~judges body =
  match Otoml.Parser.from_string (String.concat "\n" body) with
  | exception Otoml.Parse_error _ -> None
  | toml ->
    let text key = Otoml.find_or ~default:"" toml Otoml.get_string [ key ] in
    (match judges with
     | true ->
       Some
         (Judge_entry (Fusion_policy.panelist_id ~label:(text "label") ~model:(text "model")))
     | false ->
       let models =
         Otoml.find_or ~default:[] toml (Otoml.get_array Otoml.get_string) [ "panel" ]
       in
       Some
         (Panel_entry
            (panel_entry_id
               { Fusion_policy.models
               ; label = text "label"
               ; system_prompt = ""
               ; web_tools = false
               ; max_output_tokens = None
               ; timeout_s = None
               })))
;;

(* The comment block above [index]: comments and the blank lines between them,
   back to the previous key, header or value line. A comment separated from its
   key by a blank line still belongs to that key; dropping it would lose the
   note. Blank lines before the first comment are the previous element's
   spacing, not part of the block. *)
let comments_above lines kinds ~floor index =
  let rec collect acc position =
    if position <= floor
    then acc
    else (
      match kinds.(position - 1) with
      | Comment | Blank -> collect (lines.(position - 1) :: acc) (position - 1)
      | Header _ | Key _ | Data -> acc)
  in
  let rec drop_leading_blanks = function
    | line :: rest when is_blank line -> drop_leading_blanks rest
    | block -> block
  in
  let block = drop_leading_blanks (collect [] index) in
  if List.exists is_comment block then block else []
;;

let collect_anchors lines kinds region name =
  let entry_body start =
    let rec take index acc =
      if index >= region.stop
      then List.rev acc
      else (
        match kinds.(index) with
        | Header _ -> List.rev acc
        | Key _ | Comment | Blank | Data -> take (index + 1) (lines.(index) :: acc))
    in
    take (start + 1) []
  in
  let floor = region.start in
  let rec walk index section acc =
    if index >= region.stop
    then acc
    else (
      match kinds.(index) with
      | Header (E.Table_array path) ->
        let judges = List.equal String.equal path (judges_path name) in
        let section = entry_section ~judges (entry_body index) in
        let acc =
          match section with
          | Some section ->
            (Entry_head section, comments_above lines kinds ~floor index) :: acc
          | None -> acc
        in
        walk (index + 1) section acc
      | Key key ->
        let acc =
          match section with
          | Some section -> (Key_in (section, key), comments_above lines kinds ~floor index) :: acc
          | None -> acc
        in
        walk (index + 1) section acc
      | Header (E.Table _) | Comment | Blank | Data -> walk (index + 1) section acc)
  in
  walk (region.start + 1) (Some Preset_body) []
;;

let comments_for anchors anchor =
  match List.assoc_opt anchor anchors with
  | Some comments -> comments
  | None -> []
;;

(* ── rendering ─────────────────────────────────────────────────────────── *)

(* A multi-line basic string. The newline right after the opening delimiter is
   not part of the value, so the value reads back exactly as given. A quote is
   escaped wherever it stands, which keeps a run of three from closing early. *)
let multiline_string_lines ~key text =
  let buffer = Buffer.create (String.length text + 16) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\n' -> Buffer.add_char buffer '\n'
      | '\t' -> Buffer.add_char buffer '\t'
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
        Buffer.add_string buffer (Printf.sprintf "\\u%04X" (Char.code c))
      | c -> Buffer.add_char buffer c)
    text;
  String.split_on_char '\n'
    (E.render_key key ^ " = \"\"\"\n" ^ Buffer.contents buffer ^ "\"\"\"")
;;

let string_lines ~key text =
  if String.contains text '\n'
  then multiline_string_lines ~key text
  else [ E.value_line ~key ~value:(E.String text) ]
;;

let string_array_lines ~key values =
  (E.render_key key ^ " = [")
  :: List.map (fun value -> "  \"" ^ E.escape_string value ^ "\",") values
  @ [ "]" ]
;;

let optional_line ~key render = function
  | None -> []
  | Some value -> [ E.value_line ~key ~value:(render value) ]
;;

let int_line ~key value = [ E.value_line ~key ~value:(E.Int value) ]
let bool_line ~key value = [ E.value_line ~key ~value:(E.Bool value) ]
let float_value value = E.Float value
let int_value value = E.Int value

let render_preset ~header_line ~anchors (preset : Fusion_policy.preset) =
  let keyed section key lines =
    match lines with
    | [] -> []
    | _ :: _ -> comments_for anchors (Key_in (section, key)) @ lines
  in
  let group_keys section (group : Fusion_policy.panel_group) =
    keyed section "panel" (string_array_lines ~key:"panel" group.models)
    @ keyed section "panel_system_prompt"
        (string_lines ~key:"panel_system_prompt" group.system_prompt)
    @ keyed section "web_tools" (bool_line ~key:"web_tools" group.web_tools)
    @ keyed section "max_output_tokens_per_panel"
        (optional_line ~key:"max_output_tokens_per_panel" int_value group.max_output_tokens)
    @ keyed section "panel_timeout_s"
        (optional_line ~key:"panel_timeout_s" float_value group.timeout_s)
  in
  let flat_group =
    match preset.panels with
    | [ group ] when String.equal group.label "" -> Some group
    | [] | _ :: _ -> None
  in
  let judge_keys =
    keyed Preset_body "judge" (string_lines ~key:"judge" preset.judge)
    @ keyed Preset_body "judge_system_prompt"
        (string_lines ~key:"judge_system_prompt" preset.judge_system_prompt)
    @ keyed Preset_body "judge_max_output_tokens"
        (optional_line ~key:"judge_max_output_tokens" int_value preset.judge_max_output_tokens)
    @ keyed Preset_body "judge_timeout_s"
        (optional_line ~key:"judge_timeout_s" float_value preset.judge_timeout_s)
    @ keyed Preset_body "min_answered" (int_line ~key:"min_answered" preset.min_answered)
  in
  let panel_entries =
    match flat_group with
    | Some _ -> []
    | None ->
      List.concat_map
        (fun (group : Fusion_policy.panel_group) ->
           let section = Panel_entry (panel_entry_id group) in
           ("" :: comments_for anchors (Entry_head section))
           @ [ table_array_header (panels_path preset.name) ]
           @ (if String.equal group.label ""
              then []
              else keyed section "label" (string_lines ~key:"label" group.label))
           @ group_keys section group)
        preset.panels
  in
  let judge_entries =
    List.concat_map
      (fun (judge : Fusion_policy.judge_spec) ->
         let section = Judge_entry (judge_entry_id judge) in
         ("" :: comments_for anchors (Entry_head section))
         @ [ table_array_header (judges_path preset.name) ]
         @ keyed section "model" (string_lines ~key:"model" judge.jmodel)
         @ (if String.equal judge.jlabel ""
            then []
            else keyed section "label" (string_lines ~key:"label" judge.jlabel))
         @ keyed section "system_prompt" (string_lines ~key:"system_prompt" judge.jsystem_prompt)
         @ keyed section "web_tools" (bool_line ~key:"web_tools" judge.jweb_tools)
         @ keyed section "max_output_tokens"
             (optional_line ~key:"max_output_tokens" int_value judge.jmax_output_tokens)
         @ keyed section "timeout_s" (optional_line ~key:"timeout_s" float_value judge.jtimeout_s))
      preset.judges
  in
  (header_line
   :: (match flat_group with
       | Some group -> group_keys Preset_body group
       | None -> []))
  @ judge_keys
  @ panel_entries
  @ judge_entries
;;

(* ── edits ─────────────────────────────────────────────────────────────── *)

let splice lines ~start ~stop replacement =
  let before, rest = E.split_at start lines in
  let _, after = E.split_at (stop - start) rest in
  before @ replacement @ after
;;

let join lines = E.join_lines lines ~trailing_newline:true

(* Where a new preset goes: after the last region whose header sits under
   [fusion], so the section stays together; at the end of the file when there is
   no [fusion] table at all. *)
let insertion_index kinds =
  let count = Array.length kinds in
  let last_fusion = ref None in
  Array.iteri
    (fun index kind ->
       match kind with
       | Header header when has_prefix ~prefix:[ "fusion" ] (header_path header) ->
         last_fusion := Some index
       | Header _ | Key _ | Comment | Blank | Data -> ())
    kinds;
  match !last_fusion with
  | None -> count
  | Some header ->
    let rec find_next index =
      if index >= count
      then count
      else (
        match kinds.(index) with
        | Header header when not (has_prefix ~prefix:[ "fusion" ] (header_path header)) ->
          index
        | Header _ | Key _ | Comment | Blank | Data -> find_next (index + 1))
    in
    let rec back index =
      if index > header + 1
      then (
        match kinds.(index - 1) with
        | Comment | Blank -> back (index - 1)
        | Header _ | Key _ | Data -> index)
      else index
    in
    back (find_next (header + 1))
;;

let upsert_preset content (preset : Fusion_policy.preset) =
  let line_list, _trailing = E.split_lines content in
  let lines = Array.of_list line_list in
  let kinds = Array.of_list (classify line_list) in
  match find_region kinds preset.name with
  | Some region ->
    if not (region_is_whole kinds region preset.name)
    then Error (Unaddressable_preset preset.name)
    else (
      let anchors = collect_anchors lines kinds region preset.name in
      let rendered =
        render_preset ~header_line:lines.(region.start) ~anchors preset
      in
      Ok (join (splice line_list ~start:region.start ~stop:region.stop rendered)))
  | None ->
    if preset_declared content preset.name
    then Error (Unaddressable_preset preset.name)
    else (
      let rendered =
        render_preset
          ~header_line:(table_header (preset_path preset.name))
          ~anchors:[]
          preset
      in
      let at = insertion_index kinds in
      let separator =
        if at > 0 && not (is_blank lines.(at - 1)) then [ "" ] else []
      in
      let trailer =
        if at < Array.length lines && not (is_blank lines.(at)) then [ "" ] else []
      in
      Ok (join (splice line_list ~start:at ~stop:at (separator @ rendered @ trailer))))
;;

let locate content name =
  let line_list, _trailing = E.split_lines content in
  let kinds = Array.of_list (classify line_list) in
  match find_region kinds name with
  | Some region when region_is_whole kinds region name -> Ok (line_list, kinds, region)
  | Some _ -> Error (Unaddressable_preset name)
  | None ->
    if preset_declared content name
    then Error (Unaddressable_preset name)
    else Error (Preset_absent name)
;;

let delete_preset content ~name =
  Result.map
    (fun (line_list, kinds, region) ->
       let rec attached index =
         if index > 0
         then (
           match kinds.(index - 1) with
           | Comment -> attached (index - 1)
           | Header _ | Key _ | Blank | Data -> index)
         else index
       in
       let start = attached region.start in
       (* One blank line separated the preset from what came before; leaving it
          would stack two blanks where the preset was. *)
       let start =
         if start > 0 && region.stop < Array.length kinds
            && (match kinds.(start - 1), kinds.(region.stop) with
                | Blank, Blank -> true
                | _ -> false)
         then start - 1
         else start
       in
       join (splice line_list ~start ~stop:region.stop []))
    (locate content name)
;;

let default_preset content =
  match Otoml.Parser.from_string content with
  | exception Otoml.Parse_error _ -> None
  | toml -> Otoml.find_opt toml Otoml.get_string [ "fusion"; "default_preset" ]
;;

let rename_preset content ~from ~target =
  if String.equal from target
  then Result.map (fun _ -> content) (locate content from)
  else if preset_declared content target
  then Error (Preset_exists target)
  else
    Result.map
      (fun (line_list, kinds, region) ->
         let old_prefix = preset_path from in
         let renamed path =
           preset_path target @ List.filteri (fun index _ -> index >= 3) path
         in
         let line_list =
           List.mapi
             (fun index line ->
                if index < region.start || index >= region.stop
                then line
                else (
                  match kinds.(index) with
                  | Header (E.Table path) when has_prefix ~prefix:old_prefix path ->
                    table_header (renamed path)
                  | Header (E.Table_array path) when has_prefix ~prefix:old_prefix path ->
                    table_array_header (renamed path)
                  | Header _ | Key _ | Comment | Blank | Data -> line))
             line_list
         in
         let renamed_content = join line_list in
         match default_preset content with
         | Some current when String.equal current from ->
           E.edit_table_scalar renamed_content ~path:"fusion" ~key:"default_preset"
             ~value:(Some target)
         | Some _ | None -> renamed_content)
      (locate content from)
;;

let set_settings content (settings : settings) =
  let content =
    E.edit_table_bool content ~path:"fusion" ~key:"enabled" ~value:settings.enabled
  in
  let content =
    E.edit_table_scalar content ~path:"fusion" ~key:"default_preset"
      ~value:(Some settings.default_preset)
  in
  E.edit_table_int content ~path:"fusion" ~key:"staged_judge_group_size"
    ~value:settings.staged_judge_group_size
;;
