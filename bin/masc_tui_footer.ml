(** Status facts every surface footer ends with.

    A screen supplies only its own key hints. The facts, their order, and the
    separator between them live here, so adding a fact or changing how one
    reads is a single edit instead of one per surface. Before this module the
    21 footers each spelled [Port: %d] themselves and nothing made them agree. *)

type status_item =
  | Refresh_interval of float
  | Server_build of
      { version : string
      ; commit : string
      }
  | Server_base_path of string
  (* The workspace the TUI itself resolved, said only when it is not the one
     the server resolved. [Server_base_path] already names the server's, so
     the pair reads as the disagreement it is. *)
  | Workspace_mismatch of string
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
  (* Keepers mid-turn right now, first name first. The operator who sent a
     message and walked to another surface reads the answer's progress here
     instead of standing on the chat pane. Empty list draws nothing.
     [lead_elapsed_s] is how long the first keeper's turn has been running,
     derived by the caller against its own clock; a stalled turn shows up as
     a badge that keeps counting instead of a name that never changes. *)
  | Keeper_answering of
      { names : string list
      ; lead_elapsed_s : int option
      }
  (* A turn that just finished: the other half of the walked-away question.
     [seconds_ago] is derived by the caller against its own clock; [more]
     counts further finishes folded behind this one. *)
  | Keeper_answered of
      { name : string
      ; seconds_ago : int
      ; more : int
      }
  | Port of int

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
  | Workspace_identity
  | Build_identity
  | Refresh_context
  (* Live turn activity outlasts the identity facts a keeper list can also
     answer, but yields to the conflict notice and the port. *)
  | Live_activity
  (* Last to go. A footer with no room for the port still has room to say the
     screen is reading two different workspaces. *)
  | Workspace_conflict

type projected_status =
  { text : string
  ; retention : retention
  }

(* Minute precision past the first minute: the footer refreshes with the
   poll, and pretending to seconds it does not have would read as drift. *)
let coarse_age seconds =
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else Printf.sprintf "%dm" (seconds / 60)
;;

let status_item_projection = function
  | Refresh_interval seconds when Float.is_finite seconds && seconds > 0. ->
    Some
      { text = Printf.sprintf "Refresh: %.0fs" seconds
      ; retention = Refresh_context
      }
  | Refresh_interval _ -> None
  | Server_build { version; commit } ->
    let version = String.trim version in
    let commit = String.trim commit in
    (match version, short_commit commit with
     | "", "" -> None
     | version, "" -> Some { text = "v" ^ version; retention = Build_identity }
     | "", commit -> Some { text = commit; retention = Build_identity }
     | version, commit ->
       Some
         { text = Printf.sprintf "v%s %s" version commit
         ; retention = Build_identity
         })
  | Server_base_path "" -> None
  | Server_base_path path ->
    Some { text = "Base: " ^ path; retention = Workspace_identity }
  | Workspace_mismatch "" -> None
  | Workspace_mismatch local ->
    Some
      { text = "MISMATCH local " ^ local ^ " (r:retry)"
      ; retention = Workspace_conflict
      }
  | Server_worktree_binary ->
    Some
      { text = "WORKTREE server (not the root build)"
      ; retention = Workspace_conflict
      }
  | Tui_build_mismatch { tui; server; older } ->
    let action =
      match older with
      | `Tui -> "restart masc"
      | `Server -> "server is older \xe2\x80\x94 redeploy"
      | `Unknown -> "generations differ"
    in
    Some
      { text =
          Printf.sprintf "TUI %s \xe2\x89\xa0 server %s (%s)"
            (short_commit tui) (short_commit server) action
      ; retention = Workspace_conflict
      }
  | Keeper_answering { names = []; _ } -> None
  | Keeper_answering { names = name :: rest; lead_elapsed_s } ->
    let elapsed =
      match lead_elapsed_s with
      | None -> ""
      | Some seconds -> " " ^ coarse_age seconds
    in
    let tail =
      match rest with [] -> "" | _ -> Printf.sprintf " +%d" (List.length rest)
    in
    Some
      { text =
          Printf.sprintf "\xe2\x97\x8c answering %s%s%s" name elapsed tail
      ; retention = Live_activity
      }
  | Keeper_answered { name; seconds_ago; more } ->
    let ago = coarse_age (max 0 seconds_ago) in
    let tail = if more > 0 then Printf.sprintf " +%d" more else "" in
    Some
      { text =
          Printf.sprintf "\xe2\x9c\x93 %s answered %s ago%s" name ago tail
      ; retention = Live_activity
      }
  | Port port when port > 0 ->
    Some { text = Printf.sprintf "Port: %d" port; retention = Endpoint_identity }
  | Port _ -> None

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
  [ Refresh_context
  ; Build_identity
  ; Workspace_identity
  ; Live_activity
  ; Endpoint_identity
  ; Workspace_conflict
  ]

(* What ends a row that had to give something up. The ellipsis says items
   were dropped; the key says where they went.

   The ellipsis alone stops one question short. It reports a cut and leaves
   the reader unable to tell whether one key is hidden or six, and on the
   surfaces that reach here -- Keepers, Approvals, Board, Verification,
   Harness, Changes, Tools at eighty columns -- the dropped keys have no
   other way of being found. [?] opens the sheet, and [help_sections
   ~current] puts the reader's own surface at the top of it, so what was
   dropped is the first thing on the screen that follows.

   The key travels alone where something else already marked the cut.
   Cell truncation ends in [~], and [~...?] marks one cut twice -- a row that
   was cut is cut, and saying so in two alphabets is noise. *)
let more_key = "?"
let cut_marker = "\xe2\x80\xa6" ^ more_key

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
let never_dropped_keys = [ "Esc"; "q"; "y / n" ]

let item_is_pinned item =
  (* Items are [key:label]; the key is what the projection built the item
     from, and the first colon is where it ends. A label may hold colons of
     its own -- "Enter:edit / use" -- so only the first one splits. *)
  match String.index_opt item ':' with
  | None -> false
  | Some i ->
    let key = String.trim (String.sub item 0 i) in
    List.exists
      (fun pinned ->
        String.equal key pinned
        (* [Left / Esc] and [Right / Esc] are the same door under a compound
           spelling; the surfaces that write it that way mean the same key. *)
        || (String.equal pinned "Esc"
            && String.length key > 4
            && String.equal (String.sub key (String.length key - 4) 4) " Esc"))
      never_dropped_keys

let drop_hint_items ~max_cells hints =
  let items =
    split_on_double_space hints
    |> List.filter (fun item -> not (String.equal (String.trim item) ""))
  in
  let fits kept =
    let candidate = "  " ^ String.concat "  " kept ^ "  " ^ cut_marker in
    Masc_tui_message_layout.display_width candidate <= max_cells
  in
  (* The last item that may be dropped, by index. [None] once only pinned
     items are left, which is when this gives up and the caller truncates by
     cells instead. *)
  let last_droppable kept =
    List.fold_left
      (fun (index, found) item ->
        (index + 1, if item_is_pinned item then found else Some index))
      (0, None)
      kept
    |> snd
  in
  let rec fit kept =
    match kept with
    | [] -> None
    | _ when fits kept -> Some ("  " ^ String.concat "  " kept ^ "  " ^ cut_marker)
    | _ ->
      (match last_droppable kept with
       | None -> None
       | Some index -> fit (List.filteri (fun i _ -> i <> index) kept))
  in
  fit items

let rec fit_body ~max_cells ~hints ~omissions statuses =
  let rendered = body hints statuses in
  if Masc_tui_message_layout.display_width rendered <= max_cells then rendered
  else
    match statuses, omissions with
    | [], _ ->
      (* Nothing left to drop whole, so the hints themselves give way. Whole
         items go first ({!drop_hint_items}); cell truncation is what is left
         when even one item will not fit. Both end in {!cut_marker}, which
         says the row was cut and says where the rest is. *)
      (match drop_hint_items ~max_cells hints with
       | Some fitted -> fitted
       | None ->
         let room =
           max_cells - Masc_tui_message_layout.display_width more_key
         in
         if room <= 0 then Masc_tui_message_layout.fit_width rendered max_cells
         else Masc_tui_message_layout.fit_width rendered room ^ more_key)
    | _, retention :: rest ->
      fit_body ~max_cells ~hints ~omissions:rest
        (List.filter (fun status -> status.retention <> retention) statuses)
    | _, [] -> fit_body ~max_cells ~hints ~omissions:[] []

(** [line ~dim ~reset ~max_cells ~port ~hints] is one footer line, terminated by a
    newline. [Port] closes every footer and is appended here; [status] carries
    only the extra facts a surface has, in the order they should read.

    Key hints retain the row before status facts do. When the facts do not fit,
    whole typed items are omitted in this order: refresh interval, build, base
    path, port, workspace mismatch. Only an overlong surface-owned hint uses
    cell-safe truncation
    as the final fallback. *)
let line ?(status = []) ~dim ~reset ~max_cells ~port ~hints () =
  let statuses =
    List.filter_map status_item_projection (status @ [ Port port ])
  in
  let fitted =
    fit_body ~max_cells:(max 0 max_cells) ~hints ~omissions:omission_order
      statuses
  in
  Printf.sprintf "%s%s%s\n" dim fitted reset

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

let chat_hints ~enter_hint ~scroll_hint ~switch_hint ~escape_hint ~leave_hint =
  Printf.sprintf
    "%s  Ctrl-J:newline  Ctrl-R:reasoning  Ctrl-D:tools  Ctrl-N:journal  \
     Ctrl-F:metadata  Ctrl-O:image  %s%s  %s%s  Ctrl-U:clear  Ctrl-W:word"
    enter_hint scroll_hint switch_hint escape_hint leave_hint

(** Below 120 columns the fixed set drops to what leaves room for the message
    itself; {!line}'s fitting machinery trims from the tail beyond that. *)
let compact_chat_hints ~enter_hint ~scroll_hint ~escape_hint =
  Printf.sprintf
    "%s  Ctrl-J:NL  Ctrl-R:reasoning  Ctrl-D:tools  Ctrl-N:journal  \
     Ctrl-F:metadata  %s  %s"
    enter_hint scroll_hint escape_hint
