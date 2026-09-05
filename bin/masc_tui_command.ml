type t =
  | Say of string
  | Task_for_keeper of {
      title : string;
      body : string;
    }
  | Task_missing_title
  | Help
  | About
  | Open_metrics
  | Open_settings
  | Open_diff
  | Open_changes
  | Switch_keeper of string
  | Switch_keeper_missing_name
  | Interrupt_turn
  | Steer_turn of string
  | Steer_missing_message
  | Set_thinking of [ `Cycle | `Hidden | `Folded | `Full ]
  | Set_tools of [ `Toggle | `Compact | `Full ]
  | Cycle_memory
  | Find_in_chat of string
  | Find_next
  | Inspect_context
  | View_image of string
  | View_image_missing_path
  | Attach_image of string
  | Attach_image_missing_path
  | Preset_list
  | Preset_save of {
      name : string;
      description : string;
    }
  | Preset_save_missing_name
  | Preset_restore of string
  | Preset_restore_missing_name
  | Unknown of string

(* One list, drawn by /help and kept beside the parser so a new command
   cannot ship without its line. *)
type command_help = {
  word : string;
  args : string;
  summary : string;
}

(* Every slash word this build knows, said once. [help_lines] and the
   composer hint are both drawn from here: a command described in two places
   is a command that will be described two ways, and the one an operator
   reads first is whichever list nobody updated. *)
let catalog =
  [ { word = "task"
    ; args = "<title>"
    ; summary = "create a task for this keeper (lines below become the body)"
    }
  ; { word = "keeper"
    ; args = "<name>"
    ; summary = "switch this pane to another keeper"
    }
  ; { word = "settings"
    ; args = ""
    ; summary = "open type-aware runtime settings"
    }
  ; { word = "diff"
    ; args = ""
    ; summary = "open git changes and diff for the workspace"
    }
  ; { word = "changes"
    ; args = ""
    ; summary = "open recorded file changes for this keeper"
    }
  ; { word = "interrupt"
    ; args = ""
    ; summary = "signal the streaming turn to stop"
    }
  ; { word = "steer"
    ; args = "<message>"
    ; summary = "interrupt, then run this before queued next turns"
    }
  ; { word = "thinking"
    ; args = "[hidden|folded|full]"
    ; summary = "set or cycle reasoning visibility"
    }
  ; { word = "tools"
    ; args = "[compact|full]"
    ; summary = "set or toggle tool-call detail"
    }
  ; { word = "memory"
    ; args = ""
    ; summary = "cycle Librarian/Memory journal rows: summary, full, hidden"
    }
  ; { word = "fleet-memory"
    ; args = ""
    ; summary = "browse consolidated facts across the entire keeper fleet"
    }
  ; { word = "all-memory"
    ; args = ""
    ; summary = "browse consolidated facts across the entire keeper fleet"
    }
  ; { word = "find"
    ; args = "[text]"
    ; summary = "go to the newest message holding text; again for the next"
    }
  ; { word = "context"
    ; args = ""
    ; summary = "inspect the last observed provider input"
    }
  ; { word = "image"; args = "<path>"; summary = "draw an image file on the terminal" }
  ; { word = "attach"
    ; args = "<path>"
    ; summary = "stage an image to send with the next keeper message"
    }
  ; { word = "preset"
    ; args = "[save <name> [description] | restore <name>]"
    ; summary = "list prompt presets; save the live state; restore one (autosaves first)"
    }
  ; { word = "help"; args = ""; summary = "this list" }
  ; { word = "about"
    ; args = ""
    ; summary = "display MASC Horned Reaper ASCII emblem and system telemetry"
    }
  ; { word = "splash"
    ; args = ""
    ; summary = "display MASC Horned Reaper ASCII emblem and system telemetry"
    }
  ; { word = "metrics"
    ; args = ""
    ; summary = "display multicore engine telemetry, scheduler latency, and fleet health"
    }
  ; { word = "telemetry"
    ; args = ""
    ; summary = "display multicore engine telemetry, scheduler latency, and fleet health"
    }
  ]

let usage entry =
  if String.equal entry.args "" then "/" ^ entry.word
  else "/" ^ entry.word ^ " " ^ entry.args

(* Where a help line's summary starts. Usages wider than this keep their two
   spaces rather than pushing every other summary right: one long argument
   list would otherwise indent the whole page past what a narrow pane holds.
   The value is the column the hand-written list already used. *)
let help_summary_column = 16

let help_lines =
  List.map
    (fun entry ->
       let text = usage entry in
       let padding =
         String.make (max 2 (help_summary_column - String.length text)) ' '
       in
       text ^ padding ^ entry.summary)
    catalog

let slash = '/'

(* The first line and the rest, split once on the first newline. *)
let split_first_line text =
  match String.index_opt text '\n' with
  | None -> (text, "")
  | Some at ->
      (String.sub text 0 at, String.sub text (at + 1) (String.length text - at - 1))

(* The word after the slash and whatever follows it on the line. The word
   ends at the first blank; a line that is only the word has an empty rest. *)
let split_word line =
  let is_blank c = c = ' ' || c = '\t' in
  let length = String.length line in
  let rec word_end i = if i < length && not (is_blank line.[i]) then word_end (i + 1) else i in
  let stop = word_end 0 in
  let rest = String.sub line stop (length - stop) in
  (String.sub line 0 stop, String.trim rest)

let parse text =
  if String.length text = 0 || text.[0] <> slash then Say text
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    match split_word line with
    | "task", "" -> Task_missing_title
    | "task", title -> Task_for_keeper { title; body }
    | "help", _ -> Help
    | "about", _ | "splash", _ -> About
    | "metrics", _ | "telemetry", _ -> Open_metrics
    | "settings", _ -> Open_settings
    | "diff", _ -> Open_diff
    | "changes", _ -> Open_changes
    | "keeper", "" -> Switch_keeper_missing_name
    | "keeper", name -> Switch_keeper name
    | "interrupt", _ -> Interrupt_turn
    | "steer", "" -> Steer_missing_message
    | "steer", message ->
        Steer_turn
          (if String.equal body "" then message else message ^ "\n" ^ body)
    | "thinking", "" -> Set_thinking `Cycle
    | "thinking", "hidden" -> Set_thinking `Hidden
    | "thinking", "folded" -> Set_thinking `Folded
    | "thinking", "full" -> Set_thinking `Full
    | "tools", "" -> Set_tools `Toggle
    | "tools", "compact" -> Set_tools `Compact
    | "tools", "full" -> Set_tools `Full
    | "memory", _ -> Cycle_memory
    | "fleet-memory", _ | "all-memory", _ -> Open_fleet_memory
    | "find", "" -> Find_next
    | "find", text -> Find_in_chat text
    | "context", _ -> Inspect_context
    | "image", "" -> View_image_missing_path
    | "image", path -> View_image path
    | "attach", "" -> Attach_image_missing_path
    | "attach", path -> Attach_image path
    | "preset", "" -> Preset_list
    | "preset", rest -> (
        match split_word rest with
        | "save", "" -> Preset_save_missing_name
        | "save", name_and_description ->
            (* The lines below the command are description, the way /task
               takes its body. Dropping them would lose text the operator
               typed on purpose. *)
            let name, first_line = split_word name_and_description in
            let description =
              match (first_line, body) with
              | "", body -> body
              | first_line, "" -> first_line
              | first_line, body -> first_line ^ "\n" ^ body
            in
            Preset_save { name; description }
        | "restore", "" -> Preset_restore_missing_name
        | "restore", name -> Preset_restore name
        | verb, _ -> Unknown ("preset " ^ verb))
    | word, _ -> Unknown word

type hint =
  | No_command
  | Candidates of {
      typed : string;
      entries : command_help list;
    }
  | Chosen of command_help
  | Unknown_command of string

(* One piece of a hint row, split where the colour changes. The module draws
   nothing itself -- it says which glyphs are the ones already typed and
   which are still ahead, and the renderer decides what that looks like. *)
type hint_span =
  | Typed of string  (** Glyphs the operator has already entered. *)
  | Untyped of string  (** What the word would still need. *)
  | Detail of string  (** Arguments, summaries, separators. *)
  | Wrong of string  (** A word that names no command. *)

(* What to show an operator who is part way through typing a command.

   The grammar has no prefix matching, so a half-typed word is not a command
   yet and is never reported as one: [/ta] lists what it could become,
   [/task] describes what it is. Showing the summary any earlier would say a
   line was ready to send when the parser would refuse it.

   A word that begins nothing is named as unknown while the operator can
   still fix it. Before this it took an Enter and a rejected line to find out
   the command did not exist. *)
let hint text =
  if String.length text = 0 || text.[0] <> slash then No_command
  else
    let first, _ = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    let word, _ = split_word line in
    match List.find_opt (fun entry -> String.equal entry.word word) catalog with
    | Some entry -> Chosen entry
    | None -> (
        match
          List.filter
            (fun entry -> String.starts_with ~prefix:word entry.word)
            catalog
        with
        | [] -> Unknown_command word
        | entries -> Candidates { typed = word; entries })

let em_dash = " \xe2\x80\x94 "

(* The typed run always starts with the slash, so the highlight covers what
   the operator pressed rather than the word minus its first key. *)
let word_spans ~typed entry =
  let remaining =
    String.sub entry.word (String.length typed)
      (String.length entry.word - String.length typed)
  in
  [ Typed ("/" ^ typed); Untyped remaining ]

(* The bare slash is the row an operator types knowing nothing, so it is the
   one that must not run off the pane.

   It used to draw every command word, and it fit until it did not: the list
   was compacted once when /settings joined the catalog and ran over again at
   /find. A row sized by how many commands happen to exist is a row that
   breaks on the next one, so this one carries what fits and says how many it
   could not, pointing at the list that is complete by definition.

   Command words are ASCII by construction -- they are spelled in [catalog]
   above -- so bytes and cells are the same count here. *)
let bare_slash_hint_cells = 80

let bare_slash_spans entries =
  let total = List.length entries in
  let rendered kept_count =
    let words =
      entries
      |> List.filteri (fun index _ -> index < kept_count)
      |> List.map (fun entry -> entry.word)
      |> String.concat " "
    in
    let dropped = total - kept_count in
    let tail =
      if dropped <= 0 then ""
      else Printf.sprintf " +%d more (/help)" dropped
    in
    (words, tail, 1 + String.length words + String.length tail)
  in
  (* At most one row of candidates and a dozen words, so the fit is found by
     trying rather than by solving for a marker whose own width depends on how
     many words were dropped. *)
  let rec choose kept_count =
    if kept_count <= 0 then rendered 0
    else
      let (_, _, width) as attempt = rendered kept_count in
      if width <= bare_slash_hint_cells then attempt else choose (kept_count - 1)
  in
  let words, tail, _ = choose total in
  [ Typed "/"; Untyped words ]
  @ (if String.equal tail "" then [] else [ Detail tail ])

let hint_spans = function
  | No_command -> []
  | Chosen entry ->
      Typed ("/" ^ entry.word)
      :: (if String.equal entry.args "" then []
          else [ Detail (" " ^ entry.args) ])
      @ [ Detail (em_dash ^ entry.summary) ]
  | Candidates { typed; entries = [ entry ] } ->
      (* Down to one word, so there is room to say how it ends even though the
         word itself is not typed out yet. *)
      word_spans ~typed entry
      @ (if String.equal entry.args "" then []
         else [ Detail (" " ^ entry.args) ])
  | Candidates { typed = ""; entries } -> bare_slash_spans entries
  | Candidates { typed; entries } ->
      (* Names only. Every usage spelled out runs past a 120-column pane on
         the bare slash, and the commands that fell off the end were the ones
         an operator who typed [/] had not thought of yet.

         One space between them, not two.  The bare slash has its own compact
         branch above; once a prefix is typed, the shorter candidate list can
         afford to repeat each slash. *)
      List.concat
        (List.mapi
           (fun index entry ->
              (if index = 0 then [] else [ Detail " " ])
              @ word_spans ~typed entry)
           entries)
  | Unknown_command word ->
      [ Wrong ("/" ^ word)
      ; Detail (" is not a command" ^ em_dash ^ "/help lists them")
      ]

let hint_span_text = function
  | Typed text | Untyped text | Detail text | Wrong text -> text

let hint_line hint =
  match hint_spans hint with
  | [] -> None
  | spans -> Some (String.concat "" (List.map hint_span_text spans))

(* How [/keeper <name>] finds its keeper. The command grammar stays closed —
   no prefix matching on command words — but a keeper NAME is an argument,
   and an operator mid-thought types the least of it that still names one
   keeper. Exact match wins outright so a keeper whose full name prefixes
   another's is still reachable; otherwise a prefix must be unique, and an
   ambiguous one reports its candidates instead of guessing. *)
type keeper_match =
  | Keeper_found of string
  | Keeper_ambiguous of string list
  | Keeper_unknown

let resolve_keeper_name ~names typed =
  if List.exists (String.equal typed) names then Keeper_found typed
  else
    match
      List.filter (fun name -> String.starts_with ~prefix:typed name) names
    with
    | [ name ] -> Keeper_found name
    | [] -> Keeper_unknown
    | candidates -> Keeper_ambiguous candidates

let task_message ~task_id ~title ~body =
  if String.equal (String.trim body) "" then Printf.sprintf "[%s] %s" task_id title
  else Printf.sprintf "[%s] %s\n%s" task_id title body

let rec make_valid_utf_8 s =
  if String.equal s "" || String.is_valid_utf_8 s then s
  else make_valid_utf_8 (String.sub s 0 (String.length s - 1))

let longest_common_prefix = function
  | [] -> ""
  | [ s ] -> s
  | s :: rest ->
      let common_prefix a b =
        let max_len = min (String.length a) (String.length b) in
        let rec loop i =
          if i < max_len && a.[i] = b.[i] then loop (i + 1) else i
        in
        make_valid_utf_8 (String.sub a 0 (loop 0))
      in
      List.fold_left common_prefix s rest

type direction = Next | Prev

let cycle_next ~items current =
  match items with
  | [] -> None
  | [ single ] -> Some single
  | _ -> (
      match List.find_index (fun s -> String.equal s current) items with
      | Some idx ->
          let next_idx = (idx + 1) mod List.length items in
          Some (List.nth items next_idx)
      | None -> Some (List.hd items))

let cycle_prev ~items current =
  match items with
  | [] -> None
  | [ single ] -> Some single
  | _ -> (
      match List.find_index (fun s -> String.equal s current) items with
      | Some idx ->
          let len = List.length items in
          let prev_idx = (idx - 1 + len) mod len in
          Some (List.nth items prev_idx)
      | None ->
          let len = List.length items in
          Some (List.nth items (len - 1)))

let cycle_step ~direction ~items current =
  match direction with
  | Next -> cycle_next ~items current
  | Prev -> cycle_prev ~items current

let known_sub_arguments ~keeper_names word =
  match word with
  | "thinking" -> [ "hidden"; "folded"; "full" ]
  | "tools" -> [ "compact"; "full" ]
  | "preset" -> [ "save"; "restore" ]
  | "keeper" -> keeper_names
  | _ -> []

let get_siblings word =
  if String.equal word "" then List.map (fun e -> e.word) catalog
  else
    let initial = String.sub word 0 1 in
    catalog
    |> List.filter (fun e -> String.starts_with ~prefix:initial e.word)
    |> List.map (fun e -> e.word)

let with_body body text =
  if String.equal body "" then text else text ^ "\n" ^ body

let autocomplete ?(direction = Next) ?(keeper_names = []) text =
  if String.length text = 0 || text.[0] <> slash then None
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    if not (String.contains line ' ') then begin
      (* Command word completion *)
      let candidates =
        if String.equal line "" then catalog
        else
          List.filter
            (fun entry -> String.starts_with ~prefix:line entry.word)
            catalog
      in
      match candidates with
      | [] -> None
      | [ single ] ->
          if String.equal line single.word then
            let siblings = get_siblings line in
            if List.length siblings > 1 then
              match cycle_step ~direction ~items:siblings line with
              | Some next_word ->
                  let next_entry =
                    List.find (fun e -> String.equal e.word next_word) catalog
                  in
                  let suffix = if String.equal next_entry.args "" then "" else " " in
                  Some (with_body body ("/" ^ next_word ^ suffix))
              | None -> None
            else
              let suffix = if String.equal single.args "" then "" else " " in
              if String.equal suffix "" then None
              else Some (with_body body ("/" ^ single.word ^ suffix))
          else
            let suffix = if String.equal single.args "" then "" else " " in
            Some (with_body body ("/" ^ single.word ^ suffix))
      | entries ->
          let words = List.map (fun e -> e.word) entries in
          let lcp = longest_common_prefix words in
          if direction = Next && String.length lcp > String.length line then
            Some (with_body body ("/" ^ lcp))
          else
            (match cycle_step ~direction ~items:words line with
             | Some next_word ->
                 let next_entry =
                   List.find (fun e -> String.equal e.word next_word) entries
                 in
                 let suffix = if String.equal next_entry.args "" then "" else " " in
                 Some (with_body body ("/" ^ next_word ^ suffix))
             | None -> None)
    end else begin
      (* Sub-argument completion on first line *)
      let word_len = String.index line ' ' in
      let word = String.sub line 0 word_len in
      let after_space =
        String.sub line (word_len + 1) (String.length line - word_len - 1)
      in
      let options = known_sub_arguments ~keeper_names word in
      if options = [] then begin
        if String.equal (String.trim after_space) "" then
          let siblings = get_siblings word in
          if List.length siblings > 1 then
            match cycle_step ~direction ~items:siblings word with
            | Some next_word ->
                let next_entry =
                  List.find (fun e -> String.equal e.word next_word) catalog
                in
                let suffix = if String.equal next_entry.args "" then "" else " " in
                Some (with_body body ("/" ^ next_word ^ suffix))
            | None -> None
          else None
        else None
      end else if String.equal (String.trim after_space) "" then
        let chosen =
          match direction with
          | Next -> List.hd options
          | Prev -> List.nth options (List.length options - 1)
        in
        Some (with_body body ("/" ^ word ^ " " ^ chosen))
      else if String.ends_with ~suffix:" " after_space then
        None
      else
        let rest = String.trim after_space in
        let matches =
          List.filter
            (fun opt -> String.starts_with ~prefix:rest opt)
            options
        in
        match matches with
        | [] -> None
        | [ single ] when not (String.equal rest single) ->
            Some (with_body body ("/" ^ word ^ " " ^ single))
        | [ single ] ->
            (match cycle_step ~direction ~items:options single with
             | Some next_opt -> Some (with_body body ("/" ^ word ^ " " ^ next_opt))
             | None -> None)
        | many ->
            let lcp = longest_common_prefix many in
            if direction = Next && String.length lcp > String.length rest then
              Some (with_body body ("/" ^ word ^ " " ^ lcp))
            else
              (match cycle_step ~direction ~items:many rest with
               | Some next_opt -> Some (with_body body ("/" ^ word ^ " " ^ next_opt))
               | None -> None)
    end

let is_slash_navigable ?(keeper_names = []) text =
  if String.length text = 0 || text.[0] <> slash then false
  else
    let first, _ = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    if not (String.contains line ' ') then
      let candidates =
        if String.equal line "" then catalog
        else
          List.filter
            (fun entry -> String.starts_with ~prefix:line entry.word)
            catalog
      in
      match candidates with
      | [] -> false
      | [ single ] ->
          if not (String.equal line single.word) then true
          else
            let siblings = get_siblings line in
            List.length siblings > 1 || not (String.equal single.args "")
      | _ :: _ -> true
    else
      let word_len = String.index line ' ' in
      let word = String.sub line 0 word_len in
      let after_space =
        String.sub line (word_len + 1) (String.length line - word_len - 1)
      in
      let options = known_sub_arguments ~keeper_names word in
      if options = [] then
        if String.equal (String.trim after_space) "" then
          let siblings = get_siblings word in
          List.length siblings > 1
        else false
      else if String.equal (String.trim after_space) "" then true
      else if String.ends_with ~suffix:" " after_space then false
      else
        let rest = String.trim after_space in
        List.exists (fun opt -> String.starts_with ~prefix:rest opt) options

let about_banner ?(theme_name = "default") ?(active_keepers = 0) () =
  String.concat "\n"
    [ "   ___  ___  ___  _____ _____ "
    ; "  |   \\/   |/ _ \\/  ___/  __ \\"
    ; "  | /\\  / / /_\\ \\ `--.| /  \\/"
    ; "  | | \\/| |  _  | `--. \\ |    "
    ; "  | |   | | | | /\\__/ / \\__/\\"
    ; "  \\_|   |_|_| |_\\____/ \\____/"
    ; " ╭────────────────────────────────────────────────────────╮"
    ; " │  HORNED REAPER CORE · Multi-Agent Supervised Control   │"
    ; Printf.sprintf " │  Theme: %-22s  Keepers: %-13d │" theme_name active_keepers
    ; " │  Treasury: 24K Gold Dungeon · Gates: All Secure        │"
    ; " ╰────────────────────────────────────────────────────────╯"
    ]
