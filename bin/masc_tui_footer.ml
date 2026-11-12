(** Status facts every surface footer ends with.

    A screen supplies only its own key hints. The facts, their order, and the
    separator between them live here, so adding a fact or changing how one
    reads is a single edit instead of one per surface. Before this module the
    21 footers each spelled [Port: %d] themselves and nothing made them agree. *)

type task_creation_phase = Task_not_started | Task_reserved | Task_preparing | Task_awaiting_reply | Task_awaiting_application

type status_item =
  | Task_creation of { keeper : string; phase : task_creation_phase }
  (* The workspace the TUI itself resolved, said only when it is not the one
     the server resolved. *)
  | Workspace_mismatch of string
  | Workspace_unconfirmed
  (* Cached rows remain visible, but cannot authorize a new request. *)
  (* The server's executable resolved inside .worktrees/: a working tree's
     build is serving live traffic. Said only when the health probe says so;
     an older server that cannot say stays silent. *)
  | Server_worktree_binary
  (* This TUI binary and the server were built from different commits.
     [older] names which side to rebuild when both ages are known; built by
     {!build_mismatch_item}, never by hand. *)
  | Tui_build_mismatch of
      { tui : string
      ; server : string
      ; older : [ `Tui | `Server | `Unknown ]
      }
  (* A destructive action armed and waiting for its key again, or one already
     running. Neither is a key hint: [?] cannot recover "press d again to delete
     analyst", and the next unrelated key cancels the arm, so a row that drops it
     drops the only notice of a state the operator is standing in. Here rather
     than in a surface's hint string so the fitter can keep it whole. *)
  | Keeper_action_armed of
      { key : string
      ; action : string
      ; keeper : string
      }
  | Keeper_action_running of
      { gerund : string
      ; keeper : string
      }
  (* The server's rollup says the operator has to act: credit to add, a key to
     change, a Keeper to move to a route with quota left (RFC-0484 §3.3).
     [notice] summarizes the observed count in the current UI language;
     [detail] names where to read every reason. Built only from a non-empty
     list. A narrow row keeps the notice, without clipping a diagnostic. *)
  | Operator_action of
      { notice : string
      ; detail : string
      }
  | Port of int

(* A working surface needs decisions and warnings. Passive diagnostics and
   other Keepers' activity have their own System/Activity surfaces. *)
let needs_operator = function
  | Workspace_mismatch _ | Workspace_unconfirmed | Server_worktree_binary | Tui_build_mismatch _
  | Keeper_action_armed _ | Keeper_action_running _ | Task_creation _ | Operator_action _ -> true
  | Port _ -> false

(* Enough of the commit to tell two checkouts apart, which is the question
   this answers: [Port: 8935] alone is the same on every build that ever
   served that port. *)
let commit_prefix_length = 7

let short_commit commit =
  if String.length commit <= commit_prefix_length
  then commit
  else String.sub commit 0 commit_prefix_length

type retention =
  | Endpoint_identity
  (* Live task activity yields to the conflict notice and the port. *)
  | Live_activity
  (* Ahead of every conflict. A conflict says the screen is reading the wrong
     thing, which stays true on the next frame; an armed action is a question
     waiting for one keypress and gone after any other. *)
  | Armed_action
  (* Last to go. A footer with no room for the port still has room to say the
     screen is reading two different workspaces. *)
  | Workspace_conflict
  | Build_conflict
  | Worktree_conflict
  (* Leads the row like a conflict: left in the tail it is dropped on every
     surface whose keys fill the row, and nothing else on any surface says the
     operator has something to fix. It follows the conflicts, which say
     whether this screen can be trusted at all. *)
  | Operator_notice

(* [shorter] is the same notice in fewer cells, longest first. A notice that
   leads the row is drawn in the next of them before it is given up; a status
   fact in the tail has none and goes whole. A notice has none where the
   shorter text would stop saying what it is about, as an armed action that
   must keep naming its Keeper. *)
type projected_status =
  { text : string
  ; retention : retention
  ; shorter : string list
  }

let status_item_projection ~ko = function
  | Task_creation {keeper;phase} ->
    let say korean english = if ko then korean else english in
    let stage = match phase with
      | Task_not_started -> say "시작 전" "not started"
      | Task_reserved -> say "준비 대기" "waiting to prepare"
      | Task_preparing -> say "준비 중" "preparing"
      | Task_awaiting_reply -> say "응답 대기" "awaiting reply"
      | Task_awaiting_application -> say "결과 반영 대기" "result awaiting UI" in
    Some
      { text = Printf.sprintf (if ko then "%s 작업 만들기: %s" else "Task for %s: %s") keeper stage
      ; retention = Live_activity
      ; shorter = []
      }
  | Workspace_mismatch "" -> None
  | Workspace_mismatch local ->
    Some
      { text =
          (if ko then "공간 불일치 \xc2\xb7 로컬 " ^ local ^ " (r:다시 시도)"
           else "MISMATCH local " ^ local ^ " (r:retry)")
      ; retention = Workspace_conflict
      ; shorter = []
      }
  | Workspace_unconfirmed ->
    Some
      { text = (if ko then "[공간 확인 대기]" else "[workspace unconfirmed]")
      ; retention = Workspace_conflict
      ; shorter = []
      }
  | Server_worktree_binary ->
    Some
      { text =
          (if ko then "worktree 서버 (루트 빌드 아님)"
           else "WORKTREE server (not the root build)")
      ; retention = Worktree_conflict
      ; shorter = []
      }
  | Tui_build_mismatch { tui; server; older } ->
    let action =
      match older with
      | `Tui -> if ko then "masc 다시 시작" else "restart masc"
      | `Server ->
          if ko then "서버가 더 오래됨 \xc2\xb7 다시 배포"
          else "server is older \xc2\xb7 redeploy"
      | `Unknown -> if ko then "세대 다름" else "generations differ"
    in
    Some
      { text =
          Printf.sprintf
            (if ko then "TUI %s \xe2\x89\xa0 서버 %s (%s)" else "TUI %s \xe2\x89\xa0 server %s (%s)")
            (short_commit tui) (short_commit server) action
      ; retention = Build_conflict
      ; shorter = []
      }
  | Keeper_action_armed { key; action; keeper } ->
    Some
      { text =
          (if ko then Printf.sprintf "%s 한 번 더 누르면 %s %s" key keeper action
           else Printf.sprintf "press %s again to %s %s" key action keeper)
      ; retention = Armed_action
      ; shorter = []
      }
  | Operator_action { notice; detail } ->
    Some
      { text = Printf.sprintf "%s \xc2\xb7 %s" notice detail
      ; retention = Operator_notice
      ; shorter = [ notice ]
      }
  | Keeper_action_running { gerund; keeper } ->
    Some
      { text =
          (if ko then Printf.sprintf "%s %s\xe2\x80\xa6" keeper gerund
           else Printf.sprintf "%s %s\xe2\x80\xa6" gerund keeper)
      ; retention = Armed_action
      ; shorter = []
      }
  | Port port when port > 0 ->
    Some
      { text = Printf.sprintf (if ko then "포트: %d" else "Port: %d") port
      ; retention = Endpoint_identity
      ; shorter = []
      }
  | Port _ -> None

let with_literal_prefix prefix hints =
  match prefix with None -> hints | Some text -> text ^ "  " ^ hints

(* Where a scrolling surface stands in what it is scrolling, at the end of
   the row.

   It is its own argument rather than two spaces and a string on the end of
   [hints] because the fitter reads that string as key items and gives up
   the last one first. A position has no key to look up -- [?] opens the key
   sheet, and the sheet does not say where a run detail's scroll sits -- so
   it was the one item on the row that could not be recovered, and it was the
   first to go. Measured on the Fusion run detail: at sixty and at eighty
   columns the row never drew it.

   Kept with the pinned keys. A row that cannot draw its position beside the
   way out is a row with no cells to spare, and the marker says so. *)
let with_position position hints =
  match position with None -> hints | Some text -> hints ^ "  " ^ text

let body hints statuses =
  match statuses with
  | [] -> "  " ^ hints
  | _ ->
    Printf.sprintf "  %s  | %s" hints
      (String.concat " | " (List.map (fun status -> status.text) statuses))

(** The generation check behind {!Tui_build_mismatch}: [None] when the two
    binaries match, or when either side cannot testify (a TUI built outside
    git has no embedded commit; an older server sends none) — unknown must
    not warn. When both commit ages are known, the older side names the
    action; otherwise the mismatch is stated without blaming a lane. *)
let build_mismatch_item ~tui_commit ~tui_age_s ~server_commit ~server_age_s =
  match tui_commit, server_commit with
  | None, _ -> None
  | _, "" -> None
  | Some tui, server when String.equal tui server -> None
  | Some tui, server ->
    let older =
      match tui_age_s, server_age_s with
      | Some tui_age, Some server_age ->
        if Float.compare tui_age server_age > 0 then `Tui else `Server
      | Some _, None | None, Some _ | None, None -> `Unknown
    in
    Some (Tui_build_mismatch { tui; server; older })
;;

let omission_order =
  [ Live_activity
  ; Endpoint_identity
  ]

(* A conflict notice leads the row instead of riding its tail.

   The tail is given up whole before a single hint is, so a notice left there
   cannot be read on any surface whose own keys already fill the row. Measured
   2026-09-12 with the server one commit behind the TUI: of seven surfaces at
   150 columns only Activity drew the notice -- Memory, Overview, Board,
   Keepers, Workspace and Planning all dropped it, and Memory was the screen
   whose rows the older server had just made undecodable.

   Leading notices stay structured while [drop_hint_items] gives up keys
   before them; path spaces are data, never hint separators. The
   keys it crowds out have [?] as a second way to be found. The notice has
   none: nothing else on any surface says the server is not this build. *)
let leads_the_row item =
  match item.retention with
  | Armed_action | Workspace_conflict | Build_conflict
  | Worktree_conflict | Operator_notice ->
    true
  | Endpoint_identity | Live_activity -> false

(* An armed action first: it is the only one of these the next keypress can
   lose. Then the wrong-workspace read, which decides whether anything on the
   screen can be answered at all. Caller list order does not establish
   retention priority. *)
let conflict_order =
  [ Armed_action
  ; Workspace_conflict
  ; Build_conflict
  ; Worktree_conflict
  ; Operator_notice
  ]

let ordered_conflicts items =
  List.concat_map (fun retention ->
    List.filter (fun item -> item.retention = retention) items) conflict_order

(* The ellipsis says items were omitted. The help key follows only where
   the current input owner lets it open the sheet; a text draft owns [?] as
   content. When cell truncation already supplies the ellipsis, append only
   the available help key rather than marking the cut twice. *)
let more_key = "?"
let cut_marker more_key = "\xe2\x80\xa6" ^ more_key

let with_position_and_marker ~more_key ~mark_omission position hints =
  let positioned = with_position position hints in
  if mark_omission then positioned ^ "  " ^ cut_marker more_key else positioned

(* Hints are "key:action" items separated by two spaces. When even an empty
   status tail leaves the row too wide, whole items drop from the back and
   {!cut_marker} ends the row -- a reader sees "later keys omitted, press
   this", never half a word. Items keep their order: the surface put the
   load-bearing keys first. *)
let split_on_double_space text =
  let n = String.length text in
  let rec loop start i acc =
    if i >= n then
      let piece = String.sub text start (n - start) in
      List.rev (piece :: acc)
    else if i + 1 < n && text.[i] = ' ' && text.[i + 1] = ' ' then
      let piece = String.sub text start (i - start) in
      let rec skip j = if j < n && text.[j] = ' ' then skip (j + 1) else j in
      let next = skip (i + 2) in
      loop next next (piece :: acc)
    else loop start (i + 1) acc
  in
  loop 0 0 []

(* What a cut row keeps whatever else it loses.

   Dropping from the back is right for the tail it was written for: [r],
   [Tab] and [q] are the same on every surface, so a reader learns them once
   and the sheet holds them. It stops being right where the row is fullest.
   Measured at 160 usable cells: the chat pane lost [Esc] -- which is also
   how a running turn is interrupted -- and [y / n], which answers the
   approval a Keeper is waiting on; Config lost the [Esc] that leaves it.

   The rule is not a priority list, it is one sentence: a row may lose what
   the reader can look up, and it does not lose the way out. [Esc] leaves,
   [q] quits, [y / n] answers what is being asked. The three are spelled the
   same on every surface that has them, so this is a constant rather than a
   per-surface declaration -- one place to read, and no table can forget to
   mark itself.

   A pinned item keeps its position rather than moving to the front: the
   groups print in a fixed order so that the same action sits in the same
   place on every screen, and rescuing an item by moving it would trade one
   of those promises for the other. *)
(* The door in belongs here beside the door out. Measured on the fixture
   server, Code, Board, Planning, Memory and Workspace all drew an eighty-column
   footer with no key that opens the row under the cursor; Memory's was three
   navigation keys and two exits. The cause is structural rather than per
   surface: [Masc_tui_keys.group_rank] puts every Navigate key ahead of every
   Act key and this fitter drops from the back, so the surface's own action is
   the first thing to go once the row is full.

   [Enter] is what that action is called. Nearly every surface the sheet
   lists names exactly one key holding the Enter atom, and on every one of
   them it opens, reads or sends what the cursor is on -- so pinning the atom
   costs one item per row and buys back the one key the surface exists for.
   Code names two, and [footer_hints_code] already drops the history
   overlay's from the panes that have no commits.

   The rest name none, and the pin costs them nothing. Metrics, Keeper detail
   and Config / Tools have no row cursor for Enter to act on. Clients has one
   and no key acts on it, which is a gap in that surface rather than in this
   pin. test_tui_keys names all of them and counts the atom per surface, so
   this paragraph cannot drift from the table it describes. *)
type pinned_key = Key_atom of string | Whole_key of string

(* On Board, [v] and [V] mean opposite votes. A narrow footer that loses
   their pair leaves the action available but hides its direction. *)
let never_dropped_keys =
  [ Key_atom "Esc"; Key_atom "q"; Whole_key "y / n";
    Whole_key "/approve /deny"; Key_atom "Enter";
    Whole_key "a / x"; Whole_key "y / x"; Whole_key "v / V" ]

(* A compound key names its doors one per atom: [Left / Esc], [Right / Esc]
   and [Left/Esc] all hold the Esc door. The pin used to recognise the
   compound only by its " Esc" tail, so a row that spelled it [Left/Esc]
   -- three renderer literals did -- held nothing the fitter would keep,
   and at 60 cells the Board read pane had lost its way out while [z:wide]
   stayed. The single-letter pins are read by atom too; the pairs
   ([y / n], [/approve /deny], [a / x]) name a pair and are matched whole,
   because their atoms are ordinary keys elsewhere: [n] is the next-match key
   on the surfaces that search, [a] creates a keeper and [x] deletes one. *)
let key_atoms key =
  String.split_on_char '/' key
  |> List.concat_map (String.split_on_char ' ')
  |> List.filter (fun atom -> not (String.equal atom ""))

(* An item is [key:label]; the key is what the projection built the item
   from, and the first colon is where it ends. A label may hold colons of
   its own -- "Enter:edit / use" -- so only the first one splits. *)
let item_key item =
  let plain = Masc_tui_theme.strip_sgr item in
  match String.index_opt plain ':' with
  | None -> None
  | Some i -> Some (String.trim (String.sub plain 0 i))

let en_dash = "\xe2\x80\x93"

(* [1-9] and [1–9] name nine keys. The trace compares one key at a time. *)
let digit_range atom =
  let length = String.length atom in
  let is_digit c = c >= '0' && c <= '9' in
  if length >= 3
     && is_digit atom.[0]
     && is_digit atom.[length - 1]
     && atom.[0] <= atom.[length - 1]
     && (let dash = String.sub atom 1 (length - 2) in
         String.equal dash "-" || String.equal dash en_dash)
  then
    List.init
      (Char.code atom.[length - 1] - Char.code atom.[0] + 1)
      (fun offset -> String.make 1 (Char.chr (Char.code atom.[0] + offset)))
  else [ atom ]

(* Every key a hint string names, one atom each: [Right / Enter:open] names
   Right and Enter, [j/k:move] names j and k, [1-9:jump] names the nine
   digits. The navigation trace asks this of the hints a screen was drawn
   with. *)
let advertised_key_atoms hints =
  split_on_double_space hints
  |> List.filter_map item_key
  |> List.concat_map key_atoms
  |> List.concat_map digit_range

let item_is_pinned item =
  match item_key item with
  | None -> false
  | Some key ->
    let atoms = key_atoms key in
    (* The fixed rules already say whether they match an atom or a whole
       key. Only the rendered key needs splitting; fitting a narrow footer
       repeatedly visits these items as lower-priority hints are removed. *)
    List.exists
      (function
        | Whole_key pinned -> String.equal key pinned
        | Key_atom pinned -> List.exists (String.equal pinned) atoms)
      never_dropped_keys

(* The help item every key row names. An operator reading a footer in
   2026-10 could not learn the sheet existed: only the composer's rows said
   "?:help", every other surface named keys the sheet explains and never the
   sheet itself, and the narrow-row cut marker pointed at a key the wide row
   never showed. [ensure_help_item] is the door stamped on at the one seam
   every footer row passes through. The item is deliberately not pinned: a
   row too full for it drops it first and ends in the same marker, so the
   narrow spelling of this door is the cut marker the fitter already draws,
   and a wide row is the one that spells it out. *)
let help_hint_item = "?:help"

(* The same door in the screen's language. One spelling, so the chat rows,
   the Overview's own line and the stamped item cannot name it two ways. *)
let help_hint ~ko = if ko then "?:도움말" else help_hint_item

let ensure_help_item hints =
  let already_names_help =
    split_on_double_space hints
    |> List.exists (fun item ->
        match item_key item with
        | Some key -> List.mem "?" (key_atoms key)
        | None -> false)
  in
  if already_names_help then hints else hints ^ "  " ^ help_hint_item

type hint_item =
  { hint_text : string
  ; pinned : bool
  }

type hint_row =
  { full_text : string
  ; items : hint_item list Lazy.t
  }

let prepare_hints full_text =
  (* This lazy belongs to one synchronous [line] call. No fiber yields or
     shared cache can force it concurrently. A row that fits with no conflict
     never needs to split its hints; every narrower attempt shares the same
     parsed items and pin decisions. Keep [full_text] verbatim for that first
     fit, including the caller's spacing and styles. *)
  let items = lazy (
    split_on_double_space full_text
    |> List.filter (fun item -> not (String.equal (String.trim item) ""))
    |> List.map (fun hint_text ->
        { hint_text; pinned = item_is_pinned hint_text })) in
  { full_text; items }

(* The last key this row may give up, by index. [None] once only pinned keys
   are left. *)
let last_droppable kept =
  List.fold_left
    (fun (index, found) item ->
      (index + 1, if item.pinned then found else Some index))
    (0, None)
    kept
  |> snd

(* One step down for a notice: its next shorter text, or nothing once it has
   none left. *)
let shortened notice =
  match notice.shorter with
  | [] -> None
  | text :: shorter -> Some { notice with text; shorter }

(* The undroppable keys of a hint row: what the narrowest row this fitter can
   draw still has to carry. *)
let undroppable_keys hints =
  Lazy.force hints.items
  |> List.filter_map (fun item ->
      if item.pinned then Some item.hint_text else None)

(* Which notice takes a step down when the set will not fit: its next shorter
   text, or its removal once it has none. The one that cannot be drawn in the
   narrowest row that could carry it -- itself, the keys that cannot be dropped,
   and the marker that says the row was cut -- is the one blocking, whatever it
   ranks. Stepping the lowest-ranked one instead threw away a short, actionable
   build mismatch to keep a long workspace path that then could not be drawn
   either, and the row ended with no notice at all. With none blocking, the
   lowest-ranked one steps.

   The probe in {!line} cannot reject that long notice up front: a row that drops
   nothing carries no marker, and counting one there rejects a notice that fits a
   row exactly. So the marker's cells are counted here, where a step is already
   known to be needed. *)
let without_a_blocking_conflict ?literal_prefix ?position ~more_key ~max_cells ~hints conflicts =
  let cut_marker = cut_marker more_key in
  let undroppable = undroppable_keys hints in
  let narrowest conflict =
    with_position position
      ("  "
       ^ String.concat "  "
           ((conflict.text :: Option.to_list literal_prefix) @ undroppable))
    ^ "  " ^ cut_marker
  in
  let blocking =
    List.filteri
      (fun _ conflict ->
        Masc_tui_message_layout.display_width (narrowest conflict) > max_cells)
      conflicts
  in
  let stepping =
    match blocking, List.rev conflicts with
    | first :: _, _ -> Some first
    | [], lowest :: _ -> Some lowest
    | [], [] -> None
  in
  List.concat_map
    (fun conflict ->
      match stepping with
      | Some target when target == conflict -> Option.to_list (shortened conflict)
      | Some _ | None -> [ conflict ])
    conflicts

(* Keys give way before a notice does, and a notice gives way before the keys
   it crowded out stay gone: every attempt starts from the whole key row again,
   so the cells a dropped notice hands back are offered to the keys.

   One greedy pass could not do that. It dropped every droppable key to make
   room for a long notice, dropped the notice too, and left [q:quit  ...?] on a
   row where several controls would have fit once the notice was gone.

   A notice too wide to be drawn beside the keys that cannot be dropped is
   drawn in a shorter text, or put aside when none is short enough, before
   priority is read. Otherwise one long path would starve a short, actionable
   build mismatch that ranks below it and fits on its own. *)
let drop_hint_items ?literal_prefix ?position ~more_key ~max_cells ~conflicts hints =
  let cut_marker = cut_marker more_key in
  let keys = Lazy.force hints.items in
  let row conflicts kept =
    with_position position
      ("  "
       ^ String.concat "  "
           (List.map (fun conflict -> conflict.text) conflicts
            @ Option.to_list literal_prefix
            @ List.map (fun item -> item.hint_text) kept))
    ^ "  " ^ cut_marker
  in
  let fits conflicts kept =
    Masc_tui_message_layout.display_width (row conflicts kept) <= max_cells
  in
  let rec drop_keys kept =
    if fits conflicts kept then Some (row conflicts kept)
    else
      match last_droppable kept with
      | None -> None
      | Some index -> drop_keys (List.filteri (fun i _ -> i <> index) kept)
  in
  drop_keys keys

(* A notice too wide to be drawn beside the keys that cannot be dropped is
   drawn in a shorter text, or put aside when none is short enough, before
   priority is read. Otherwise one long path would starve a short, actionable
   build mismatch that ranks below it and fits on its own. *)
let drawable_conflicts ?literal_prefix ~max_cells ~hints = function
  | [] -> []
  | conflicts ->
    let undroppable = undroppable_keys hints in
    (* No cut marker in the probe. A row that gives nothing up carries none, and
       counting it here rejected a notice that fits a row exactly. Where a key
       does have to go the marker's cells are counted by the fit itself, which
       then steps the conflict set down -- the probe only has to stop a notice
       that can never be drawn from taking the ranking down with it. *)
    let drawable conflict =
      let row =
        "  "
        ^ String.concat "  "
            ((conflict.text :: Option.to_list literal_prefix) @ undroppable)
      in
      Masc_tui_message_layout.display_width row <= max_cells
    in
    let rec in_the_longest_text_that_fits conflict =
      if drawable conflict then Some conflict
      else Option.bind (shortened conflict) in_the_longest_text_that_fits
    in
    List.filter_map in_the_longest_text_that_fits conflicts

(* What fits with this conflict set kept whole: the status facts give way in
   [omission_order], then the keys give way as whole items. [None] when even the
   keys that cannot be dropped will not fit beside these conflicts. *)
let rec fit_with_conflicts ?literal_prefix ?position ~more_key ~mark_omission ~max_cells
    ~conflicts ~hints ~omissions statuses =
  let leading =
    String.concat "  "
      (List.map (fun item -> item.text) conflicts
       @ Option.to_list literal_prefix
       @ [ with_position_and_marker ~more_key ~mark_omission position hints.full_text ])
  in
  let rendered = body leading statuses in
  if Masc_tui_message_layout.display_width rendered <= max_cells then
    Some rendered
  else
    match statuses, omissions with
    | [], _ -> drop_hint_items ?literal_prefix ?position ~more_key ~max_cells ~conflicts hints
    | _, retention :: rest ->
      fit_with_conflicts ?literal_prefix ?position ~more_key ~mark_omission ~max_cells
        ~conflicts ~hints ~omissions:rest
        (List.filter (fun status -> status.retention <> retention) statuses)
    | _, [] ->
      fit_with_conflicts ?literal_prefix ?position ~more_key ~mark_omission ~max_cells
        ~conflicts ~hints ~omissions:[] []

(* Every notice that has a shorter text, in that text; the others stay as they
   are. *)
let notices_in_their_shorter_text conflicts =
  List.map
    (fun conflict -> Option.value (shortened conflict) ~default:conflict)
    conflicts

(* Dropping a notice hands its cells back to everything that gave way for it,
   the status facts included, so each conflict set is fitted from the whole
   status list and the whole key row again. Shrinking in one pass left a row
   carrying only [q:quit  ...?] where the task line and the port all fit once
   the notice was gone. *)
let rec fit_body ?literal_prefix ?action_text ?position ~more_key ~max_cells ~conflicts ~hints
    ~omissions statuses =
  let cut_marker = cut_marker more_key in
  let prefix_with_action action =
    match Option.to_list literal_prefix @ (if action = "" then [] else [ action ]) with
    | [] -> None
    | parts -> Some (String.concat "  " parts)
  in
  (* Try the complete outcome first. The existing fitter only adds its marker
     after it actually gives up a key; reserving it ahead of this attempt can
     hide an outcome even when the whole row fits exactly. *)
  let complete =
    let prefix = match action_text with
      | None -> literal_prefix
      | Some action -> prefix_with_action action in
    fit_with_conflicts ?literal_prefix:prefix ?position ~more_key ~mark_omission:false
      ~max_cells ~conflicts ~hints ~omissions statuses
  in
  match complete with
  | Some fitted -> fitted
  | None ->
  (* What the last key did is what the operator is looking for, and it stays
     for [last_action_window_s]; a standing notice is on the row every frame.
     So an outcome that does not fit whole beside the notices at full length
     is offered the room their reasons take before it is cut: the notices step
     down to their count, as they do where the keys need the room. Measured on
     the Code pane at 100 cells with ACTION NEEDED naming a 47-cell reason, the
     outcome of [y] kept one cell of 92 ([d…]) and the reason kept all of
     its cells. *)
  let shorter_notices = notices_in_their_shorter_text conflicts in
  let outcome_present =
    match action_text with
    | Some action -> not (String.equal action "")
    | None -> false
  in
  if outcome_present && shorter_notices <> conflicts then
    fit_body ?literal_prefix ?action_text ?position ~more_key ~max_cells
      ~conflicts:shorter_notices ~hints ~omissions statuses
  else
  let displayed_prefix, mark_omission =
    match action_text with
    | None | Some "" -> literal_prefix, false
    | Some action ->
      let shown, mark_omission =
          (* Existing warnings, search status and pinned keys keep their
             space, including on rows without warnings. Only the action
             uses the remaining cells. *)
          let reserved action_parts =
            with_position position
              (body (String.concat "  "
                (List.map (fun conflict -> conflict.text) conflicts
                 @ Option.to_list literal_prefix @ action_parts
                 @ undroppable_keys hints)) [])
            ^ "  " ^ cut_marker in
          (* An empty action item includes its real separator in the row. *)
          let room = max 0 (max_cells
            - Masc_tui_message_layout.display_width (reserved [ "" ])) in
          let shown =
            if Masc_tui_message_layout.display_width action <= room then action
            else Masc_tui_message_layout.fit_width action room in
          shown, (shown = ""
            && Masc_tui_message_layout.display_width (reserved []) <= max_cells)
      in
      let prefix = prefix_with_action shown in
      (* Mark a wholly omitted action when the marker itself fits; a marker
         must not displace the warning or its pinned keys either. *)
      prefix, mark_omission
  in
  match fit_with_conflicts ?literal_prefix:displayed_prefix ?position ~more_key ~max_cells
          ~mark_omission ~conflicts ~hints ~omissions statuses with
  | Some fitted -> fitted
  | None ->
    (match conflicts with
     | _ :: _ ->
       fit_body ?literal_prefix ?action_text ?position ~more_key ~max_cells
         ~conflicts:
           (without_a_blocking_conflict ?literal_prefix ?position ~more_key ~max_cells ~hints
              conflicts)
         ~hints ~omissions statuses
     | [] ->
       (* Never cell-cut a conflict into a different path or diagnosis. Only
          surface hints can use the last-resort text truncation. The position
          rides the hints here: a row this narrow has no cells to keep it in,
          and the marker says the row was cut.

          What is cut is the row [drop_hint_items] reduced to, not the row it
          started from. The keys give way as whole items first, and this path
          is reached only once none of them may give way again -- so the cells
          left belong to the keys that cannot be dropped. Cutting the original
          row instead spent them on the keys the reader can look up: measured
          on the fixture server at sixty cells, Planning's Verification and
          Harness tabs drew [j/k:move  v:next Planning tab  h:queue / history]
          and no way out at all, while the Tasks tab beside them kept
          [Left / Esc:back] and [q:quit]. *)
       let cut_from =
         match undroppable_keys hints with
         | [] -> hints.full_text
         | undroppable -> String.concat "  " undroppable
       in
       let rendered =
         body
           (with_position_and_marker ~more_key ~mark_omission position
              (with_literal_prefix displayed_prefix cut_from))
           []
       in
       let room = max_cells - Masc_tui_message_layout.display_width more_key in
       let marker_room =
         max_cells - Masc_tui_message_layout.display_width cut_marker
       in
       if room <= 0 then Masc_tui_message_layout.fit_width rendered max_cells
       else if
         Masc_tui_message_layout.display_width rendered <= room
         && not (String.ends_with ~suffix:cut_marker rendered)
       then
         (* The keys that cannot be dropped fit the row, and the row still has
            to say that other keys were left out. Cell truncation is what puts
            the ellipsis on a row, and it cuts nothing when the keys fit. A
            bare [?] then followed the padding, or touched the last key as
            [q:quit?] when the keys filled every cell but one. The marker ends
            the row instead and the keys keep the cells it leaves: all of them
            while they fit beside it, one cell short when they fill the row.
            Planning's four pinned keys take 57 of 60 cells. *)
         Masc_tui_message_layout.fit_width
           (Masc_tui_message_layout.take_cells rendered marker_room) marker_room
         ^ cut_marker
       else Masc_tui_message_layout.fit_width rendered room ^ more_key)

(** What the caller would rather the notice slot said than [action_text],
    once it has resolved priority.

    An [Outcome] says what the last key did or why it did nothing. It replaces
    [action_text] only when it fits whole beside the conflicts and the pinned
    keys.

    A [Pending_question] is one that a single further key answers, such as the
    quit confirmation. It is the only thing on the row the next keypress can
    lose, so it leads the row as an armed Keeper action does ({!conflict_order}):
    the notices and the keys that can be dropped give way to it. It is drawn
    beside the pinned keys and the cut marker, or alone when even those do not
    fit, or not at all, and then [action_text] stands. The mark turns a drawn
    text into a press target and is applied only to a text that is drawn. *)
type preferred_action =
  | Outcome of string * (string -> string)
  | Pending_question of string * (string -> string)
  | Menu_choices of string
      (** Draw the choices together when they fit. Otherwise return them to
          the ordinary key-item fitter, which preserves the way out. *)

(** Where a [Pending_question] goes on the row, decided once from the widths:
    in front of the notices and the keys that can be dropped, on a row of its
    own where it fits beside nothing else, or nowhere. *)
type question_place =
  | Leads_the_row of projected_status
  | Alone of string
  | Not_drawn

(** [line ~dim ~reset ~max_cells ~hints] is one footer line, terminated by a
    newline. A diagnostic caller can explicitly supply [port]; normal working
    surfaces keep connection identity on System.

    [literal_prefix] carries surface status such as a search query. Its spaces
    are preserved while the separately supplied hints are split into items.
    [action_text] is a transient outcome of an operator action. Existing
    conflicts, search status and pinned keys retain their space before that
    outcome is cell-cut. A complete outcome is attempted before reserving an
    omission marker, and it cannot disappear as a droppable key hint.
    Key hints retain the row before status facts do. When the facts do not fit,
    whole typed items are omitted in this order: live task activity, port.
    Only an overlong surface-owned hint uses cell-safe truncation as the
    final fallback.

    A conflict notice is the exception: it is rendered in front of the hints
    ({!leads_the_row}) rather than left in the tail, so it outlives the keys
    instead of going before them.

    [help_key_answers] controls whether an omission can offer [?] as a way to
    recover the hidden keys. The caller supplies its current input ownership.

    [preferred_action] is the caller's choice for the notice slot once it has
    resolved priority; {!preferred_action} says what each kind does.

    [ko] picks the language of the status facts. The hints arrive written. *)
let line ?literal_prefix ?action_text ?preferred_action ?position ?(status = []) ?port
    ?(help_key_answers = true) ~ko ~dim ~reset
    ~max_cells ~hints () =
  let max_cells = max 0 max_cells in
  let more_key = if help_key_answers then more_key else "" in
  let cut_marker = cut_marker more_key in
  let hints = prepare_hints hints in
  let statuses =
    List.filter_map (status_item_projection ~ko)
      (status @ Option.to_list (Option.map (fun port -> Port port) port))
  in
  let conflicts, statuses = List.partition leads_the_row statuses in
  (* A question is drawn where it fits whole: beside the keys that cannot be
     dropped and the mark that says the row was cut (the narrowest row the
     fitter can carry, as in [without_a_blocking_conflict]), or alone on the
     row. Where neither holds the caller's [action_text] says why. The mark is
     applied only to a text that is drawn. *)
  let beside_the_pinned_keys text =
    Masc_tui_message_layout.display_width
      (with_position position
         ("  "
          ^ String.concat "  "
              ((text :: Option.to_list literal_prefix) @ undroppable_keys hints))
       ^ "  " ^ cut_marker)
    <= max_cells
  in
  let alone text = Masc_tui_message_layout.display_width ("  " ^ text) <= max_cells in
  let place_question text mark =
    if beside_the_pinned_keys text then
      Leads_the_row { text = mark text; retention = Armed_action; shorter = [] }
    else if alone text then Alone (mark text)
    else Not_drawn
  in
  let place =
    match preferred_action with
    | Some (Pending_question (text, mark)) -> place_question text mark
    | Some (Menu_choices text) -> place_question text Fun.id
    | Some (Outcome _) | None -> Not_drawn
  in
  let fit_row question =
    let hints =
      match question with
      | Some _ -> hints
      | None ->
          (match preferred_action with
           | Some (Menu_choices text) ->
               prepare_hints (text ^ "  " ^ hints.full_text)
           | Some (Outcome _ | Pending_question _) | None -> hints)
    in
    let conflicts =
      drawable_conflicts ?literal_prefix ~max_cells ~hints
        (ordered_conflicts (Option.to_list question @ conflicts))
    in
    (* The caller offers an outcome only after resolving priority. It replaces
       the fallback here only when it fits whole. The marker is added after
       fitting so a clipped marker cannot count as complete evidence. *)
    let action_text =
      match question, preferred_action with
      | Some _, _ -> None
      | None, Some (Outcome (text, mark)) ->
        let prefix = String.concat "  " (Option.to_list literal_prefix @ [text]) in
        let fits_beside conflicts =
          Option.is_some
            (fit_with_conflicts ~literal_prefix:prefix ?position ~more_key ~mark_omission:false
               ~max_cells ~conflicts ~hints ~omissions:omission_order statuses)
        in
        (* Whole beside the notices at full length, or beside their shorter
           text: [fit_body] gives the outcome that room before cutting it. *)
        if fits_beside conflicts || fits_beside (notices_in_their_shorter_text conflicts)
        then Some (mark text)
        else action_text
      | None, (Some (Pending_question _ | Menu_choices _) | None) -> action_text
    in
    let fitted =
      fit_body ?literal_prefix ?action_text ?position ~more_key ~max_cells
        ~conflicts ~hints ~omissions:omission_order statuses
    in
    Printf.sprintf "%s%s%s\n" dim fitted reset
  in
  match place with
  | Alone drawn -> Printf.sprintf "%s  %s%s\n" dim drawn reset
  | Leads_the_row question -> fit_row (Some question)
  | Not_drawn -> fit_row None

(** The chat pane's key hints, with the fixed keys owned here beside the
    fitting machinery. The pane supplies only the holes it alone can answer:
    what Enter does right now, where the scroll sits, whether another Keeper
    is one Ctrl-G away, and what Esc means to the current turn.

    The width test builds its worst case through this same function, so the
    one-row guarantee is proven against the string the pane actually draws.
    As two hand-copies the strings drifted twice — first Ctrl-F/Ctrl-O, then
    Ctrl-N never reached the test's copy. *)
(* The hint line a capture replaces, and the bar that replaces it.

   The chat surface draws its own input row rather than the composer's, so the
   meter that row carries never reaches this screen — and this is the one an
   operator speaks from. A microphone that is hearing them and one that is not
   both end as an empty draft; the bar is what separates those.

   Here rather than inline in the pane so its width can be checked against the
   same one-row budget as the hints it stands in for. *)
let voice_bar ~width ~db =
  let filled =
    match db with
    | None -> 0
    | Some level when level = Float.neg_infinity -> 0
    | Some level -> max 0 (min width (int_of_float ((level +. 60.) /. (60. /. float_of_int width))))
  in
  String.concat "" (List.init filled (fun _ -> "\xe2\x96\x88"))
  ^ String.concat "" (List.init (width - filled) (fun _ -> "\xc2\xb7"))
;;

let voice_bar_width = 16

(* [help_hint] carries the door item -- "  ?:help" or "" -- because in a
   chat [?] opens the sheet only while the draft is empty, and the wide and
   compact rows are drawn in both states. The caller, which can see the
   draft, decides; the minimal rows below always carry the item because the
   empty-draft state they are drawn for is the state where it answers. *)
let chat_hints ~ko ~enter_hint ~scroll_hint ~switch_hint ~escape_hint
    ~leave_hint ~help_hint =
  let say korean english = if ko then korean else english in
  Printf.sprintf
    "%s  Ctrl-J:%s  /:%s  %s%s  %s%s  Ctrl-R:%s  Ctrl-D:%s  Ctrl-N:%s  \
     Ctrl-F:%s  Ctrl-O:%s  Ctrl-U:%s  Ctrl-W:%s%s"
    enter_hint (say "줄바꿈" "newline") (say "명령" "commands") escape_hint
    leave_hint scroll_hint switch_hint (say "추론" "reasoning")
    (say "도구" "tools") (say "기록" "journal") (say "정보" "metadata")
    (say "이미지/다이어그램" "image/diagram") (say "지우기" "clear")
    (say "낱말" "word") help_hint

(** Below 120 columns the fixed set drops to what leaves room for the message
    itself; {!line}'s fitting machinery trims from the tail beyond that. *)
let compact_chat_hints ~ko ~enter_hint ~scroll_hint ~escape_hint ~help_hint =
  let say korean english = if ko then korean else english in
  Printf.sprintf
    "%s  Ctrl-J:%s  /:%s  %s  %s  Ctrl-R:%s  Ctrl-D:%s  Ctrl-N:%s  Ctrl-F:%s%s"
    enter_hint (say "줄바꿈" "NL") (say "명령" "commands") escape_hint
    scroll_hint (say "추론" "reasoning") (say "도구" "tools")
    (say "기록" "journal") (say "정보" "metadata") help_hint

(* Keep discoverability whole before optional editing hints. This projection
   fits the framed inner row, so box_line never cuts a key label in half. *)
let fit_minimal_hints ~max_cells hints =
  List.fold_left (fun shown hint ->
    let candidate = if shown = "" then hint else shown ^ "  " ^ hint in
    if Masc_tui_message_layout.display_width candidate <= max_cells
    then candidate else shown) "" hints

let chat_commands_hint ~ko = if ko then "/:명령" else "/:commands"
let chat_newline_hint ~ko = if ko then "Ctrl-J:줄바꿈" else "Ctrl-J:newline"

let minimal_chat_hints ~ko ~max_cells ~enter_hint ~escape_hint =
  fit_minimal_hints ~max_cells
    [ chat_commands_hint ~ko; help_hint ~ko; enter_hint; escape_hint
    ; chat_newline_hint ~ko ]

let minimal_context_chat_hints ~ko ~max_cells ~context_hints ~escape_hint =
  fit_minimal_hints ~max_cells
    (context_hints
     @ [ chat_commands_hint ~ko; help_hint ~ko; escape_hint
       ; chat_newline_hint ~ko ])
