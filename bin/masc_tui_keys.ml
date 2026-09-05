(* The key table — data first, then the display projections. Most dispatch
   remains the ordered match in masc_tui.ml; cross-surface shortcuts whose
   spelling is shared with the displays classify through this module too.
   That keeps one binding record authoritative for both behaviour and
   discoverability (#30356 taught the cost of the two drifting apart). *)

open Masc_tui_types

type group = Navigate | Act | Search | Meta

type binding = {
  key : string;
  label : string;
  help : string option;
  group : group;
}

let b ?help group key label = { key; label; help; group }

let keepers_jump =
  b Meta "2" "keepers"
    ~help:"jump to Keepers when the active field or panel does not use 2"

let global =
  [ b Meta "Tab / Shift-Tab" "next / previous surface"
  ; keepers_jump
  ; b Meta "r" "refresh the current surface"
  ; b Meta "i" "focus the composer (message the shown keeper)"
  ; b Meta ":" "command palette"
  ; b Meta ";" "agenda: what is coming, and who is waiting on you"
  ; b Meta "@" "answering: who is mid-turn or just finished; Enter opens their chat"
  ; b Meta "?" "this help"
  ; b Meta "Ctrl-B" "show or hide a visible keeper roster pane"
  ; b Meta "Ctrl-T" "release the mouse so you can drag-select and copy"
  ; b Navigate "Ctrl-]" "follow the reference under the cursor"
      ~help:"and Esc on the surface it opens comes back here"
  ; b Meta "q" "quit"
  ]

(* The plain-listing tail every converted footer shares. *)
let listing_meta = [ b Meta "r" "refresh"; b Meta "Tab" "next"; b Meta "q" "quit" ]

let keeper_actions =
  [ b Act "c" "chat" ~help:"chat with the keeper"
  ; b Act "l" "logs"
  ; b Act "t" "calls" ~help:"tool calls"
  ; b Act "u" "runtime" ~help:"pick a runtime lane"
  ; b Act "g" "yolo / auto" ~help:"toggle yolo / auto tool approval"
  ; b Act "p / w" "pause / wake"
  ; b Act "s" "shutdown"
  ; b Act "e" "settings"
  ; b Act "f" "files" ~help:"file changes this keeper wrote"
  ; b Act "a" "new" ~help:"new keeper"
  ]

let for_surface = function
  | Overview ->
      [ b Navigate "j/k" "events" ~help:"scroll events"
      ; b Navigate "h/l" "pane" ~help:"move between events and tasks"
      ; b Act "t" "tasks" ~help:"hand j/k to the task list"
      ; b Act "Right / Enter" "open" ~help:"open the selected task"
      ; b Act "Left / Esc" "back" ~help:"close detail / back to events"
      ]
      @ listing_meta
  | Acting ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "g / G" "newest / oldest"
      ; b Navigate "l" "logs"
          ~help:"the server's own log lines, off the ring under Activity"
      ; b Act "f" "filter" ~help:"cycle the filter"
      ; b Act "Esc" "overview"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Metrics ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "1-3" "section"
          ~help:"1: Fleet Pulse & Activity · 2: Keeper Memory Resources · 3: Gate Queue"
      ; b Navigate "s" "cycle" ~help:"cycle telemetry section"
      ; b Act "Esc" "overview"
      ; b Meta "r" "refresh"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Keepers Keeper_list ->
      (b Navigate "j/k" "move" ~help:"move the roster cursor")
      :: (b Act "Right / Enter" "detail" ~help:"keeper detail")
      :: keeper_actions
      @ [ b Search "/" "search" ~help:"search names; Enter keeps the query"
        ; b Search "n / N" "next / previous match"
        ; b Act "Esc" "overview"
        ]
      @ listing_meta
  | Keepers Keeper_detail ->
      [ b Navigate "h/l" "pane" ~help:"move between roster and detail"
      ; b Navigate "[ / ]" "tabs" ~help:"detail tabs: Info / Settings / Secrets / GitHub"
      ; b Act "o" "logs"
          ~help:"open container logs in Sandbox; Keeper activity elsewhere"
      ; b Act "U" "runtime" ~help:"pick a runtime lane"
      ; b Act "Left / Esc" "back"
      ]
      @ List.filter
          (fun binding -> binding.key <> "l" && binding.key <> "u")
          keeper_actions
  | Keepers Keeper_logs ->
      (* The shared tail was missing here while the renderer's own footer
         string carried it, so the sheet and the footer disagreed about
         whether r/q worked on this screen. *)
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ] @ listing_meta
  | Keepers Keeper_calls ->
      [ b Navigate "j/k" "scroll"; b Act "Left / Esc" "back" ] @ listing_meta
  | Keepers Keeper_message ->
      [ b Navigate "Left" "roster" ~help:"focus the visible Keeper roster"
      ; b Navigate "Right / Esc" "chat" ~help:"return focus to the chat composer"
      ; (* One key, two focuses: the roster when it holds focus, the history
           when the chat is scrolled back. Listed once so the table keeps the
           one-key-one-row contract (#33236). *)
        b Navigate "Up / Down" "roster move / scroll"
          ~help:"roster focused: move; chat scrolled back: adjust by one line"
      ; b Act "Enter" "send / open"
          ~help:"send from chat, or open the selected Keeper from the roster"
      ; b Act "Ctrl-J" "newline" ~help:"newline in the draft"
      ; b Act "Ctrl-G" "next keeper" ~help:"next keeper with a chat open"
      ; b Act "Ctrl-U" "clear" ~help:"clear the draft"
      ; b Act "Ctrl-K / Ctrl-P" "queued line"
          ~help:"cancel / edit the last queued line"
      ; b Navigate "PgUp / PgDn" "history" ~help:"scroll history by a page"
      ; b Act "Ctrl-R" "reasoning" ~help:"cycle reasoning hidden / folded / full"
      ; b Act "Ctrl-D" "tool detail" ~help:"toggle compact / full tool-call detail"
      ; b Act "Ctrl-N" "memory detail"
          (* The three words are the states' own, the way Ctrl-R above spells
             its own. Pressing this answers "Librarian/Memory timeline: full",
             so a help promising "full detail" sends a reader looking for a
             state the pane never names. *)
          ~help:"cycle Memory journal summary / full / hidden"
      ; b Act "Ctrl-F" "message metadata"
          ~help:"cycle no clock / inline clock / full timestamp and request id"
      ; b Act "y / n" "approval" ~help:"answer a tool approval"
      ; b Act "Q" "leave"
          ~help:"leave with a turn running, without interrupting it \
                 (empty draft, no capture or edit in flight)"
      ; b Act "Esc" "back" ~help:"back; during a turn, interrupt it"
      ]
  | Keepers Keeper_runtime_pick ->
      [ b Navigate "j/k" "move"
      ; b Act "Enter" "choose"
      ; b Act "d" "use the default"
          ~help:"drop this Keeper's own binding and follow [runtime].default"
      ; b Act "Esc" "back"
      ]
  | Lanes ->
      [ b Navigate "j/k" "move" ~help:"move the lane cursor"
      ; b Act "Right / Enter" "runs"
          ~help:"open the standalone lane's exact runs"
      ; b Navigate "e" "lane config"
          ~help:"open this lane's runtime.exact_output_lanes section"
      ; b Navigate "p" "runtime"
          ~help:"back to the Runtime surface this hangs off"
      ; b Act "Esc" "runtime" ~help:"back to the Runtime surface it hangs off"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching standalone lane; the run list \
                 and a run's detail carry no searchable rows"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Clients ->
      [ b Navigate "j/k" "move" ~help:"move the roster cursor"
      ; b Navigate "p" "runtime"
          ~help:"back to the Runtime surface this hangs off"
      ; b Act "Esc" "runtime" ~help:"back to the Runtime surface it hangs off"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching attached name"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Board ->
      [ b Navigate "j/k" "move"
      ; b Act "Right / Enter" "read" ~help:"read the post"
      ; b Act "Left / Esc" "back" ~help:"close the post"
      ; b Act "w" "write" ~help:"write a post"
      ; b Act "v / V" "vote up / down"
      ; b Act "c" "reply" ~help:"reply (while reading)"
      ; b Navigate "[ / ]" "previous / next post"
          ~help:"while reading, open the post before or after this one"
      ; b Navigate "s" "sort" ~help:"cycle hot / trending / recent / updated / discussed"
      ; b Search "f" "hearth"
          ~help:"narrow to one sub-board, busiest first; again for the next"
      ; b Navigate "z" "wide detail" ~help:"hide or show the post list while reading"
      ; b Act "Y" "copy link" ~help:"copy the selected post reference"
      ; b Navigate "Ctrl-W" "pane" ~help:"switch between the post list and detail pane"
      ; b Navigate "h/l" "pane" ~help:"focus the post list or detail pane"
        (* Beside [f], not instead of it: [f] narrows the list to one hearth,
           this jumps the cursor to a post without changing what is listed. *)
      ; b Search "/" "find" ~help:"jump the cursor to a matching post id, author or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Approvals ->
      [ b Navigate "j/k" "move"
        (* The list draws each ask on one row. Enter is where a multi-line
           argument is readable before y answers it. *)
      ; b Act "Enter" "read the whole ask" ~help:"j/k scrolls it; Esc goes back"
      ; b Act "y" "confirm"
      ; b Act "n" "deny"
      ; b Act "R" "retry Auto Judge"
          ~help:"only when the blocked row is safely rearmable"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "e" "external Gate lane"
          ~help:"cycle manual / auto_judge / always_allow for calls into \
                 attached outside services"
      ]
      @ listing_meta
  | Planning ->
      [ b Navigate "j/k" "move"
      ; b Navigate "v" "next Planning tab"
          ~help:"1 Goals \xe2\x86\x92 2 Task Review \xe2\x86\x92 3 Evaluator \
                 Verdicts"
      ; b Act "Right / Enter" "detail"
      ; b Act "Left / Esc" "back"
      ; b Navigate "f" "filter" ~help:"cycle all / active / completed / dropped"
      ; b Navigate "s" "sort" ~help:"cycle phase / updated / due"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "c" "complete" ~help:"complete goal"
      ; b Act "x" "drop"
      ; b Act "o" "reopen"
      ; b Act "Y" "copy link" ~help:"copy the selected goal reference"
        (* Over the goals [f] and [s] left on screen, in the order they are
           drawn: the search walks what the list shows, not the snapshot. *)
      ; b Search "/" "find" ~help:"jump the cursor to a matching goal id or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Schedules ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the payload"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Right / Enter" "details" ~help:"open schedule details"
      ; b Act "Left / Esc" "back" ~help:"back to the schedule list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "n" "new" ~help:"create a schedule through a $EDITOR JSON form"
      ; b Act "e" "modify"
          ~help:"edit the selected active schedule; running/finished rows refuse"
      ; b Act "x" "cancel" ~help:"arm / confirm cancellation"
      ; b Act "Y" "copy link" ~help:"copy the selected schedule reference"
      ]
      @ listing_meta
  | Verification ->
      [ b Navigate "j/k" "move" ~help:"move; in details, scroll the evidence"
      ; b Navigate "v" "next Planning tab"
          ~help:"on to 3 Evaluator Verdicts, then 1 Goals"
      ; b Act "Right / Enter" "details" ~help:"read the request and evidence"
      ; b Act "Left / Esc" "back" ~help:"back to the verification queue"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "a" "approve" ~help:"approve the row under the cursor (press twice)"
      ; b Act "x" "reject" ~help:"reject with a reason ($EDITOR form)"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching task id, title, or submitter; \
                 the queue answers this, an open detail does not"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Harness ->
      [ b Navigate "j/k" "move" ~help:"move; in a verdict, scroll"
      ; b Navigate "v" "next Planning tab" ~help:"back round to 1 Goals"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Right / Enter" "verdict" ~help:"open the full evaluator verdict"
      ; b Act "Left / Esc" "back" ~help:"back to the verdict list"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "y" "agree" ~help:"record the machine's verdict as yours"
        (* [x], not [n]: this surface answers the row search, and [n] / [N]
           step it. Spelled the way Verification spells its own rejection. *)
      ; b Act "x" "overrule" ~help:"record the opposite verdict; $EDITOR takes the reason"
      ; b Act "Y" "copy task" ~help:"copy a link to the task on Overview"
      ; b Search "/" "find" ~help:"jump the cursor to a matching task id or title"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Fusion ->
      (* [fusion_mode] owns list/detail (masc_tui_types.ml); the detail
         footer is [footer_hints_fusion_detail], which also appends the live
         scroll position this static table cannot know. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "PgUp/PgDn" "page"
      ; b Act "Enter" "detail" ~help:"Right or Enter opens detail"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while a detail is open, step to the row before or after it"
      ; b Act "Y" "copy" ~help:"copy the selected Fusion run reference"
      ; b Act "Esc" "back" ~help:"leave detail, or return to Overview"
      ]
      @ listing_meta
  | Memory ->
      (* j/k moves the keeper row the health table draws -- the row Enter
         reads. [ / ] was listed here for that same movement and never had a
         handler, so the footer offered two spellings and one of them did
         nothing. *)
      [ b Navigate "j/k" "move" ~help:"move the keeper row"
      ; b Act "Enter" "facts"
          ~help:"browse what the selected keeper actually remembers"
      ; b Search "/" "find" ~help:"jump the cursor to a matching keeper"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Repositories ->
      [ b Navigate "j/k" "scroll"
      ; b Act "Enter" "browse"
          ~help:"open the repository tree, or the selected changed file"
      ; b Act "d" "Git changes"
          ~help:"show the selected repository's current working-tree changes"
      ; b Act "a" "add" ~help:"register a repository; opens $EDITOR"
      ; b Act "Left / Esc" "back"
          ~help:"leave Git changes, or return to Overview"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching repository, or to a changed \
                 path while Git changes is open"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Changes ->
      (* "move", not "scroll": the keys move the marked row and the window
         follows it, which is also what the surface's own footer says. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "[ / ]" "keeper" ~help:"previous / next keeper"
      ; b Act "Right / Enter" "written diff"
          ~help:"what the call wrote, as a diff"
      ; b Act "Left / Esc" "back" ~help:"close the diff"
      ; b Act "d" "tree diff" ~help:"what the tree holds now"
      ; b Act "v" "view code"
          ~help:"the file on the Code surface, read from the keeper's own \
                 workspace"
      ; b Act "o" "editor" ~help:"open in $EDITOR / $NVIM"
      ]
      @ listing_meta
  | Connectors ->
      [ b Navigate "j/k" "scroll"
      ; b Act "b / u" "bind / unbind" ~help:"bind / unbind a channel"
      ; b Act "Esc" "keeper" ~help:"back to the selected Keeper"
      ; b Search "/" "find" ~help:"jump the cursor to a matching transport"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Runtime ->
      [ b Navigate "j/k" "move / scroll"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Act "Right / Enter" "detail"
          ~help:"show the full runtime, lane, dispatch, and probe fields"
      ; b Navigate "p" "keeper lanes / all runtimes / service lanes"
          ~help:"walk the three substrate readings; the third is the \
                 standalone Lanes surface"
      ; b Navigate "c" "clients"
          ~help:"everyone attached to this workspace, off the ring under \
                 Runtime"
      ; b Act "Left / Esc" "back"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching lane id or runtime id"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta
  | Config ->
      [ b Navigate "j/k" "select / scroll"
        (* Config combines persisted files, typed live params, and the local
           theme choice.  The pane strip says which meaning each key has. *)
      ; b Navigate "p" "runtime.toml / models / params / prompts / themes"
      ; b Navigate "s" "resources"
          ~help:"the MCP resource catalog, off the ring under Config"
      ; b Navigate "t" "tools"
          ~help:"the tool catalog, receipts, and usage, off the ring under \
                 Config"
      ; b Act "e" "edit"
          ~help:"params use a type-aware field; runtime.toml previews; prompts save an override"
      ; b Act "E" "advanced JSON"
          ~help:"on params only: edit the exact JSON value"
      ; b Act "Enter" "edit / use"
          ~help:"edit the selected param; on themes, use that colour scheme"
      ; b Act "x" "default / clear"
          ~help:"params return to default; prompts clear override; themes follow terminal colours"
      ; b Act "f" "filter"
          ~help:"on themes, cycle All / Dark / Light schemes"
      ; b Act "Esc" "overview"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ]
  | Resources ->
      [ b Navigate "j/k" "move"
          ~help:"move the list; with the text focused, scroll it"
      ; b Navigate "h/l" "pane" ~help:"focus the resource list or text"
      ; b Navigate "Ctrl-W" "focus" ~help:"switch between resource list and text"
      ; b Navigate "J / K" "scroll text"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while the detail is focused, read the adjacent resource"
      ; b Act "Enter" "read" ~help:"read the selected resource"
      ; b Act "Esc" "back"
          ~help:"the text hands back to the list; the list leaves for Config"
      ; b Meta "r" "reload"
      ; b Meta "Tab" "next"
      ; b Meta "q" "quit"
      ]
  | Code ->
      (* A row surface: masc_tui_types gives it a searchable row list
         (code_entries), so the cursor and "/" are real here, and Enter drills
         one directory level (the /workspace/children route is lazy). Claimed
         from those two facts rather than from the render, so the footer does
         not advertise a key nothing handles. *)
      [ b Navigate "j/k" "move"
      ; b Navigate "h/l" "pane" ~help:"focus the tree or open file"
      ; b Act "Right / Enter" "open" ~help:"drill in, or open the file"
        (* Esc walks back out the way Enter came in: it closes an open file
           first, and only climbs a directory once no file is open. From the
           project root, Esc alone leaves for Workspace, the ring parent --
           Left stays on the surface, the same convention as every other
           off-ring child. A key that works and is not listed is the same
           drift as a listed key that does nothing, pointing the other way. *)
      ; b Act "Left / Esc" "back"
          ~help:"close the history, then the file, then climb one \
                 directory; Esc at the project root leaves for Workspace"
      ; b Navigate "Shift-Left / Shift-Right" "pan"
          ~help:"with a file open, scroll it sideways one cell at a time"
      ; b Search "/" "find"
          ~help:"jump the cursor to a match: the tree, or the open file's \
                 lines"
      ; b Search "n / N" "next / previous match"
      ; b Act "K" "hover"
          ~help:"ask the language server what a name on the cursor line is \
                 (one name asks at once; several open the palette as \
                 choices)"
      ; b Act "R" "references"
          ~help:"ask the language server where a name on the cursor line is \
                 used; needs the project's reference index, and says which \
                 command builds it when there is none"
      ; b Act "D" "definition"
          ~help:"jump to where a name on the cursor line is defined (one \
                 name jumps at once; several open the palette as choices)"
      ; b Act "B" "back"
          ~help:"walk back through the definition jumps, newest first"
      ; b Act "b" "blame"
          ~help:"who last touched each run of lines, in the margin; b again \
                 drops it"
      ; b Act "m" "notes"
          ~help:"the notes anchored to the open file (repository scope)"
      ; b Act "w" "add note"
          ~help:"in the notes view: add one through the $EDITOR form, \
                 anchored to the line the cursor was on when the view opened \
                 (kind: Comment / Decision / Question / Bookmark)"
      ; b Act "d" "diff"
          ~help:"on the project tree, list every working-tree change; on an \
                 open file, show that file's diff against HEAD"
      ; b Act "Enter (history)" "open"
          ~help:"a commit answers with its pull request, from its (#N) and \
                 the repository's remote"
      ; b Act "H" "history"
          ~help:"the commits that touched the open file, newest first \
                 (H or Esc closes)"
      ]
      @ listing_meta
  | Tools ->
      [ b Navigate "j/k" "scroll"
      ; b Navigate "Home/End" "top/bottom"
      ; b Navigate "p" "section"
          ~help:"available / async runs / receipts / usage / all tools"
      ; b Navigate "J/K" "Skill" ~help:"select a published Skill"
      ; b Navigate "[/]" "Keeper" ~help:"change the effective Keeper surface"
      ; b Act "e" "edit Skill"
          ~help:"open the selected SKILL.md in $EDITOR, validate, CAS-save, and publish"
      ; b Act "Esc" "config" ~help:"back to the Config surface it hangs off"
      ]
      @ listing_meta
  | System_logs ->
      [ b Navigate "j/k" "move / scroll"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Navigate "[ / ]" "previous / next"
          ~help:"while detail is open, inspect the adjacent visible log entry"
      ; b Act "l" "level floor"
          ~help:"raise the minimum level; after error, back to everything"
      ; b Act "v" "verbose"
          ~help:"toggle DEBUG rows directly; off uses the INFO floor"
      ; b Act "c" "category"
          ~help:"cycle through the categories this page carries"
      ; b Act "Right / Enter" "detail"
          ~help:"show the full message, source, category, turn, and JSON details"
      ; b Act "Left / Esc" "back"
      ; b Search "/" "find"
          ~help:"jump the cursor to a matching module, keeper, or message, \
                 over the rows the level and category filters leave"
      ; b Search "n / N" "next / previous match"
      ]
      @ listing_meta

let group_rank = function Navigate -> 0 | Act -> 1 | Search -> 2 | Meta -> 3

(* Sort by group, then flatten to the footer's "key:label  key:label" form.
   Both the static per-surface footer and the Fusion detail footer (which
   appends a live scroll position) render through this one projection. *)
let hints_of_bindings bindings =
  bindings
  |> List.stable_sort (fun a b -> compare (group_rank a.group) (group_rank b.group))
  |> List.map (fun { key; label; _ } -> key ^ ":" ^ label)
  |> String.concat "  "

let footer_hints surface = hints_of_bindings (for_surface surface)

(* The Overview footer is the same table plus one runtime fact the renderer
   owns: whether j/k currently drives the task list (task_focus) or the
   event list. The table stays the SSOT — this projection only relabels
   j/k and drops the keys that are dead in the current mode (t enters the
   task list, Enter/Esc act on the focused task), exactly like the old
   hand-assembled literal did, but without a second key list. *)
let footer_hints_overview ~task_focus =
  let dead =
    if task_focus then [ "t" ] else [ "Right / Enter"; "Left / Esc" ]
  in
  keepers_jump :: for_surface Overview
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
         if b.key = "j/k" then
           { b with label = (if task_focus then "tasks" else "events") }
         else b)
  |> hints_of_bindings

(* The Code surface's footer, which the renderer used to spell by hand. It
   named d, H, m and w and nothing else, so the three language-server keys
   never appeared on the screen they work on -- and neither did blame or the
   row search when those arrived. Projected here, from the table the help
   sheet already reads, and narrowed to what the current mode answers: an
   overlay owns the pane, so the keys that act on the code underneath are
   dead while it is up, and the tree pane answers none of the file keys. *)
type code_pane =
  | Code_tree  (** the file list has focus *)
  | Code_file  (** a file is open and nothing covers it *)
  | Code_overlay  (** history, diff or notes is drawn over the file *)

let footer_hints_code ~pane =
  let file_keys =
    [ "Shift-Left / Shift-Right"; "K"; "D"; "R"; "B"; "b"; "d"; "H"; "m" ]
  in
  (* Two keys belong to one pane each and were showing on all three. [w]
     writes a note and only the notes view takes it; [Enter (history)] opens
     a commit's pull request and only the history view has commits. Named
     apart from [file_keys] because they are the overlay's own, not the
     file's. *)
  let overlay_keys = [ "w"; "Enter (history)" ] in
  let dead =
    match pane with
    | Code_tree -> overlay_keys @ file_keys
    | Code_file -> overlay_keys
    | Code_overlay -> file_keys
  in
  for_surface Code
  |> List.filter (fun b -> not (List.mem b.key dead))
  |> List.map (fun b ->
       if String.equal b.key "j/k" then
         { b with label = (match pane with Code_tree -> "move" | _ -> "scroll") }
       else b)
  |> hints_of_bindings

let footer_hints_resources ~detail_focus =
  for_surface Resources
  |> List.map (fun binding ->
         if String.equal binding.key "j/k" then
           { binding with label = (if detail_focus then "scroll text" else "move") }
         else binding)
  |> hints_of_bindings

let opens_keepers ~message_mode key =
  (not message_mode) && String.equal key keepers_jump.key

(* An armed two-press action expires on the next unrelated input: otherwise
   it waits indefinitely and a later press of the same key -- after the
   cursor has moved, after a refresh -- submits work the operator armed
   minutes ago for something else.

   Two facts, not one. [input_seen] says the loop actually read something:
   the loop turns on a timeout as well, and a turn that read nothing is not
   an unrelated input. [key] says what it read, and it is [None] for a
   mouse report, a paste, and a graphics reply -- deliberate input that is
   not the second press, so it cancels.

   The rule lives here because the dispatch loop restated it once per armed
   field and the connector unbind's restatement read the timeout turn as an
   unrelated key. Its arm therefore survived one iteration: the two [u]
   presses removed a binding only when both bytes arrived in the same
   read. *)
let cancels_two_press ~input_seen ~key ~second_press =
  input_seen
  &&
  match key with
  | None -> true
  | Some pressed -> not (List.exists (String.equal pressed) second_press)

(* The Fusion detail view: the keys table owns the key list; the renderer
   owns the live scroll numbers it appends after them. ([view] stays
   [Fusion]; [fusion_mode] decides list vs detail — masc_tui_types.ml.)
   [scroll] is the clamped position the renderer computed, so the footer
   agrees with what is on screen. *)
let footer_hints_fusion_detail ~scroll ~max_scroll =
  Printf.sprintf "%s  (%d/%d)"
    (hints_of_bindings
       ([ b Navigate "j/k" "scroll"
        ; b Navigate "PgUp/PgDn" "page"
        ; b Act "Y" "copy"
        ; b Act "Esc" "back" ~help:"Left or Esc returns to the run list"
        ]
        @ listing_meta))
    scroll max_scroll

(* Lanes sub-modes ([lanes_mode] owns overview/list/detail/notice —
   masc_tui_types.ml). The overview footer stays [for_surface Lanes]; these
   name the drill-downs the same way the Fusion detail footer does. *)
let footer_hints_lanes_run_list =
  hints_of_bindings
    ([ b Navigate "j/k" "move" ~help:"move the run cursor"
     ; b Act "Right / Enter" "prompt" ~help:"open the run's prompt and output"
     ; b Act "Left / Esc" "back" ~help:"back to the lane overview"
     ]
     @ listing_meta)

let footer_hints_lanes_run_detail ~scroll ~max_scroll =
  Printf.sprintf "%s  (%d/%d)"
    (hints_of_bindings
       ([ b Navigate "j/k" "compare" ~help:"scroll Input and Output together"
        ; b Navigate "PgUp/PgDn" "page" ~help:"page both evidence panes"
        ; b Act "Left / Esc" "back" ~help:"back to the run list"
        ]
        @ listing_meta))
    scroll max_scroll

let footer_hints_git_changes =
  hints_of_bindings
    ([ b Navigate "j/k" "move"
     ; b Act "Right / d / Enter" "diff"
     ; b Act "v" "open in code"
     ; b Act "p" "open PR"
     ; b Act "t/g" "task / goal"
     ; b Act "Left / Esc" "back"
     ]
     @ listing_meta)

let footer_hints_git_diff =
  hints_of_bindings
    ([ b Navigate "j/k" "scroll"
     ; b Act "v" "open in code"
     ; b Act "p" "open PR"
     ; b Act "t/g" "task / goal"
     ; b Act "Left / Esc" "back to files"
     ]
     @ listing_meta)

(* The Memory fact browser drawn over the health table. Its own row because
   the keys change with it: the cursor moves rows instead of scrolling the
   table, [c] narrows by the categories the loaded store holds, and Esc
   closes the browser rather than leaving the surface. *)
let footer_hints_memory_facts =
  hints_of_bindings
    ([ b Navigate "j/k" "move"
     ; b Act "c / C" "category" ~help:"cycle category filter (forward / backward)"
     ; b Act "s" "sort" ~help:"cycle sort (recency, last retrieved, retrieved count, category, claim)"
     ; b Search "/" "filter" ~help:"live text filter / search"
     ; b Search "n / N" "next / previous match"
     ; b Act "Esc" "close / clear" ~help:"clear filter or exit to health table"
     ]
     @ listing_meta)

let footer_hints_metrics =
  hints_of_bindings (for_surface Metrics)

(* One section per surface family; the strip's spelling names it. Keepers
   sub-modes collapse into the two sections an operator thinks in. *)
let help_surfaces : (string * surface) list =
  [ "Overview", Overview
  ; "Activity", Acting
  ; "Metrics", Metrics
  ; "Keepers", Keepers Keeper_list
  ; "Keeper detail", Keepers Keeper_detail
  ; "Chat", Keepers Keeper_message
  ; "Runtime / Lanes", Lanes
  ; "Runtime / Clients", Clients
  ; "Board", Board
  ; "Approvals", Approvals
  ; "Planning / Goals", Planning
  ; "Planning / Task Review", Verification
  ; "Planning / Verdicts", Harness
  ; "Fusion", Fusion
  ; "Keeper detail / Automation", Schedules
  ; "Memory", Memory
  ; "Workspace", Repositories
  ; "Workspace / Code", Code
  ; "Changes", Changes
  ; "Runtime", Runtime
  ; "Config", Config
  ; "Config / Resources", Resources
  ; "Config / Tools", Tools
  ; "Activity / Logs", System_logs
  ]

let entries bindings =
  List.map
    (fun { key; label; help; _ } -> (key, Option.value help ~default:label))
    bindings

(* The reader's own surface first, then the keys that work everywhere, then
   the rest as reference. A sheet that opens on Planning while the reader is
   on Overview is a list to search rather than an answer: the question [?]
   asks is "what can I do here", and twenty other surfaces are what sits
   underneath that answer.

   [current] is matched exactly rather than by ring position. The Keepers
   sub-modes are three sections here and one entry on the strip, and a reader
   in the chat is asking for the chat's keys, not the roster's. A surface with
   no section of its own simply matches nothing and the sheet reads as it did
   before this argument existed. *)
let here_marker = " \xc2\xb7 you are here"

(* The Keeper detail tabs. Until 2026-08-30 the renderer drew these as
   hand-written strings in its own [tab_hint] match, so the detail tabs were
   a second key list this module did not own -- the exact split the header
   above says cannot happen. [T] was missing from that string as well as
   from here, so toggling a provider was undocumented on every screen.

   The tabs' keys are conditional on the tab rather than the surface, which
   is why they are not in [for_surface]: listing them there would advertise
   them on the five tabs where they do nothing. *)
let keeper_detail_tab_bindings (tab : Masc_tui_types.keeper_detail_tab) =
  match tab with
  | Detail_github -> [ b Act "L" "login" ~help:"start the gh device-flow login" ]
  | Detail_sandbox ->
      [ b Act "o" "actual logs"
      ; b Act "d/m/s" "backend"
          ~help:"set the sandbox backend in place: docker / microvm / remote_ssh"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Meta "R" "refresh"
      ]
  | Detail_instructions ->
      [ b Act "e" "edit JSON in $EDITOR"
          ~help:"the settings form; only changed fields are sent"
      ]
  | Detail_identity ->
      [ (* Arrows first: the digits only reach the first nine rows and the
           list is a declaration directory that can hold more. *)
        b Navigate "arrows+enter" "connect"
      ; b Act "T" "toggle" ~help:"turn the provider under the cursor on or off"
      ; b Act "A" "app" ~help:"open the app-registration form for it"
      ; b Search "/" "filter"
      ; b Meta "R" "refresh"
      ]
  | Detail_channels ->
      [ b Navigate "j/k" "transport"
      ; b Navigate "J/K" "binding"
      ; b Navigate "PgUp/PgDn" "detail page"
      ; b Act "b / e / u u" "bind / reassign / remove"
          ~help:"bind a channel, reassign the selected row, or remove it twice-confirmed"
      ]
  | Detail_info | Detail_secrets | Detail_automation | Detail_runs -> []

(* The compact strip beside the tab row. Same [key:label] spelling the
   footer uses, and the tab switch leads because it is on every tab. *)
let keeper_detail_tab_hint tab =
  String.concat "  "
    ("[ ]:tab"
     :: List.map
          (fun binding -> binding.key ^ ":" ^ binding.label)
          (keeper_detail_tab_bindings tab))

let help_sections ?current () =
  let sections =
    List.map
      (fun (title, surface) ->
         (* The Keeper detail tabs each own keys the surface list cannot
            hold, and the sheet is where a reader looks for them. Append
            them under the surface with the tab named, so [?] answers
            "what does T do" -- which nothing did before 2026-08-30. *)
         let tab_entries =
           match surface with
           | Keepers Keeper_detail ->
               List.concat_map
                 (fun tab ->
                    List.map
                      (fun (key, help) ->
                         ( key
                         , Printf.sprintf "on the %s tab: %s"
                             (Masc_tui_types.keeper_detail_tab_label tab)
                             help ))
                      (entries (keeper_detail_tab_bindings tab)))
                 Masc_tui_types.keeper_detail_tabs
           | _ -> []
         in
         (surface, (title, entries (for_surface surface) @ tab_entries)))
      help_surfaces
  in
  let here, rest =
    match current with
    | None -> ([], sections)
    | Some current ->
        List.partition (fun (surface, _) -> surface = current) sections
  in
  List.map (fun (_, (title, keys)) -> (title ^ here_marker, keys)) here
  @ ("Global", entries global)
    :: List.map (fun (_, section) -> section) rest
