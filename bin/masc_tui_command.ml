type t =
  | Say of string
  | Task_for_keeper of {
      title : string;
      body : string;
    }
  | Task_missing_title
  | Help
  | Switch_keeper of string
  | Switch_keeper_missing_name
  | Interrupt_turn
  | Set_thinking of [ `Cycle | `Hidden | `Folded | `Full ]
  | Set_tools of [ `Toggle | `Compact | `Full ]
  | Toggle_memory
  | View_image of string
  | View_image_missing_path
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
  ; { word = "interrupt"
    ; args = ""
    ; summary = "signal the streaming turn to stop"
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
    ; summary = "show or hide Librarian/Memory journal rows"
    }
  ; { word = "image"; args = "<path>"; summary = "draw an image file on the terminal" }
  ; { word = "help"; args = ""; summary = "this list" }
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
    | "keeper", "" -> Switch_keeper_missing_name
    | "keeper", name -> Switch_keeper name
    | "interrupt", _ -> Interrupt_turn
    | "thinking", "" -> Set_thinking `Cycle
    | "thinking", "hidden" -> Set_thinking `Hidden
    | "thinking", "folded" -> Set_thinking `Folded
    | "thinking", "full" -> Set_thinking `Full
    | "tools", "" -> Set_tools `Toggle
    | "tools", "compact" -> Set_tools `Compact
    | "tools", "full" -> Set_tools `Full
    | "memory", _ -> Toggle_memory
    | "image", "" -> View_image_missing_path
    | "image", path -> View_image path
    | word, _ -> Unknown word

type hint =
  | No_command
  | Candidates of command_help list
  | Chosen of command_help
  | Unknown_command of string

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
        | candidates -> Candidates candidates)

let hint_line = function
  | No_command -> None
  | Chosen entry -> Some (usage entry ^ " \xe2\x80\x94 " ^ entry.summary)
  | Candidates [ entry ] ->
      (* Down to one word, so there is room to say how it ends even though
         the word itself is not typed out yet. *)
      Some (usage entry)
  | Candidates entries ->
      (* Names only. Every usage spelled out runs past a 120-column pane on
         the bare slash, and the commands that fell off the end were the ones
         an operator who typed [/] had not thought of yet. *)
      Some (String.concat "  " (List.map (fun entry -> "/" ^ entry.word) entries))
  | Unknown_command word ->
      Some
        (Printf.sprintf "/%s is not a command \xe2\x80\x94 /help lists them" word)

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
