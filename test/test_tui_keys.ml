(* The display contracts of the key table.

   The table exists so footers and the help overlay stop drifting; these
   tests pin the conventions (one spelling per key, one order per screen)
   and the specific drifts the table was written to close. *)

open Masc_tui_types
module Cat = Masc.Keeper_memory_os_types

let check = Alcotest.check
let str = Alcotest.string

let every_surface =
  [ Overview; Acting; Metrics; Keepers Keeper_list; Keepers Keeper_detail
  ; Keepers Keeper_logs; Keepers Keeper_calls; Keepers Keeper_message
  ; Keepers Keeper_runtime_pick; Lanes; Board; Approvals; Planning
  ; Schedules; Verification; Harness; Fusion; Repositories; Code; Changes
  ; Connectors; Runtime; Clients; Config; Resources; Tools; System_logs
  ; Memory
  ]

(* [Masc_tui_footer.never_dropped_keys] pins the Enter atom, and the comment
   that justifies the pin rests on a claim about this table: that every
   surface names exactly one key holding that atom, so the pin costs one item
   per row and keeps the key the surface exists for. Nothing checked the
   claim, and it is not true of five of the sheet's surfaces -- four name no
   Enter key at all and Code names two.

   Four of the five are the same answer in different words: a surface with no
   row cursor has nothing for Enter to open. Clients is not. It moves a
   cursor, jumps that cursor to a search match and draws the row it lands on
   selected, and then no key acts on the selection -- [masc_tui.ml] gives it
   cursor scrolling and [Clients -> None] for the row's link.

   Named together the way the [ / ] table below is, so the next surface that
   arrives with a cursor and nothing to open has to be a decision. *)
let enter_atom_count_exceptions =
  [ (* Charts, not a list: [j/k] scrolls. *)
    "Metrics", 0
  ; (* A detail screen. Its tabs carry their own keys. *)
    "Keeper detail", 0
  ; (* A roster with a cursor and nothing the cursor opens. *)
    "Config / Runtime / Clients", 0
  ; (* A scrolling reading, not a row list. *)
    "Config / Tools", 0
  ; (* The second is the history overlay's, which [footer_hints_code] drops
       from the panes that have no commits. *)
    "Workspace / Code", 2
  ; (* [e / Enter] edits on params and [Enter] uses on themes.
       [footer_hints_config ~pane] never draws both: this count is of the
       union the help sheet shows, not of any footer. The per-pane form of
       this check is [test_every_config_pane_answers_once] below, which is
       stricter than the one here -- it asks seven screens, not one union. *)
    "Config", 2
  ]

let test_every_surface_names_one_key_that_acts_on_the_cursor () =
  List.iter
    (fun (label, surface) ->
      let enter_keys =
        List.filter_map
          (fun (b : Masc_tui_keys.binding) ->
            if List.exists (String.equal "Enter") (Masc_tui_keys.key_atoms b.Masc_tui_keys.key)
            then Some b.Masc_tui_keys.key
            else None)
          (Masc_tui_keys.for_surface surface)
      in
      let want =
        match List.assoc_opt label enter_atom_count_exceptions with
        | Some n -> n
        | None -> 1
      in
      Alcotest.(check int)
        (Printf.sprintf "%s names %d key(s) holding the Enter atom (found: %s)"
           label want (String.concat " | " enter_keys))
        want (List.length enter_keys))
    Masc_tui_keys.help_surfaces

(* An exception that names a surface the sheet no longer lists stops being a
   decision and becomes a line nobody reads. *)
let test_every_enter_atom_exception_names_a_sheet_surface () =
  List.iter
    (fun (label, _) ->
      Alcotest.(check bool) (Printf.sprintf "%s is still a surface the sheet lists" label) true
        (List.mem_assoc label Masc_tui_keys.help_surfaces))
    enter_atom_count_exceptions

let test_every_surface_answers () =
  List.iter
    (fun surface ->
      Alcotest.(check bool)
        "a surface with no bindings has no footer and no help row" true
        (Masc_tui_keys.for_surface surface <> []))
    every_surface

let test_no_surface_repeats_a_key () =
  List.iter
    (fun surface ->
      let keys =
        List.map
          (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
          (Masc_tui_keys.for_surface surface)
      in
      Alcotest.(check int)
        (Printf.sprintf "each key appears once per surface (keys: %s)"
           (String.concat ", " keys))
        (List.length keys)
        (List.length (List.sort_uniq compare keys)))
    every_surface

let test_one_spelling_per_key () =
  (* The old footers wrote Esc, esc, and enter for the same keys. *)
  List.iter
    (fun surface ->
      List.iter
        (fun (b : Masc_tui_keys.binding) ->
          let k = b.Masc_tui_keys.key in
          Alcotest.(check bool)
            (Printf.sprintf "%S spells its key canonically" k)
            false
            (List.mem k [ "esc"; "enter"; "tab"; "ESC"; "Return" ]))
        (Masc_tui_keys.for_surface surface))
    every_surface

(* The blacklist above catches the three spellings that were already in the
   footers; it cannot catch a spelling nobody has written yet. This is the
   invariant it stands for: one key, one spelling, wherever it appears. The
   operator reads footers across surfaces, so "PgUp/PgDn" here and
   "PgUp / PgDn" one screen over is a key they have to recognise twice. *)
let test_a_key_is_spelled_one_way_across_every_surface () =
  let spellings = Hashtbl.create 64 in
  List.iter
    (fun surface ->
      List.iter
        (fun (b : Masc_tui_keys.binding) ->
          let k = b.Masc_tui_keys.key in
          let bare = String.concat "" (String.split_on_char ' ' k) in
          let seen = try Hashtbl.find spellings bare with Not_found -> [] in
          if not (List.mem k seen) then
            Hashtbl.replace spellings bare (k :: seen))
        (Masc_tui_keys.for_surface surface))
    every_surface;
  Hashtbl.iter
    (fun bare seen ->
      Alcotest.(check int)
        (Printf.sprintf "%S is spelled one way (found: %s)" bare
           (String.concat " | " seen))
        1 (List.length seen))
    spellings

(* The handler pages the Config body in three panes (masc_tui.ml walks
   [Config when config_pane = Config_prompts || = Config_presets] and
   [= Config_runtime]), and the footer advertised the keys while the table did
   not -- so the help sheet, which projects from the table, could not answer
   what PgUp does here. *)
let test_config_declares_the_page_keys_it_handles () =
  (* [for_surface] takes a surface, not a pane, so the sheet cannot narrow this
     to the three panes the dispatcher pages. The help text is where the sheet
     says so -- without it the key reads as working on all seven. *)
  match
    List.find_opt
      (fun (b : Masc_tui_keys.binding) ->
        String.equal b.Masc_tui_keys.key "PgUp/PgDn")
      (Masc_tui_keys.for_surface Config)
  with
  | None -> Alcotest.fail "Config does not name the page keys it handles"
  | Some binding ->
      let help = Option.value binding.Masc_tui_keys.help ~default:"" in
      let names pane =
        let n = String.length pane in
        let rec seek i =
          i + n <= String.length help
          && (String.equal (String.sub help i n) pane || seek (i + 1))
        in
        seek 0
      in
      Alcotest.(check bool) "and says it pages the runtime.toml pane" true
        (names "runtime.toml");
      Alcotest.(check bool) "and the prompts pane" true (names "prompts");
      Alcotest.(check bool) "and the presets pane" true (names "presets")

let test_chat_help_names_memory_cycle () =
  let bindings = Masc_tui_keys.for_surface (Keepers Keeper_message) in
  match
    List.find_opt
      (fun (binding : Masc_tui_keys.binding) -> String.equal binding.key "Ctrl-N")
      bindings
  with
  | None -> Alcotest.fail "chat help omitted the Ctrl-N Memory shortcut"
  | Some binding ->
      check (Alcotest.option str) "Memory cycle help"
        (Some "cycle Memory journal summary / full / hidden")
        binding.help

(* The chat pane binds the capture keys (masc_tui.ml, the arms beside
   [submit_chat_draft]) and is the surface an operator speaks from. The help
   sheet for it named neither, so the only place they were written down was the
   composer row on other surfaces. *)
let test_chat_help_names_the_voice_keys () =
  let keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface (Keepers Keeper_message))
  in
  Alcotest.(check bool) "Ctrl-Y starts a capture" true (List.mem "Ctrl-Y" keys);
  Alcotest.(check bool) "Ctrl-A turns continuous capture on" true
    (List.mem "Ctrl-A" keys)

let test_plain_listing_footer_shape () =
  (* Connectors answers the row search, so its footer carries the two Search
     hints between its own keys and the shared meta tail. That order is the
     shape being pinned: groups, then declaration order inside each. *)
  let canonical =
    "B:Browser Lane  j/k:scroll  PgUp/PgDn:page  Home/End:top/bottom  Ctrl-O:Browser screenshot  b / u:bind / unbind  Esc:keeper  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
  in
  check str "the plain listing keeps its footer" canonical
    (Masc_tui_keys.footer_hints Connectors)

let test_system_logs_footer_names_browser_controls () =
  check str "logs names filters and detail"
    ("1 / 2:Events / Logs  j/k:move / scroll  PgUp/PgDn:detail page"
     ^ "  [ / ]:previous / next  Home/End:top/bottom  l:level floor  v:verbose"
     ^ "  c:category  Right / Enter:detail  Left / Esc:back  /:find"
     ^ "  n / N:next / previous match  r:refresh  Tab:next  q:quit")
    (Masc_tui_keys.footer_hints System_logs)

let test_lanes_footer_opens_standalone_runs () =
  check str "Lanes names its run drill-down, config source, and way back"
    (* [hints_of_bindings] stable-sorts by group: Navigate (j/k, o / A, e, p)
       precedes Act (Right/Enter, Esc) regardless of declaration order.

       One item for Lane Add-ons, not two. The row carried "o:Lane Add-ons"
       and "A:add-ons" as separate items reading as separate destinations,
       and the dispatch had always been one arm. *)
    "j/k:move  o / A:Lane Add-ons  e:lane config  p:runtime  PgUp/PgDn:page  Home/End:top/bottom  Right / Enter:runs  a:append slot  s:slots  Esc:overview  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Lanes)

let test_lanes_scroll_reserves_standalone_matrix_rows () =
  check Alcotest.int
    "loading row plus title and divider"
    3
    (standalone_lanes_chrome ~row_count:None ~error:None ~truncated:false);
  check Alcotest.int
    "six lane rows plus title and divider"
    8
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:None
       ~truncated:false);
  check Alcotest.int
    "retained rows plus explicit stale warning"
    9
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:(Some "offline")
       ~truncated:false);
  check Alcotest.int
    "bounded-window warning spends one row"
    9
    (standalone_lanes_chrome
       ~row_count:(Some 6)
       ~error:None
       ~truncated:true)
;;

let test_harness_footer_links_to_overview_task () =
(* The four surfaces that own a detail -- Harness, Schedules, Verification,
   Planning -- pin their list footer, and say so. Called without the state,
   [footer_hints] returns every binding, which puts [[ / ]] (detail-only) and
   [Right / Enter] (list-only) in one row: a spelling no screen draws. It
   still caught label drift, so nothing failed; it just described a footer
   nobody has. The detail side is checked by [test_tui_footer_detail_state],
   which asserts each state drops the other's key, and for Harness by the PTY
   walk, which reads the drawn row. *)
  check str "Harness names its task link"
    "j/k:move  v:next Planning tab  PgUp/PgDn:page  Home/End:top/bottom  Right / Enter:verdict  Left / Esc:back  y / x:agree / overrule  Y:copy task  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints ~detail_open:false Harness)

let test_schedules_footer_names_write_and_read_controls () =
  check str "Schedules names create and modify"
    "j/k:move  PgUp/PgDn:page  Home/End:top/bottom  Right / Enter:details  Left / Esc:back  n:new  e:modify  x:cancel  Y:copy link  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints ~detail_open:false Schedules)

let schedule_form_row : schedule_row =
  { sch_schedule_id = "daily-check"
  ; sch_schedule_instance_id = "instance-old"
  ; sch_status = "scheduled"
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator (human)"
  ; sch_scheduled_by = "operator (human)"
  ; sch_requested_at_iso = "2026-09-01T00:00:00Z"
  ; sch_due_at_iso = Some "2026-09-02T00:00:00Z"
  ; sch_next_due_at_iso = Some "2026-09-02T00:00:00Z"
  ; sch_expires_at_iso = Some "2026-09-30T00:00:00Z"
  ; sch_recurrence_summary = "daily 09:30:05 Asia/Seoul"
  ; sch_recurrence =
      `Assoc
        [ "kind", `String "daily"
        ; "hour", `Int 9
        ; "minute", `Int 30
        ; "second", `Int 5
        ; "timezone", `String "Asia/Seoul"
        ]
  ; sch_payload_digest = "digest"
  ; sch_payload =
      `Assoc
        [ "kind", `String "masc.keeper_wake"
        ; ( "body"
          , `Assoc
              [ "keeper_name", `String "edgar.a.poe"
              ; "message", `String "inspect the latest work"
              ; "title", `String "daily inspection"
              ; "urgency", `String "low"
              ] )
        ]
  ; sch_payload_kind = Some "masc.keeper_wake"
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = Some "masc_keeper_wakeup"
  ; sch_payload_target = Some "keeper:edgar.a.poe"
  ; sch_payload_summary = Some "daily inspection"
  ; sch_last_wake_status = None
  ; sch_last_wake_started_at_iso = None
  ; sch_last_wake_error = None
  ; sch_queue_projection_status = None
  ; sch_queue_pending_count = None
  ; sch_reaction_projection_status = None
  ; sch_reaction_latest_at_iso = None
  ; sch_reaction_kind = None
  ; sch_reaction_keeper_name = None
  ; sch_reaction_stimulus_id = None
  ; sch_reaction_post_id = None
  ; sch_reaction_reason = None
  ; sch_wake_seen = None
  ; sch_turn_started = None
  ; sch_turn_finished = None
  ; sch_queue_ack_seen = None
  ; sch_wake_cancelled = None
  ; sch_stimulus_recorded_at_iso = None
  ; sch_turn_started_recorded_at_iso = None
  ; sch_turn_finished_recorded_at_iso = None
  ; sch_queue_ack_recorded_at_iso = None
  ; sch_wake_cancelled_recorded_at_iso = None
  ; sch_reaction_quarantined = None
  }

let test_schedule_create_form_names_the_canonical_required_fields () =
  let open Yojson.Safe.Util in
  let form =
    Masc_tui_types.schedule_create_form_json () |> Yojson.Safe.from_string
  in
  check str "keeper is explicit" "" (form |> member "keeper_name" |> to_string);
  check str "message is explicit" "" (form |> member "message" |> to_string);
  check str "one-shot is the visible default" "one_shot"
    (form |> member "recurrence_kind" |> to_string);
  check Alcotest.int "interval alternative is discoverable" 3600
    (form |> member "recurrence_interval_sec" |> to_int);
  check str "cron alternative is discoverable" "0 9 * * *"
    (form |> member "recurrence_cron" |> to_string)

(* The modify key's help says "running/finished rows refuse". These pin that
   the refusal now happens at the keypress, and that the set it refuses is the
   store's own: both ask [Schedule_domain.modify_allowed].

   The vocabulary is checked against
   [Schedule_contract_values.schedule_status_strings] rather than trusted as a
   hand-copied list, which is a second copy of the contract that goes stale
   quietly. *)
let refusal_for status =
  Masc_tui_types.schedule_modify_refusal
    { schedule_form_row with sch_status = status }

let test_modify_refuses_exactly_the_statuses_the_store_refuses () =
  (* The two sides are spelled out rather than recomputed from the gate's own
     expression: a test that recomputes it only proves the code equals itself.
     The sort below then checks these words against the contract's vocabulary,
     so a status added upstream fails here instead of being classified
     unasked. *)
  let refused = [ "running"; "succeeded"; "failed"; "cancelled"; "expired" ] in
  let opens = [ "scheduled"; "due" ] in
  check (Alcotest.list str)
    "the two sides together name every status the contract has"
    (List.sort compare Schedule_contract_values.schedule_status_strings)
    (List.sort compare (refused @ opens));
  List.iter
    (fun word ->
      check Alcotest.bool (word ^ " is refused before the editor opens") true
        (refusal_for word <> None))
    refused;
  (* The inputs that split this from a blanket refusal. Without them a gate
     that refused everything would pass every assertion above. *)
  List.iter
    (fun word ->
      check Alcotest.bool (word ^ " still opens the editor") true
        (refusal_for word = None))
    opens

let test_modify_names_the_status_it_refuses () =
  match refusal_for "running" with
  | None -> Alcotest.fail "a running row must refuse"
  | Some reason ->
    (* The operator is told which word on the screen closed the door, not
       just that it is closed. *)
    check str "the reason quotes the status the screen showed"
      "the store refuses to modify a running schedule (status as last read; \
       refresh if it has changed)"
      reason

(* The TUI and [Schedule_store.update_request] both ask
   [Schedule_domain.modify_allowed]; the store side is pinned in
   test_schedule_store. This pins the TUI side for every contract status. *)
let test_modify_refusal_is_the_shared_predicate () =
  List.iter
    (fun word ->
      match Schedule_domain.schedule_status_of_string word with
      | Error msg -> Alcotest.fail msg
      | Ok status ->
        check Alcotest.bool (word ^ " refuses iff modify_allowed is false")
          (not (Schedule_domain.modify_allowed status))
          (refusal_for word <> None))
    Schedule_contract_values.schedule_status_strings

let test_modify_leaves_an_unnamed_status_to_the_server () =
  (* [sch_status] stays a string so a status this build does not name renders
     as itself. Refusing on a word we cannot read would turn that forward
     compatibility into a row nobody can edit, so the roundtrip is the right
     answer here -- the server knows what it means. *)
  check Alcotest.bool "a status this build does not name is not refused here"
    true
    (refusal_for "paused" = None)

let test_schedule_update_form_preserves_exact_editable_definition () =
  let open Yojson.Safe.Util in
  let form =
    Masc_tui_types.schedule_update_form_json schedule_form_row
    |> Yojson.Safe.from_string
  in
  check str "stable id" "daily-check" (form |> member "schedule_id" |> to_string);
  check str "keeper" "edgar.a.poe" (form |> member "keeper_name" |> to_string);
  check str "full message" "inspect the latest work"
    (form |> member "message" |> to_string);
  check str "urgency" "low" (form |> member "urgency" |> to_string);
  check str "daily kind" "daily" (form |> member "recurrence_kind" |> to_string);
  check Alcotest.int "hour" 9 (form |> member "recurrence_hour" |> to_int);
  check Alcotest.int "minute" 30 (form |> member "recurrence_minute" |> to_int);
  check Alcotest.int "second" 5 (form |> member "recurrence_second" |> to_int);
  check str "timezone" "Asia/Seoul"
    (form |> member "recurrence_timezone" |> to_string);
  check str "due timestamp" "2026-09-02T00:00:00Z"
    (form |> member "due_at_iso" |> to_string);
  check Alcotest.bool "expiry remains present" true
    (form |> member "expires_at_unix" <> `Null)

(* Tools left the plain group when it grew a per-Keeper axis: the pane now
   shows one Keeper's effective tool surface, so it needs a key to change
   which Keeper that is. Pinned on its own rather than dropped from the list
   above -- a surface removed from the shared shape and named nowhere else
   can drift to any footer at all without a test noticing. *)
let test_tools_footer_carries_the_keeper_axis () =
  check str "tools names the effective Keeper switch"
    "j/k:scroll  Home/End:top/bottom  p:section  J/K:Skill  [ / ]:Keeper  c / C:new Skill  e:edit Skill  Esc:config  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Tools)

let test_resources_footer_steps_through_detail () =
  let tail =
    "  h/l:pane  Ctrl-W:focus  J/K:scroll text  [ / ]:previous / next"
    ^ "  PgUp/PgDn:page  Home/End:top/bottom  Enter:read  Esc:back"
  in
  let meta = "  r:reload  Tab:next  q:quit" in
  check str "list names its search and adjacent detail navigation"
    ("j/k:move" ^ tail ^ "  /:find  n / N:next / previous match" ^ meta)
    (Masc_tui_keys.footer_hints_resources ~detail_focus:false);
  (* The text has no cursor for a match to land on, so it says no [/] --
     the same answer [surface_row_texts] gives for that focus. Both ends
     still answer Home and End, which move the reading. *)
  check str "the text names scrolling without a row search"
    ("j/k:scroll text" ^ tail ^ meta)
    (Masc_tui_keys.footer_hints_resources ~detail_focus:true)

let test_repositories_footer_offers_code_and_git_changes () =
  check str "repositories names the Code and Git changes paths"
    "j/k:scroll  H:recent activity  PgUp/PgDn:page  Home/End:top/bottom  Enter:browse  d:Git changes  a:add  Left / Esc:back  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Repositories)

let test_memory_footer_offers_the_fact_browser () =
  (* One spelling for the keeper row. [ / ] was listed beside j/k for the
     same movement and no arm answered it. [/] narrows this table rather than
     moving a cursor through it, and Esc clears that filter before it leaves,
     so both are named the way the fact browser names them. *)
  check str "the health table names the way into the facts"
    "j/k:move  PgUp/PgDn:page  Home/End:top/bottom  Enter:facts  a / A:all fleet  s:sort  Esc:clear / back  /:filter  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Memory);
  check Alcotest.bool "the dead bracket hint is gone" false
    (List.exists
       (fun (binding : Masc_tui_keys.binding) ->
          String.equal binding.Masc_tui_keys.key "[ / ]")
       (Masc_tui_keys.for_surface Memory))

let test_memory_facts_footer_names_filter_and_way_back () =
  check str "the browser names movement, the category cycle, and Esc"
    "j/k:move  Home/End:top/bottom  Enter:detail  c / C:category  s:sort  a / A:all fleet  Esc:close / clear  /:filter  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_memory_facts

let sample_memory_fact ~category ~claim : Tui_decode.memory_fact =
  { Tui_decode.mf_claim = claim
  ; mf_category = category
  ; mf_origin = "authored"
  ; mf_first_seen = 0.
  ; mf_last_seen = 0.
  ; mf_memory_id = claim
  ; mf_events = Tui_decode.no_memory_fact_events
  }

let memory_state_with_facts () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.memory_facts_keeper <- Some "alpha";
  state.memory_facts <-
    Some
      { Tui_decode.mfs_keeper = "alpha"
      ; mfs_ordinary =
          Tui_decode.Memory_store_present
            { Tui_decode.mos_revision = 1
            ; mos_updated_at = 0.
            ; mos_facts =
                [ sample_memory_fact ~category:Cat.Lesson ~claim:"a"
                ; sample_memory_fact ~category:Cat.Blocker ~claim:"b"
                ]
            }
      ; mfs_source =
          Tui_decode.Memory_store_present
            { Tui_decode.mss_revision = 1
            ; mss_updated_at = 0.
            ; mss_facts =
                [ { Tui_decode.msf_claim = "bound"
                  ; msf_first_seen = 0.
                  ; msf_path = "docs/a.md"
                  ; msf_sha256 = "cafe"
                  }
                ]
            ; mss_invalidations =
                [ { Tui_decode.mi_source_path = "docs/old.md"
                  ; mi_invalidated_at = 0.
                  ; mi_reason = "source_changed"
                  }
                ]
            }
      ; mfs_events_read_error = None
      };
  state

let category_filter_testable =
  let pp fmt = function
    | Category_all -> Format.pp_print_string fmt "Category_all"
    | Category_ordinary c ->
        Format.fprintf fmt "Category_ordinary %S"
          (Cat.category_to_string c)
    | Category_source -> Format.pp_print_string fmt "Category_source"
    | Category_dropped -> Format.pp_print_string fmt "Category_dropped"
  in
  Alcotest.testable pp ( = )

let test_memory_fact_rows_follow_the_category_filter () =
  let state = memory_state_with_facts () in
  Alcotest.(check int) "All lists both stores plus the drops" 4
    (List.length (memory_fact_rows state));
  state.memory_facts_category <- Category_ordinary Cat.Lesson;
  (match memory_fact_rows state with
   | [ Memory_row_fact fact ] ->
       check str "the filter narrows ordinary facts only" "a"
         fact.Tui_decode.mf_claim
   | rows ->
       Alcotest.fail
         (Printf.sprintf "unexpected filtered shape (%d rows)"
            (List.length rows)));
  Alcotest.(check (list category_filter_testable)) "categories are the loaded ones, sorted"
    [ Category_ordinary Cat.Blocker
    ; Category_ordinary Cat.Lesson
    ; Category_source
    ; Category_dropped
    ]
    (memory_fact_categories state)

let test_memory_category_cycle_returns_to_all () =
  let categories = [ Category_ordinary Cat.Blocker; Category_ordinary Cat.Lesson ] in
  Alcotest.(check category_filter_testable) "All steps to the first" (Category_ordinary Cat.Blocker)
    (next_memory_category Category_all categories);
  Alcotest.(check category_filter_testable) "then to the next" (Category_ordinary Cat.Lesson)
    (next_memory_category (Category_ordinary Cat.Blocker) categories);
  Alcotest.(check category_filter_testable) "the last returns to All" Category_all
    (next_memory_category (Category_ordinary Cat.Lesson) categories);
  Alcotest.(check category_filter_testable) "a vanished category restarts at All" Category_all
    (next_memory_category (Category_ordinary Cat.Goal) categories);
  Alcotest.(check category_filter_testable) "no categories keeps All" Category_all
    (next_memory_category Category_all [])

let test_git_changes_footer_names_only_changed_file_actions () =
  check str "Git changes has one shared row footer"
    "j/k:move  Right / d / Enter:diff  v:open in code  p:open PR  t/g:task / goal  Left / Esc:back  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_git_changes

let test_git_diff_footer_names_scroll_code_and_files () =
  check str "Git diff has diff navigation footer"
    "j/k:scroll  v:open in code  p:open PR  t/g:task / goal  Left / Esc:back to files  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_git_diff

(* The Board draft's footers were literals in the renderer, so the pane above
   them spelled Ctrl-E a second way and named Enter where the footer did not.
   Pinned as display data the way the other projected footers are. *)
let test_board_compose_footers_are_projected () =
  check str "writing names the letters' exceptions and no q"
    "type to write  Enter:newline  Ctrl-E:$EDITOR  Esc:menu  Tab:surfaces"
    Masc_tui_keys.footer_hints_board_compose_writing;
  check str "a new post's menu cycles the hearth"
    "s:send  e:edit in $EDITOR  h:cycle hearth  d:discard  Esc:keep writing"
    (Masc_tui_keys.footer_hints_board_compose_armed ~reply:false);
  check str "a reply's menu has no hearth to cycle"
    "s:send  e:edit in $EDITOR  d:discard  Esc:keep writing"
    (Masc_tui_keys.footer_hints_board_compose_armed ~reply:true)

let test_verification_footer_carries_the_verdict_keys () =
  (* Verification is a list/detail surface: Enter explains the request before
     the two-press approve or the $EDITOR reject reason changes it. [h] names
     the other list -- the store keeps every submission, so the history holds
     rows whose task finished weeks ago -- and [< / >] pages that history. *)
  check str "verification names detail, approve, and reject"
    "j/k:move  v:next Planning tab  h:queue / history  < / >:newer / older  PgUp/PgDn:page  Home/End:top/bottom  Right / Enter:details  Left / Esc:back  a / x:approve / reject  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints ~detail_open:false Verification)

let test_fusion_footer_pins_the_shared_list_projection () =
  (* Pin the shared list footer as display data. The PTY scenario separately
     exercises j, r, Enter, PgDn, and detail Esc through the real dispatch. *)
  check str "fusion names its list keys"
    "j/k:move  PgUp/PgDn:page  [ / ]:previous / next  K:calling Keeper  B:Board evidence  Home/End:top/bottom  Enter:open  a:new run  Y:copy  Esc:back  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Fusion)

(* K and B answer in the detail as on the list; the detail footer named
   neither, and a body row named them in its own notation. Both footers now
   read the same two bindings. *)
let test_fusion_detail_footer_names_the_caller_and_board_keys () =
  let detail = Masc_tui_keys.footer_hints_fusion_detail ~position:"1-40/47" in
  let holds needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
    scan 0
  in
  Alcotest.(check bool) "the detail names the calling Keeper" true (holds "K:calling Keeper" detail);
  Alcotest.(check bool) "the detail names the Board evidence" true (holds "B:Board evidence" detail);
  Alcotest.(check bool) "spelled as the list spells them" true
    (holds "K:calling Keeper  B:Board evidence" (Masc_tui_keys.footer_hints Fusion))

(* The Board read pane drew its keys twice: a row above the post listed
   reply, vote, copy and back, and the footer listed reply, copy and back
   again -- with no vote key, so that row was the only place v was drawn.
   The row is gone; the footer carries the three post keys, spelled as the
   Board list spells them, in both layouts. *)
let test_board_read_footer_carries_the_post_keys () =
  let holds needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
    scan 0
  in
  let list = Masc_tui_keys.footer_hints Board in
  List.iter
    (fun split ->
      let read = Masc_tui_keys.footer_hints_board_read ~focus_posts:false ~split in
      List.iter
        (fun key ->
          Alcotest.(check bool) (Printf.sprintf "read footer (split=%b) names %s" split key) true
            (holds key read);
          Alcotest.(check bool) (Printf.sprintf "the Board list spells %s the same" key) true
            (holds key list))
        [ "v / V:vote"; "c:reply"; "Y:copy link" ];
      Alcotest.(check bool) (Printf.sprintf "the pane keys follow the split (%b)" split) split
        (holds "Ctrl-W:switch" read))
    [ false; true ];
  Alcotest.(check bool) "j/k names what it moves" true
    (holds "j/k:posts"
       (Masc_tui_keys.footer_hints_board_read ~focus_posts:true ~split:true))

let test_fusion_historical_evidence_is_a_selectable_board_reference () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let response = `Assoc
    [ "generated_at", `String "2026-09-07T00:00:00Z"
    ; "count", `Int 0; "runs", `List []
    ; "replay", `Assoc ["status", `String "complete"; "lines_read", `Int 2;
                        "malformed_lines", `Int 1; "dropped_running", `Int 1]
    ; "historical_evidence", `List
        [ `Assoc ["run_id", `String "past-run"; "post_id", `String "original-post";
                  "title", `String "Original conclusion"; "created_at", `Float 10.]
        ]
    ] in
  (match Tui_decode.decode_fusion_snapshot response with
   | Error detail -> Alcotest.fail detail
   | Ok snapshot -> state.fusion_runs <- Some snapshot);
  check Alcotest.int "history remains in the selectable list with no retained runs"
    1 (List.length (fusion_list_entries state));
  (match selected_fusion_entry state with
   | Some (Tui_decode.Fusion_historical_evidence evidence) ->
       check str "selection retains original Board identity" "original-post" evidence.fhe_post_id
   | Some (Tui_decode.Fusion_retained_run _) | None ->
       Alcotest.fail "historical evidence disappeared or became an invented run");
  check Alcotest.int "historical evidence does not inflate Keeper run count"
    0 (List.length (selected_keeper_runs state))

let test_keeper_runs_selection_survives_a_shorter_list () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let keeper name : Tui_decode.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper; k_name = name; k_trace_id = name; k_paused = false; k_current_task_id = None
    ; k_total_turns = 0; k_total_tokens = 0; k_total_cost_usd = 0.
    ; k_last_turn_ts = ""; k_last_proactive_outcome = None
    ; k_created_at = "2026-09-07T00:00:00Z"; k_updated_at = "2026-09-07T00:00:00Z"
    }
  in
  let run id keeper = `Assoc
    [ "run_id", `String id; "keeper", `String keeper; "preset", `String "trio"
    ; "topology", `String "simple"; "started_at", `Float 1.; "finished_at", `Float 2.
    ; "status", `String "completed"; "stage", `String "completed"; "progress", `Null
    ]
  in
  let load runs =
    match Tui_decode.decode_fusion_snapshot (`Assoc
      [ "generated_at", `String "2026-09-07T00:00:00Z"
      ; "replay", `Assoc ["status", `String "not_replayed"]
      ; "historical_evidence", `List []
      ; "count", `Int (List.length runs); "runs", `List runs ]) with
    | Ok snapshot -> state.fusion_runs <- Some snapshot
    | Error detail -> Alcotest.fail detail
  in
  let selected () =
    Option.map (fun (index, run) -> index, run.Tui_decode.fur_run_id)
      (selected_keeper_run state)
  in
  state.keepers <- [keeper "alpha"; keeper "beta"];
  load [run "alpha-1" "alpha"; run "alpha-2" "alpha"; run "beta-1" "beta"];
  state.keeper_run_cursor <- 1;
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "selected alpha run"
    (Some (1, "alpha-2")) (selected ());
  state.keeper_cursor <- 1;
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "a shorter Keeper list remains selectable"
    (Some (0, "beta-1")) (selected ());
  state.keeper_cursor <- 0;
  load [run "alpha-1" "alpha"];
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "a refreshed list remains selectable"
    (Some (0, "alpha-1")) (selected ());
  load [];
  check (Alcotest.option (Alcotest.pair Alcotest.int str)) "empty list has no action target"
    None (selected ())

let test_lanes_run_list_footer_names_the_drill_down () =
  check str "the standalone lane run list names open and back"
    "j/k:move  Right / Enter:prompt  ]:older  Left / Esc:back  r:refresh  Tab:next  q:quit"
    Masc_tui_keys.footer_hints_lanes_run_list

(* [compare], not [scroll]: #32270 stacked Input and Output into one list that
   one scroll walks, so the two panes move together and the key's name says
   which of the two it does. *)
let test_lanes_run_detail_footer_appends_the_scroll_position () =
  check str "the stacked run detail footer carries the window it drew"
    "j/k:compare  PgUp/PgDn:page  Left / Esc:back  r:refresh  Tab:next  q:quit  4-23/60"
    (Masc_tui_keys.footer_hints_lanes_run_detail ~position:(Some "4-23/60"));
  check str "the split panes name their own windows, so the footer does not"
    "j/k:compare  PgUp/PgDn:page  Left / Esc:back  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints_lanes_run_detail ~position:None)

let test_overview_footer_projects_by_focus () =
  (* The retired literal said "j/k:events  t:tasks  q:quit  r:refresh
     Tab:next  2:keepers" (and "j/k:tasks  Enter:detail  esc:events …").
     The projection keeps every pair, relabels j/k by focus, and drops the
     keys that are dead in the other mode: t only leaves the event list,
     Right/Enter and Left/Esc only act on a focused task. h/l stays visible
     because it selects either pane directly. *)
  check str "events mode keeps t and drops the task keys"
    ("j/k:events  h/l:pane  m:telemetry  Home/End:top/bottom  t:tasks"
     ^ "  2:keepers  r:refresh  Tab:next  q:quit")
    (Masc_tui_keys.footer_hints_overview ~task_focus:false);
  (* Both columns and an open task's detail answer Home and End: the events
     column and the detail as readings the frame clamps, the task column as a
     row list whose window follows its cursor. So the key is named in both
     modes rather than in one. *)
  check str "tasks mode keeps arrow/Enter/Esc and drops t"
    ("j/k:tasks  h/l:pane  m:telemetry  Home/End:top/bottom"
     ^ "  Right / Enter:open  Left / Esc:back  2:keepers  r:refresh"
     ^ "  Tab:next  q:quit")
    (Masc_tui_keys.footer_hints_overview ~task_focus:true)

(* Reading a queue meant Esc, move, Enter for every row -- three keys to do
   what one does on Changes and the Keeper detail tabs, both of which already
   spell it [ / ]. Six surfaces have a list and a detail over it and none of
   them offered the step.

   Asserted over the whole set rather than one at a time: the gap was that
   each surface decided this for itself, and a table that names them together
   is what stops the seventh from being added without it. *)
let test_every_detail_surface_steps_through_its_list () =
  List.iter
    (fun (label, surface) ->
      let keys =
        List.map
          (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
          (Masc_tui_keys.for_surface surface)
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s steps with [ / ]" label)
        true
        (List.mem "[ / ]" keys))
    [ "Approvals", Approvals
    ; "Planning", Planning
    ; "Schedules", Schedules
    ; "Verification", Verification
    ; "Harness", Harness
    ; "Fusion", Fusion
    ; "Board", Board
    ; "Changes", Changes
    ; "Resources", Resources
    ; "Keeper detail", Keepers Keeper_detail
    ; "System logs", System_logs
    ]

let test_planning_footer_carries_filter_and_sort () =
  check str "planning names filter and sort"
    "j/k:move  v:next Planning tab  f:filter  s:sort  PgUp/PgDn:page  Home/End:top/bottom  Right / Enter:detail  Left / Esc:back  c:request completion  a:confirm proof  x:drop  o:reopen  Y:copy link  /:find  n / N:next / previous match  r:refresh  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints ~detail_open:false Planning)

let test_board_footer_names_reversible_hearth_navigation () =
  let keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface Board)
  in
  check Alcotest.bool "both hearth directions" true (List.mem "f / F" keys);
  check Alcotest.bool "direct hearth chooser" true (List.mem "H" keys)

let test_board_and_planning_explain_their_order () =
  check str "hot formula" "net votes first; newer breaks ties"
    (board_sort_explanation Board_hot);
  check str "trending formula" "net votes / √age-hours"
    (board_sort_explanation Board_trending);
  check str "active phase set" "executing + verifying"
    (planning_filter_explanation Planning_filter_active);
  check str "phase and priority order" "phase order, then P1→P5"
    (planning_sort_explanation Planning_sort_phase_priority);
  check str "due order" "earliest due date first; undated last"
    (planning_sort_explanation Planning_sort_due)
;;

(* Where the strip puts the highlight for a view, read through the index the
   strip draws with. These tests used to read a second copy of the mapping
   that nothing on screen called. The Browser Lane arm lived only in the drawn
   one, so the two could disagree and the tests would not see it. *)
let ring_stop surface =
  visible_surface_ring_index
    (create_state ~workspace:"" ~port:0 ~refresh_interval:0. ())
    surface

(* Every view lands on a stop the ring holds. The index cannot say this: a
   family missing from the ring comes back as 0, Overview's position, and a
   comparison against Overview would pass. *)
let test_every_view_has_a_ring_stop () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  List.iter
    (fun surface ->
      Alcotest.(check bool) "the view's family is a ring stop" true
        (List.exists
           (fun (stop, _) -> stop = surface_ring_family state surface)
           surface_ring))
    every_surface

let test_task_review_is_a_planning_child () =
  Alcotest.(check bool) "Task Review is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Verification) surface_ring);
  Alcotest.(check int) "Task Review highlights Planning"
    (ring_stop Planning)
    (ring_stop Verification)

(* Verdicts is the far half of Task Review -- one lists what is waiting for a
   ruling, the other what was ruled -- and it stood on the top-level ring under
   the name "Harness", which named a mechanism rather than a thing an operator
   opens. Both halves now hang off Planning, and [v] walks the three. *)
let test_verdicts_is_a_planning_child () =
  Alcotest.(check bool) "Verdicts is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Harness) surface_ring);
  Alcotest.(check int) "Verdicts highlights Planning"
    (ring_stop Planning)
    (ring_stop Harness);
  Alcotest.(check bool) "and the help sheet files it under Planning" true
    (List.exists
       (fun (label, _) -> String.equal label "Planning / Task Verdicts")
       (Masc_tui_keys.help_sections ()))

(* Changes reads one keeper's file writes and binds to the roster cursor on
   entry, so it opens with [f] from the roster instead of holding a Tab stop
   of its own. *)
let test_changes_is_a_keeper_child () =
  Alcotest.(check bool) "Changes is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Changes) surface_ring);
  Alcotest.(check int) "Changes highlights Keepers"
    (ring_stop (Keepers Keeper_list))
    (ring_stop Changes)

let test_keeper_operations_are_not_top_level_tabs () =
  List.iter
    (fun (surface, label) ->
       Alcotest.(check bool) (label ^ " is not a top-level ring entry") false
         (List.exists (fun (entry, _) -> entry = surface) surface_ring);
       Alcotest.(check int) (label ^ " highlights Keepers")
         (ring_stop (Keepers Keeper_list))
         (ring_stop surface))
    [ Connectors, "Channels"; Schedules, "Automation" ];
  Alcotest.(check (list string)) "Keeper operation tab labels"
    [ "Channels"; "Automation"; "Runs" ]
    (List.filter_map
       (fun tab ->
          match tab with
          | Detail_channels | Detail_automation | Detail_runs ->
              Some (keeper_detail_tab_label tab)
          | Detail_info | Detail_sandbox | Detail_instructions | Detail_secrets
          | Detail_github | Detail_identity -> None)
       keeper_detail_tabs)

(* The Memory roster's ST column used to carry its own legend row, drawn above
   every roster whether or not the column had anything in it -- including a
   roster whose read had failed, where the marks it explained were not on
   screen at all. The Keeper columns left the surface for the sheet for that
   reason (#36156's neighbours in [help_sections]); this is the same move.

   Both halves are pinned: the sheet has the section, and every state the
   column can draw has a mark the section explains. A state added to
   [memory_state] stops [Masc_tui_memory_mark] compiling until it has a mark,
   and this stops a mark being added without a word beside it. *)
let test_the_memory_marks_are_in_the_sheet_not_on_the_roster () =
  Alcotest.(check bool) "the sheet explains the ST column" true
    (List.exists
       (fun (label, _) -> String.equal label "Memory marks")
       (Masc_tui_keys.help_sections ()));
  let explained = List.map fst Masc_tui_memory_mark.legend in
  List.iter
    (fun state ->
      let mark = Masc_tui_memory_mark.glyph state in
      Alcotest.(check bool)
        (Printf.sprintf "the sheet explains the mark %S" mark)
        true
        (List.mem mark explained))
    [ Masc_tui_types.Memory_ordinary; Masc_tui_types.Memory_warning
    ; Masc_tui_types.Memory_degraded; Masc_tui_types.Memory_no_current
    ; Masc_tui_types.Memory_source_only; Masc_tui_types.Memory_starving
    ; Masc_tui_types.Memory_read_error ];
  (* And nothing in the sheet that the column cannot draw. *)
  let drawable =
    List.map Masc_tui_memory_mark.glyph
      [ Masc_tui_types.Memory_ordinary; Masc_tui_types.Memory_warning
      ; Masc_tui_types.Memory_degraded; Masc_tui_types.Memory_no_current
      ; Masc_tui_types.Memory_source_only; Masc_tui_types.Memory_starving
      ; Masc_tui_types.Memory_read_error ]
  in
  List.iter
    (fun (mark, _) ->
      Alcotest.(check bool)
        (Printf.sprintf "the column can draw %S" mark)
        true
        (List.mem mark drawable))
    Masc_tui_memory_mark.legend

(* The Code tree draws a mark in front of every row: an arrow for a folder,
   and for a file one of seven marks read from its extension. Nothing beside
   the mark says which is which -- the row is the mark and then the file name,
   and the name only repeats the extension the mark came from. So a reader
   who wants to know what the diamond means has one place to look, and until
   [File marks] the sheet was not it.

   Same two halves as the memory marks above: the sheet has the section, and
   every mark the tree can draw has a word in it. [Masc_tui_file_icon.word]
   stops compiling when a kind is added without a word, and this stops a word
   being added for a mark the tree never draws. *)
let test_the_file_marks_are_in_the_sheet () =
  Alcotest.(check bool) "the sheet explains the Code tree's marks" true
    (List.exists
       (fun (label, _) -> String.equal label "File marks")
       (Masc_tui_keys.help_sections ()));
  let explained = List.map fst Masc_tui_file_icon.legend in
  List.iter
    (fun kind ->
      let mark = Masc_tui_file_icon.glyph kind in
      Alcotest.(check bool)
        (Printf.sprintf "the sheet explains the mark %S" mark)
        true
        (List.mem mark explained))
    Masc_tui_file_icon.kinds;
  (* The eighth mark. The tree draws an arrow on a row that opens rather than
     reads, and the sheet explained the seven file kinds beside it and not
     that one -- the mark that says which of the two a row is. *)
  Alcotest.(check bool) "the sheet explains the folder arrow" true
    (List.mem Masc_tui_file_icon.folder_glyph explained);
  (* And nothing in the sheet the tree cannot draw. *)
  let drawable =
    Masc_tui_file_icon.folder_glyph
    :: List.map Masc_tui_file_icon.glyph Masc_tui_file_icon.kinds
  in
  List.iter
    (fun (mark, _) ->
      Alcotest.(check bool)
        (Printf.sprintf "the tree can draw %S" mark)
        true
        (List.mem mark drawable))
    Masc_tui_file_icon.legend

(* Config's two list panes draw a mark in their first column and say what it
   means only in the detail pane below the list, for the one row the cursor is
   on. A reader scanning twenty prompt rows could tell a marked row from an
   unmarked one and not what the mark said; the sheet carried seven legends
   and neither of these.

   Same two halves as the memory and file marks above: every mark a pane can
   draw has a word, and nothing has a word the pane cannot draw. A source
   added to [prompt_source] stops [Masc_tui_config_mark] compiling until it
   has a mark, and this stops a mark being added without a word beside it. *)
let prompt_sources =
  [ Masc.Tui_decode.Prompt_override
  ; Masc.Tui_decode.Prompt_file
  ; Masc.Tui_decode.Prompt_missing
  ]

let test_the_config_marks_are_in_the_sheet () =
  List.iter
    (fun section ->
      Alcotest.(check bool)
        (Printf.sprintf "the sheet carries %S" section)
        true
        (List.exists
           (fun (label, _) -> String.equal label section)
           (Masc_tui_keys.help_sections ())))
    [ "Prompt marks"; "Param marks" ];
  let prompt_explained = List.map fst Masc_tui_config_mark.prompt_legend in
  (* Held back outranks the source, so every source wears the same mark under
     it, and that mark has a word. *)
  List.iter
    (fun source ->
      let mark = Masc_tui_config_mark.prompt_glyph ~held_back:true source in
      Alcotest.(check bool)
        (Printf.sprintf "the sheet explains the held-back mark %S" mark)
        true
        (List.mem mark prompt_explained))
    prompt_sources;
  (* Unheld, the shipped file is the one row that draws nothing, and a state
     with no mark needs no word. The other two do. *)
  List.iter
    (fun source ->
      let mark = Masc_tui_config_mark.prompt_glyph ~held_back:false source in
      let explained = List.mem mark prompt_explained in
      match source with
      | Masc.Tui_decode.Prompt_file ->
          Alcotest.(check string) "the shipped file draws a blank" " " mark;
          Alcotest.(check bool) "so the blank is no sheet row" false explained
      | Masc.Tui_decode.Prompt_override | Masc.Tui_decode.Prompt_missing ->
          Alcotest.(check bool)
            (Printf.sprintf "the sheet explains the mark %S" mark)
            true
            explained)
    prompt_sources;
  let prompt_drawable =
    List.concat_map
      (fun held_back ->
        List.map
          (fun source -> Masc_tui_config_mark.prompt_glyph ~held_back source)
          prompt_sources)
      [ true; false ]
  in
  List.iter
    (fun (mark, _) ->
      Alcotest.(check bool)
        (Printf.sprintf "the prompt registry can draw %S" mark)
        true
        (List.mem mark prompt_drawable))
    Masc_tui_config_mark.prompt_legend;
  (* The params list fills its column on every row, so both marks are words. *)
  let param_drawable =
    List.map
      (fun has_override -> Masc_tui_config_mark.param_glyph ~has_override)
      [ true; false ]
  in
  let param_explained = List.map fst Masc_tui_config_mark.param_legend in
  List.iter
    (fun mark ->
      Alcotest.(check bool)
        (Printf.sprintf "the sheet explains the param mark %S" mark)
        true
        (List.mem mark param_explained))
    param_drawable;
  List.iter
    (fun (mark, _) ->
      Alcotest.(check bool)
        (Printf.sprintf "the params list can draw %S" mark)
        true
        (List.mem mark param_drawable))
    Masc_tui_config_mark.param_legend

(* Lanes is the operator's top-level concurrent lane workspace. Runtime still
   owns configuration and substrate probes; [p] remains the explicit return
   path from the standalone run browser. *)
(* A sheet section answers "what can I do here", and a label is the answer.
   Two rows carrying the same label are one answer given twice: the reader
   reads the second to find what it adds and finds a pronoun.

   Config / Runtime / Clients listed [p] and [Esc] as "runtime", one row under
   the other, helped "back to the Runtime surface this hangs off" and "...it
   hangs off". Both call goto_surface Runtime. The repo spells two doors to
   one action as one binding -- [Left / Esc], [y / n], [o / A] -- and
   [Masc_tui_keys.key_atoms] splits the slash, so both keys stay counted. *)
(* Two rows that share a label but not an action. The label under-describes
   them and the help beside it tells them apart; which word each should carry
   instead is a wording decision, not a duplicate key, so they are named here
   rather than fixed in passing.

   Board: [Ctrl-W] swaps the two panes and [h/l] focuses one of them by
   direction. Workspace / Code: [Left / Esc] leaves the file, then the
   directory, then the surface, and [B] walks back through definition
   jumps -- unrelated, and both called "back". *)
(* And one that shares a label because no screen shows both rows. Config
   draws a footer per pane, so "edit" on [e] (runtime, models, prompts,
   voice) and on [e / Enter] (params) are the same answer given to readers
   who never meet each other. Kept apart rather than merged into one row
   because the panes take different keys: merging would put [Enter] in front
   of four panes that do not answer it. [test_every_config_pane_answers_once]
   is where this is checked at the size a reader actually sees. *)
let shared_label_exceptions =
  [ ("Board", "pane"); ("Workspace / Code", "back"); ("Config", "edit") ]

let test_no_surface_gives_one_answer_two_rows () =
  let found = ref [] in
  List.iter
    (fun (name, surface) ->
      let labels = List.map (fun b -> b.Masc_tui_keys.label) (Masc_tui_keys.for_surface surface) in
      let sorted = List.sort compare labels in
      let rec first_repeat = function
        | a :: (b :: _ as rest) -> if String.equal a b then Some a else first_repeat rest
        | [ _ ] | [] -> None
      in
      match first_repeat sorted with
      | None -> ()
      | Some label ->
          if not (List.mem (name, label) shared_label_exceptions) then
            found := Printf.sprintf "%s names two keys %S" name label :: !found)
    Masc_tui_keys.help_surfaces;
  Alcotest.(check (list string)) "every label answers for one key" [] (List.rev !found);
  (* And every exception still shares its label, so one that was renamed or
     removed does not sit here claiming to hold something. *)
  List.iter
    (fun ((name, label) as entry) ->
      let surface = List.assoc name Masc_tui_keys.help_surfaces in
      let count =
        List.length
          (List.filter
             (fun b -> String.equal b.Masc_tui_keys.label label)
             (Masc_tui_keys.for_surface surface))
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s still shares %S" (fst entry) label)
        true (count >= 2))
    shared_label_exceptions

(* Both exceptions above name Config because the help sheet shows the union of
   seven panes. No reader sees that union -- [footer_hints_config] draws one
   pane -- so the invariants they stepped out of are asked here, of each pane.
   That is seven checks where the surface form was one.

   Read the raw row, not a fitted one: the fitter drops items at narrow
   widths, and an item it dropped would pass a uniqueness check by being
   absent. *)
let config_panes =
  [ ("runtime", Config_runtime)
  ; ("models", Config_models)
  ; ("params", Config_params)
  ; ("prompts", Config_prompts)
  ; ("presets", Config_presets)
  ; ("themes", Config_themes)
  ; ("voice", Config_voice)
  ]

(* [hints_of_bindings] joins items with two spaces, and a key may hold a single
   one ([e / Enter], [Right / Enter]) -- so split on the pair, not on a space.
   [footer_has_key] splits on one space, which is why it cannot ask for a
   pair's whole spelling. *)
let footer_items row =
  let length = String.length row in
  let rec split acc start index =
    if index + 1 >= length then List.rev (String.sub row start (length - start) :: acc)
    else if row.[index] = ' ' && row.[index + 1] = ' ' then
      split (String.sub row start (index - start) :: acc) (index + 2) (index + 2)
    else split acc start (index + 1)
  in
  if length = 0 then []
  else List.filter (fun item -> not (String.equal item "")) (split [] 0 0)

(* An item is [key:label]; a label may hold a colon of its own, so read the
   key up to the first one. *)
let item_key item =
  match String.index_opt item ':' with
  | Some at -> String.sub item 0 at
  | None -> item

let item_label item =
  match String.index_opt item ':' with
  | Some at -> String.sub item (at + 1) (String.length item - at - 1)
  | None -> item

let test_every_config_pane_answers_once () =
  List.iter
    (fun (name, pane) ->
      let items = footer_items (Masc_tui_keys.footer_hints_config ~pane) in
      let enter =
        List.filter
          (fun item ->
            List.exists (String.equal "Enter") (Masc_tui_keys.key_atoms (item_key item)))
          items
      in
      Alcotest.(check bool)
        (Printf.sprintf "the %s pane names at most one key holding Enter (found: %s)" name
           (String.concat " | " enter))
        true
        (List.length enter <= 1);
      let sorted = List.sort compare (List.map item_label items) in
      let rec first_repeat = function
        | a :: (b :: _ as rest) -> if String.equal a b then Some a else first_repeat rest
        | [ _ ] | [] -> None
      in
      Alcotest.(check (option string))
        (Printf.sprintf "the %s pane gives each answer once" name)
        None
        (first_repeat sorted))
    config_panes

let test_lanes_is_a_main_destination () =
  Alcotest.(check bool) "Lanes is a top-level ring entry" true
    (List.exists (fun (surface, _) -> surface = Lanes) surface_ring);
  Alcotest.(check bool) "Lanes has its own ring stop" true
    (ring_stop Lanes <> ring_stop Config);
  Alcotest.(check bool) "help sheet names Lanes directly" true
    (List.exists
       (fun (label, _) -> String.equal label "Lanes")
       (Masc_tui_keys.help_sections ()));
  let lanes_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Lanes)
  in
  Alcotest.(check bool) "Lanes documents the [p] way back" true
    (List.mem "p" lanes_keys)

(* Code's tree is always somebody's checkout -- a registered repository, a
   keeper workspace, or the project -- and Enter on a Workspace row is
   already how a reader walks into it, so it hangs off Workspace instead of
   holding a Tab stop of its own. *)
let test_code_is_a_workspace_child () =
  Alcotest.(check bool) "Code is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Code) surface_ring);
  Alcotest.(check int) "Code highlights Workspace"
    (ring_stop Repositories)
    (ring_stop Code);
  Alcotest.(check bool) "and the help sheet files it under Workspace" true
    (List.exists
       (fun (label, _) -> String.equal label "Workspace / Code")
       (Masc_tui_keys.help_sections ()));
  Alcotest.(check bool) "and the ring stop is spelled Workspace" true
    (List.exists
       (fun (surface, label) ->
         surface = Repositories && String.equal label "Workspace")
       surface_ring)

(* Resources and Tools are registration catalogs -- what is wired up here,
   read rarely -- so they hang off Config under [s] and [t] instead of
   holding Tab stops of their own. *)
let test_resources_is_a_config_child () =
  Alcotest.(check bool) "Resources is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Resources) surface_ring);
  Alcotest.(check int) "Resources highlights Config"
    (ring_stop Config)
    (ring_stop Resources);
  Alcotest.(check bool) "and the help sheet files it under Config" true
    (List.exists
       (fun (label, _) -> String.equal label "Config / Resources")
       (Masc_tui_keys.help_sections ()));
  let config_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Config)
  in
  Alcotest.(check bool) "Config documents the [s] hop" true
    (List.mem "s" config_keys)

let test_tools_is_a_config_child () =
  Alcotest.(check bool) "Tools is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Tools) surface_ring);
  Alcotest.(check int) "Tools highlights Config"
    (ring_stop Config)
    (ring_stop Tools);
  Alcotest.(check bool) "and the help sheet files it under Config" true
    (List.exists
       (fun (label, _) -> String.equal label "Config / Tools")
       (Masc_tui_keys.help_sections ()));
  let config_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Config)
  in
  Alcotest.(check bool) "Config documents the [t] hop" true
    (List.mem "t" config_keys)

(* Tool calls settling and the server's own log lines are two readings of
   one fleet timeline, so Logs hangs off Activity (the Acting surface)
   under its [1 / 2] tabs instead of holding a Tab stop of its own. *)
let test_logs_is_an_activity_child () =
  Alcotest.(check bool) "Runtime is inside Config" false
    (List.exists (fun (surface, _) -> surface = Runtime) surface_ring);
  List.iter (fun surface ->
      Alcotest.(check int) "runtime children highlight Config"
        (ring_stop Config) (ring_stop surface))
    [Runtime; Clients];
  Alcotest.(check bool) "Logs is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = System_logs) surface_ring);
  Alcotest.(check int) "Logs highlights Activity"
    (ring_stop Acting)
    (ring_stop System_logs);
  Alcotest.(check bool) "and the help sheet files it under Activity" true
    (List.exists
       (fun (label, _) -> String.equal label "Activity / Logs")
       (Masc_tui_keys.help_sections ()));
  Alcotest.(check bool) "and the ring stop is spelled Activity" true
    (List.exists
       (fun ((surface : surface), label) ->
         surface = Acting && String.equal label "Activity")
       surface_ring);
  let acting_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Acting)
  in
  Alcotest.(check bool) "Activity documents the way to Logs" true
    (List.mem "1 / 2" acting_keys)

(* Telemetry and multicore engine metrics hang off Overview under [m]
   instead of holding a top-level Tab stop of their own. *)
let test_metrics_is_an_overview_child () =
  Alcotest.(check bool) "Metrics is not a top-level ring entry" false
    (List.exists (fun (surface, _) -> surface = Metrics) surface_ring);
  Alcotest.(check int) "Metrics highlights Overview"
    (ring_stop Overview)
    (ring_stop Metrics);
  let overview_keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Overview)
  in
  Alcotest.(check bool) "Overview documents the [m] hop" true
    (List.mem "m" overview_keys)

let test_browser_lanes_highlight_config () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Connectors;
  check Alcotest.int "channel bindings remain under Keepers"
    (visible_surface_ring_index state (Keepers Keeper_list))
    (visible_surface_ring_index state Connectors);
  List.iter (fun source ->
      show_browser_lane state;
      state.browser_lane <- Some
        (Browser_lane_view.switch_source source (Browser_lane_view.create ()));
      let index = visible_surface_ring_index state Connectors in
      check Alcotest.int "Browser reader highlights Config"
        (visible_surface_ring_index state Config) index;
      check Alcotest.bool "the selected ring entry is Config, not the fallback"
        true (fst (List.nth (visible_surface_ring state) index) = Config))
    [Browser_lane_view.Live; Browser_lane_view.Automation];
  state.browser_lane <- None;
  check Alcotest.int "closing the reader restores the Keeper parent"
    (visible_surface_ring_index state (Keepers Keeper_list))
    (visible_surface_ring_index state Connectors)

let test_visible_surface_ring_declutter () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  let ring_empty = visible_surface_ring state in
  Alcotest.(check bool) "Approvals hidden when empty and not active" false
    (List.exists (fun (s, _) -> s = Approvals) ring_empty);
  state.view <- Approvals;
  let ring_active = visible_surface_ring state in
  Alcotest.(check bool) "Approvals shown when active surface" true
    (List.exists (fun (s, _) -> s = Approvals) ring_active);
  state.view <- Overview;
  state.keeper_tool_approvals <-
    [ { kta_keeper = "alpha"
      ; kta_tool_call_id = "call_1"
      ; kta_tool = "exec"
      ; kta_args = "{}"
      ; kta_question = "run?"
      ; kta_because = None
      ; kta_asked_at = 0.0
      ; kta_timeout_sec = 60.0
      }
    ];
  let ring_with_pending = visible_surface_ring state in
  Alcotest.(check bool) "Approvals shown when pending items exist" true
    (List.exists (fun (s, _) -> s = Approvals) ring_with_pending)

(* One ask can carry several questions, and the surface counts them under the
   word "question": its title, the block header above the rows, and the tab
   badge all read from [approvals_open_question_count]. It counted the asks,
   so a fleet holding one ask of two questions said "1 question" while the
   line three rows below it said "+2 more questions". *)
let test_the_question_count_counts_questions () =
  let ask id questions : Tui_decode.ask_row =
    { Tui_decode.ar_keeper = "jazz-developer"
    ; ar_id = id
    ; ar_asked_at = 0.0
    ; ar_context = None
    ; ar_questions =
        List.init questions (fun index ->
            { Tui_decode.aq_id = Printf.sprintf "%s-q%d" id index
            ; aq_header = "header"
            ; aq_prompt = "prompt"
            ; aq_mode = Tui_decode.Ask_single
            ; aq_free_text = Tui_decode.Ask_choices_only
            ; aq_choices = []
            })
    ; ar_resolution = Tui_decode.Ask_open
    }
  in
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.asks_snapshot <-
    Some
      { Tui_decode.asn_keeper = None
      ; asn_open_count = 2
      ; asn_rows = [ ask "a1" 2; ask "a2" 1 ]
      };
  Alcotest.(check int) "two asks holding three questions" 3
    (approvals_open_question_count state);
  (* The surface's own pending reading is the approvals plus these, and it
     answers the tab badge as well as the title. *)
  Alcotest.(check int) "and the surface counts them the same way" 3
    (approvals_surface_pending state);
  (* A resolved ask is not waiting on anyone, so its questions are not
     counted either. *)
  state.asks_snapshot <-
    Some
      { Tui_decode.asn_keeper = None
      ; asn_open_count = 1
      ; asn_rows =
          [ ask "a1" 2
          ; { (ask "a2" 4) with Tui_decode.ar_resolution =
                Tui_decode.Ask_answered
                  { aa_answered_at = 1.0; aa_question_ids = [] }
            }
          ]
      };
  Alcotest.(check int) "only the open ask's questions" 2
    (approvals_open_question_count state)

let test_visible_surface_ring_open_ask () =
  (* A keeper's question is an approval of a different kind: it waits on the
     same human, on the same surface. With zero approvals and one open ask
     the Approvals entry must stay in the ring, or the question has nowhere
     to be seen from. *)
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  state.asks_snapshot <-
    Some
      { Tui_decode.asn_keeper = Some "jazz-developer"
      ; asn_open_count = 1
      ; asn_rows =
          [ { Tui_decode.ar_keeper = "jazz-developer"
            ; ar_id = "ask1"
            ; ar_asked_at = 0.0
            ; ar_context = Some "where to post the measured comment"
            ; ar_questions =
                [ { Tui_decode.aq_id = "q1"
                  ; aq_header = "post or wait"
                  ; aq_prompt = "post the comment as is?"
                  ; aq_mode = Tui_decode.Ask_single
                  ; aq_free_text = Tui_decode.Ask_choices_only
                  ; aq_choices =
                      [ { Tui_decode.ac_id = "post_as_is"
                        ; ac_label = "post as is"
                        ; ac_description = None
                        }
                      ]
                  }
                ]
            ; ar_resolution = Tui_decode.Ask_open
            }
          ]
      };
  let ring = visible_surface_ring state in
  Alcotest.(check bool) "Approvals stays visible with zero approvals and one open ask"
    true (List.exists (fun (s, _) -> s = Approvals) ring)

(* The sheet is the only place the keeper marks are named where a reader
   can read all of them at once: the Keepers rows pair each glyph with its word
   but show only the states the fleet is in, and the 34-cell roster pane beside
   the chat draws the glyph with no word at all. The list lived in
   Masc_tui_keeper_mark with no reader until the sheet took it. *)
let test_the_sheet_names_every_keeper_mark () =
  let sections = Masc_tui_keys.help_sections () in
  let marks =
    List.assoc_opt "Keeper marks" sections
  in
  match marks with
  | None -> Alcotest.fail "the sheet has no Keeper marks section"
  | Some entries ->
      Alcotest.(check int) "every mark the roster can draw is named"
        (List.length Masc_tui_keeper_mark.legend)
        (List.length entries);
      List.iter
        (fun (glyph, meaning) ->
          Alcotest.(check bool) ("mark " ^ meaning ^ " is drawn") true
            (String.length glyph > 0);
          Alcotest.(check bool) ("mark " ^ glyph ^ " is named") true
            (String.length meaning > 0))
        entries

(* The chat's tool and skill rows carry six outcome marks and eight skill
   phrases, and until the sheet took the transcript's legend nothing on any
   screen said what one meant. *)
let test_the_sheet_explains_the_chat_marks () =
  match List.assoc_opt "Chat marks" (Masc_tui_keys.help_sections ()) with
  | None -> Alcotest.fail "the sheet has no Chat marks section"
  | Some entries ->
      Alcotest.(check int) "every legend row is on the sheet"
        (List.length Masc_tui_keeper_chat_transcript.legend)
        (List.length entries)

(* The Keepers header words and the Mode S letters used to take two rows above
   the roster. The sheet holds them now, next to the marks. *)
let test_the_sheet_explains_the_keeper_columns () =
  match List.assoc_opt "Keeper columns" (Masc_tui_keys.help_sections ()) with
  | None -> Alcotest.fail "the sheet has no Keeper columns section"
  | Some entries ->
      Alcotest.(check int) "every column entry is on the sheet"
        (List.length Masc_tui_keeper_mark.column_legend)
        (List.length entries)

(* The listing tail is Global's to say. Each surface section used to end with
   r refresh / Tab next / q quit again, under a Global section that already
   names Tab / Shift-Tab, r and q. *)
let test_the_sheet_says_the_listing_tail_once () =
  let sections = Masc_tui_keys.help_sections () in
  let tail = [ ("r", "refresh"); ("Tab", "next"); ("q", "quit") ] in
  List.iter
    (fun (title, rows) ->
      if not (String.equal title "Global") then
        List.iter
          (fun row ->
            Alcotest.(check bool)
              (Printf.sprintf "%s does not repeat %s" title (fst row))
              false (List.mem row rows))
          tail)
    sections;
  match List.assoc_opt "Global" sections with
  | None -> Alcotest.fail "the sheet has no Global section"
  | Some rows ->
      List.iter
        (fun key ->
          Alcotest.(check bool) ("Global names " ^ key) true
            (List.exists (fun (k, _) -> String.equal k key) rows))
        [ "Tab / Shift-Tab"; "r"; "q" ];
      Alcotest.(check bool) "a surface's own r stays" true
        (match List.assoc_opt "Config" sections with
         | None -> false
         | Some config -> List.mem ("r", "reload") config)

let test_braille_sparkline () =
  Alcotest.(check string) "empty list gives base line" "⣀⡠⠤⠶"
    (braille_sparkline []);
  let spark = braille_sparkline [ 0.0; 0.5; 1.0 ] in
  Alcotest.(check bool) "sparkline non-empty" true (String.length spark > 0)

let test_fleet_total_cost () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  Alcotest.(check (float 0.001)) "fleet cost initially 0" 0.0
    (fleet_total_cost_usd state)

(* The golden below holds every label, so a deliberate relabelling fails it and
   asks to be looked at -- which is what it is for. The three hops are asserted
   on their own underneath, because losing one of those is not a relabelling: it
   is the only place the Config screen names a surface the ring folds under it,
   and a reader who cannot see it has no way to the surface but the palette. *)
let test_config_footer_names_child_hops () =
  (* The five short labels after f are pane-scoped writes and views that were
     in no list at all -- which pane each belongs to is in the help the ?
     overlay draws, and a pane's own footer carries only its own.

     This row is a dump of the table, not a screen. Every Config renderer
     draws [footer_hints_config ~pane], so nobody sees [e:edit] and
     [e / Enter:edit] side by side the way they stand here -- the panes that
     answer each are disjoint. Kept because it catches label drift across the
     whole table in one string; the per-pane rows below are what a reader
     meets, and [test_every_config_pane_answers_once] is what holds them to
     one answer each. *)
  check str "Config names its three off-ring children"
    "j/k:select / scroll  p:next pane  PgUp/PgDn:page  v:read status  9:Runtime  s:resources  t:tools  e:edit  e / Enter:edit  E:advanced JSON  Enter:use  x:default / clear  f:filter  n:new  u:restore  i:input  a:fragments / keeper voice  o:assets  Esc:overview  r:reload  Tab:next  q:quit"
    (Masc_tui_keys.footer_hints Config);
  let hints = Masc_tui_keys.footer_hints Config in
  List.iter
    (fun hop ->
      Alcotest.(check bool) ("Config still names " ^ hop) true
        (List.exists (String.equal hop)
           (String.split_on_char ' ' hints
            |> List.filter (fun piece -> not (String.equal piece "")))))
    [ "9:Runtime"; "s:resources"; "t:tools" ]

(* Runtime's footer comes from the table. The renderer's own line named
   neither [c], the only key to Clients, nor [Esc], the way back to Config, and
   it offered [e] as if the key table did not know it. *)
let test_runtime_footer_is_the_tables () =
  let lanes = Masc_tui_keys.footer_hints_runtime ~mode:Runtime_lanes in
  let all = Masc_tui_keys.footer_hints_runtime ~mode:Runtime_all in
  let has hints piece =
    let n = String.length piece and m = String.length hints in
    let rec go i = i + n <= m && (String.sub hints i n = piece || go (i + 1)) in
    go 0
  in
  List.iter
    (fun piece ->
      Alcotest.(check bool) ("keeper lanes name " ^ piece) true (has lanes piece))
    [ "c:clients"; "Left / Esc:back"; "p:all runtimes"; "e:add candidate"; "r:refresh"
    ; "a:new lane"; "x:drop candidate"; "J/K:move candidate"; "D:remove lane" ];
  Alcotest.(check bool) "all runtimes name where p goes" true (has all "p:service lanes");
  Alcotest.(check bool) "and offer no failover to append" false (has all "e:add candidate");
  List.iter
    (fun piece ->
      Alcotest.(check bool) ("all runtimes offer no lane edit " ^ piece) false (has all piece))
    [ "a:new lane"; "x:drop candidate"; "J/K:move candidate"; "D:remove lane" ];
  Alcotest.(check bool) "the refresh is not called live" false (has lanes "live refresh");
  (* The sheet reads the same table and names the whole walk once, because it
     is not drawn from either reading. *)
  let labels key =
    Masc_tui_keys.for_surface Runtime
    |> List.filter (fun (b : Masc_tui_keys.binding) -> String.equal b.Masc_tui_keys.key key)
    |> List.map (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.label)
  in
  Alcotest.(check (list string)) "the sheet names the p walk once"
    [ "keeper lanes / all runtimes / service lanes" ] (labels "p");
  Alcotest.(check (list string)) "and lists failover" [ "add candidate" ] (labels "e")

let test_system_logs_owns_only_its_real_filter_keys () =
  (* The newest/oldest ends and f still belong to Acting. Logs owns the server
     level floor, direct verbose toggle, and category cycle under l/v/c. *)
  let keys =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface System_logs)
  in
  Alcotest.(check bool) "no g/G on System logs" false (List.mem "g / G" keys);
  Alcotest.(check bool) "no f on System logs" false (List.mem "f" keys);
  Alcotest.(check bool) "level floor is documented" true (List.mem "l" keys);
  Alcotest.(check bool) "verbose is documented" true (List.mem "v" keys);
  Alcotest.(check bool) "category filter is documented" true (List.mem "c" keys);
  let acting =
    List.map
      (fun (b : Masc_tui_keys.binding) -> b.Masc_tui_keys.key)
      (Masc_tui_keys.for_surface Acting)
  in
  Alcotest.(check bool) "the ends stay on Acting" true (List.mem "Home/End" acting);
  Alcotest.(check bool) "f stays on Acting" true (List.mem "f" acting)

(* Read a row the way the fitter reads it. [Masc_tui_footer.item_is_pinned]
   takes an item's key up to its first colon, splits that key into atoms, and
   matches a single-atom question against them -- which is why [e / Enter] is
   pinned by "Enter". This asked a different question: it split the row on one
   space, so the atoms of a key spelled with spaces became separate tokens and
   only the last one carried the colon. [footer_has_key "e"] was false on a row
   holding [e / Enter:edit], and [footer_has_key "y"] false on [y / x:agree /
   overrule] -- the pane answers both.

   The cost was not the false answers. It was that the answer depended on
   which atom was written last: spelling the pair [Enter / e] would have
   flipped two assertions without a word of the table changing meaning. An
   assertion about a key must not turn on the order its spellings appear in. *)
let footer_has_key key row =
  let asked = Masc_tui_keys.key_atoms key in
  List.exists
    (fun item ->
      let drawn = item_key item in
      String.equal drawn key
      || (List.length asked = 1 && List.mem key (Masc_tui_keys.key_atoms drawn)))
    (footer_items row)

let fitted_footer ~cols hints =
  Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:cols ~port:8935
    ~hints ()
  |> String.trim

let test_config_pane_footer_actions () =
  let panes =
    [ Config_runtime; Config_models; Config_params; Config_prompts
    ; Config_presets; Config_themes; Config_voice ]
  in
  List.iter (fun pane ->
    let hints = Masc_tui_keys.footer_hints_config ~pane in
    let enabled key expected =
      Alcotest.(check bool) ("pane availability of " ^ key) expected
        (footer_has_key key hints)
    in
    enabled "PgUp/PgDn"
      (List.mem pane
         [ Config_runtime; Config_models; Config_prompts; Config_presets; Config_themes
         ; Config_voice ]);
    enabled "v" (pane = Config_runtime);
    enabled "E" (pane = Config_params);
    enabled "Enter" (List.mem pane [ Config_params; Config_themes ]);
    enabled "f" (pane = Config_themes);
    enabled "x" (List.mem pane [ Config_params; Config_prompts; Config_themes ]);
    (* Every pane that answers [e], including params -- where #36650 moved the
       key into the pair [e / Enter] because both spellings open the same
       field ([handle_runtime_param_edit_open] ~advanced:false). The pane was
       dropped from this list while [footer_has_key] read only a key's last
       atom, which made the line say "params does not answer e" about a pane
       whose dispatcher answers it. This is a list of what the panes do. *)
    enabled "e"
      (List.mem pane
         [ Config_runtime; Config_models; Config_params; Config_prompts; Config_voice ]);
    List.iter (fun key -> enabled key (pane = Config_presets)) [ "n"; "u" ];
    List.iter (fun key -> enabled key (pane = Config_prompts)) [ "i"; "o" ];
    (* [a] answers on two panes now: the prompt fragments, and the keeper-voice
       screen the voice pane opens. *)
    enabled "a" (List.mem pane [ Config_prompts; Config_voice ]);
    List.iter (fun key -> enabled key true) [ "j/k"; "p"; "9"; "s"; "t"; "Esc"; "q" ])
    panes;
  (* The prompts pane's read-only assets: the registry's edit keys only answer
     with a notice there, so the row does not offer them, and [o] goes back. *)
  let assets = Masc_tui_keys.footer_hints_prompt_assets in
  List.iter
    (fun key ->
      Alcotest.(check bool) ("the assets row leaves out " ^ key) false
        (footer_has_key key assets))
    [ "a"; "i"; "e"; "x" ];
  List.iter
    (fun key ->
      Alcotest.(check bool) ("the assets row keeps " ^ key) true
        (footer_has_key key assets))
    [ "j/k"; "PgUp/PgDn"; "p"; "9"; "Esc"; "q" ];
  Alcotest.(check bool) "and o names the way back" true
    (List.exists (String.equal "o:registry") (String.split_on_char ' ' assets));
  (* A cut row keeps the pane's own keys over the ones every pane shares. *)
  let at_120 hints = fitted_footer ~cols:120 hints in
  List.iter
    (fun key ->
      Alcotest.(check bool) ("presets keeps " ^ key ^ " at 120 columns") true
        (footer_has_key key (at_120 (Masc_tui_keys.footer_hints_config ~pane:Config_presets))))
    [ "n"; "u"; "PgUp/PgDn" ];
  Alcotest.(check bool) "the runtime assets keep their way back at 120 columns" true
    (footer_has_key "o" (at_120 assets));
  List.iter
    (fun key ->
      Alcotest.(check bool) ("params keeps " ^ key ^ " at 120 columns") true
        (footer_has_key key (at_120 (Masc_tui_keys.footer_hints_config ~pane:Config_params))))
    [ "Enter"; "E"; "x" ];
  (* #36650, measured: this pane does two things -- the type-aware field and
     the JSON one. While [e] and [Enter] were two items for the first, 80
     cells held both of them and dropped [E], the only item for the second.
     The fitter reads position, not meaning, so the row that survived showed
     two doors to one action and no sign of the other. One item for one
     action is what buys the cell back. *)
  let params_at_80 =
    fitted_footer ~cols:80 (Masc_tui_keys.footer_hints_config ~pane:Config_params)
  in
  Alcotest.(check bool) "params keeps its other action at 80 columns" true
    (footer_has_key "E" params_at_80);
  (* Both spellings of the field, asked separately. While [footer_has_key] saw
     only a key's last atom, the [Enter] line passed and an [e] line would
     have failed -- so the pair's two doors are named here, and a future
     spelling of [Enter / e] cannot quietly turn either answer around. *)
  Alcotest.(check bool) "params keeps the shared field at 80 columns" true
    (footer_has_key "Enter" params_at_80);
  Alcotest.(check bool) "params keeps the field's other spelling at 80 columns" true
    (footer_has_key "e" params_at_80);
  (* The themes list pages now, and its own keys still fit the row. *)
  List.iter
    (fun key ->
      Alcotest.(check bool) ("themes keeps " ^ key ^ " at 120 columns") true
        (footer_has_key key (at_120 (Masc_tui_keys.footer_hints_config ~pane:Config_themes))))
    [ "PgUp/PgDn"; "Enter"; "x"; "f" ];
  List.iter (fun pane ->
    List.iter (fun cols ->
      let row = fitted_footer ~cols (Masc_tui_keys.footer_hints_config ~pane) in
      Alcotest.(check bool) "fitted Config row stays within terminal" true
        (Masc_tui_message_layout.display_width row <= cols);
      List.iter (fun key ->
        Alcotest.(check bool) ("Config retains " ^ key) true
          (footer_has_key key row)) [ "Esc"; "q" ];
      List.iter (fun key ->
        Alcotest.(check bool) ("inactive action stays absent: " ^ key) false
          (footer_has_key key row))
        (match pane with
         | Config_runtime -> [ "E"; "Enter"; "x"; "f" ]
         | Config_themes -> [ "v"; "e"; "E" ]
         | Config_models | Config_params | Config_prompts | Config_presets
         | Config_voice -> []))
      [ 80; 120; 150; 300 ]) [ Config_runtime; Config_themes ]

(* The keeper-voice screen has its own keys, not the Config pane's: two axes,
   one write, one way out. Spelled from the table so the row cannot drift from
   what masc_tui.ml reads. *)
let test_the_keeper_voice_screen_names_its_two_axes () =
  let row = Masc_tui_keys.footer_hints_voice_agent () in
  List.iter
    (fun key ->
      Alcotest.(check bool) ("the keeper-voice row names " ^ key) true
        (footer_has_key key row))
    [ "j/k"; "\xe2\x86\x90/\xe2\x86\x92"; "Enter"; "Esc" ];
  (* The pane's keys are not this screen's: it is drawn instead of the pane. *)
  List.iter
    (fun key ->
      Alcotest.(check bool) ("the keeper-voice row leaves out " ^ key) false
        (footer_has_key key row))
    [ "p"; "e"; "9"; "r" ]

let test_the_voice_pane_offers_the_keeper_voice_key () =
  let voice = Masc_tui_keys.footer_hints_config ~pane:Config_voice in
  Alcotest.(check bool) "the voice pane names the key that opens it" true
    (footer_has_key "a" voice)

(* Activity opens on the Turns scope, where [Enter] has no individual event
   to open -- the two keys say so themselves ("Turns has no individual event
   evidence", "Actions/Everything: exact selected event"). So a row offering
   [Enter] without [f] offers a promise and hides the only key that makes it
   true.

   This went red when #36156 pinned [Enter] in [never_dropped_keys]: from
   eighty to a hundred and ten columns the fitter gave up [f] and kept
   [Enter]. Two things were wrong and neither alone was enough. [f] sat in
   [Act], which the fitter gives up before [Navigate], so it went before
   [Home/End] however short the row was; and [Enter:event evidence] spent six
   cells saying "event" on a surface whose rows are events. Both moved, the
   whole row fits from seventy-nine columns up -- measured, not reasoned: the
   sweep below was run from sixty and the last failing width was seventy-eight.

   The structural answer is still a binding that can say a key is its
   prerequisite (#36282, #35834). Until then this case is the ratchet: a
   label or a group that grows back past the budget turns it red here. *)
let test_activity_footer_keeps_filter_before_evidence () =
  let hints = Masc_tui_keys.footer_hints Acting in
  for cols = 80 to 148 do
    let row = fitted_footer ~cols hints in
    Alcotest.(check bool) "Activity stays within terminal" true
      (Masc_tui_message_layout.display_width row <= cols);
    Alcotest.(check bool) "evidence never outlives its filter prerequisite" true
      (not (footer_has_key "Enter" row) || footer_has_key "f" row);
    if cols >= 120 then begin
      Alcotest.(check bool) "filter remains visible at affected widths" true
        (footer_has_key "f" row);
      Alcotest.(check bool) "the key that opens an event is visible" true
        (footer_has_key "Enter" row)
    end
  done;
  (* One row per action: a second spelling of an action already on the row
     takes a place the fitter then takes from a key that does something else. *)
  let labels =
    List.map (fun (binding : Masc_tui_keys.binding) -> binding.label)
      (Masc_tui_keys.for_surface Acting)
  in
  Alcotest.(check int) "no two Activity rows name the same action"
    (List.length labels)
    (List.length (List.sort_uniq String.compare labels))

(* The two keys this surface exists for. Spelled apart they were two items a
   fitted footer could give up one at a time, and it did: [x] went first, then
   [a], leaving a queue of work with no drawn way to act on it.

   What is checked is that the pin can fire at all. [item_is_pinned] matches a
   pair by its exact spelling, so the key table and the pin list have to agree
   on the string; spelled apart in the table, the pin would name something the
   row never draws and would never hold anything.

   Not a width sweep. The pin makes the pair the last thing the row gives up,
   which is not the same as surviving any width: at sixty columns the pinned
   items alone are wider than the row, and the row is cut whatever is pinned.
   The width below is one where the row must drop something and still has room
   for what it keeps. *)
let test_the_verdict_pair_is_pinned_by_the_spelling_the_table_uses () =
  let keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface Verification)
  in
  Alcotest.(check bool) "the table spells the two as one key" true
    (List.mem "a / x" keys);
  Alcotest.(check bool) "and the pin names that spelling" true
    (List.mem "a / x" Masc_tui_footer.never_dropped_keys);
  let hints = Masc_tui_keys.footer_hints Verification in
  let cut = fitted_footer ~cols:120 hints in
  Alcotest.(check bool) "the row had to drop something" true
    (String.length cut < String.length hints);
  Alcotest.(check bool) "and what it kept includes the way to answer" true
    (String.split_on_char ' ' cut
     |> List.exists (String.starts_with ~prefix:"x:approve"))

let section name =
  match List.assoc_opt name (Masc_tui_keys.help_sections ()) with
  | Some entries -> entries
  | None -> Alcotest.failf "help has no %S section" name

let test_help_documents_what_was_missing () =
  (* Changes shipped Enter/d/o with no help section; the palette had no row
     anywhere. *)
  let changes = List.map fst (section "Changes") in
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf "Changes documents %S" key)
        true (List.mem key changes))
    [ "[ / ]"; "Right / Enter"; "Left / Esc"; "d"; "o" ];
  let global = List.map fst (section "Global") in
  Alcotest.(check bool) "the palette has a row" true (List.mem ":" global);
  Alcotest.(check bool) "the cross-surface Keepers jump has a row" true
    (List.mem "2" global);
  let logs = List.map fst (section "Activity / Logs") in
  Alcotest.(check bool) "Logs documents only what is bound" false
    (List.mem "g / G" logs)

(* The fact browser's Enter opens a reading whose keys the surface list cannot
   carry: one fact scrolls under the cursor, so it owns page and edge keys the
   browser row has none of, and the browser row's Enter means something else
   under that name. A reader who has not pressed them learns them from [?], so
   the sheet files both rows under Memory with the screen named -- and the
   footer the reading draws projects that same binding table, so the two cannot
   teach different keys. *)
let test_the_sheet_carries_the_fact_detail_keys () =
  let memory = section "Memory" in
  let detail =
    List.filter
      (fun (_, help) -> String.starts_with ~prefix:"in the fact detail: " help)
      memory
  in
  Alcotest.(check int) "the sheet files the reading's four keys" 4
    (List.length detail);
  List.iter
    (fun pair ->
      Alcotest.(check bool)
        (Printf.sprintf "the sheet files %S" (fst pair))
        true
        (List.mem pair detail))
    [ ("j/k", "in the fact detail: scroll")
    ; ("PgUp/PgDn", "in the fact detail: page")
    ; ("g / G", "in the fact detail: jump to the first or last line of the fact")
    ; ("Esc", "in the fact detail: return to the fact list")
    ];
  Alcotest.(check bool) "the browser row is filed under Memory too" true
    (List.exists
       (fun (_, help) ->
         String.starts_with
           ~prefix:"in the facts browser: read the whole fact"
           help)
       memory);
  Alcotest.(check string) "the footer projects the same binding table"
    "j/k:scroll  PgUp/PgDn:page  g / G:top/bottom  Esc:close"
    Masc_tui_keys.memory_fact_detail_hints

let test_keepers_jump_uses_one_binding_for_dispatch_and_help () =
  let global_twos =
    List.filter
      (fun (binding : Masc_tui_keys.binding) -> String.equal binding.key "2")
      Masc_tui_keys.global
  in
  Alcotest.(check int) "Global declares 2 once" 1 (List.length global_twos);
  Alcotest.(check bool) "2 opens Keepers after local input declines it" true
    (Masc_tui_keys.opens_keepers ~message_mode:false "2");
  Alcotest.(check bool) "message input keeps printable 2" false
    (Masc_tui_keys.opens_keepers ~message_mode:true "2");
  Alcotest.(check bool) "another key does not open Keepers" false
    (Masc_tui_keys.opens_keepers ~message_mode:false "x");
  Alcotest.(check string) "Help states the local-owner boundary"
    "jump to Keepers when the active field or panel does not use 2"
    (List.assoc "2" (section "Global"));
  let overview_keys =
    List.map
      (fun (binding : Masc_tui_keys.binding) -> binding.key)
      (Masc_tui_keys.for_surface Overview)
  in
  Alcotest.(check bool) "2 is not an Overview-only binding" false
    (List.mem "2" overview_keys)

(* The sheet opens on the reader's own surface. Without this the answer to
   "what can I do here" sat behind nineteen other surfaces, in strip order,
   and the reader had to search a reference for it. *)
let test_the_sheet_opens_on_the_current_surface () =
  List.iter
    (fun (name, surface, expected) ->
       match Masc_tui_keys.help_sections ~current:surface () with
       | (title, keys) :: _ ->
           Alcotest.(check bool)
             (name ^ ": names the surface first")
             true
             (String.length title >= String.length expected
              && String.equal (String.sub title 0 (String.length expected))
                   expected);
           (* The section has to be that surface's, not just titled like it:
              its own keys, less the tail Global names. *)
           Alcotest.(check (list (pair string string)))
             (name ^ ": and carries its keys")
             (List.map
                (fun (b : Masc_tui_keys.binding) ->
                   (b.key, Option.value b.help ~default:b.label))
                (Masc_tui_keys.sheet_bindings surface))
             keys
       | [] -> Alcotest.fail (name ^ ": no sections at all"))
    [ ("Overview", Overview, "Overview")
    ; ("Keepers", Keepers Keeper_list, "Keepers")
    ; ("Chat", Keepers Keeper_message, "Chat")
    ; ("Config", Config, "Config")
    ]

(* The Keepers sub-modes are one entry on the strip and three sections here.
   Matching by ring position would hand a reader in the chat the roster's
   keys, which is the drift this argument exists to prevent. *)
let test_the_keeper_sub_modes_do_not_share_a_section () =
  let first surface =
    match Masc_tui_keys.help_sections ~current:surface () with
    | (title, _) :: _ -> title
    | [] -> "none"
  in
  Alcotest.(check bool)
    "the roster and the chat open on different sections" false
    (String.equal (first (Keepers Keeper_list)) (first (Keepers Keeper_message)))

(* Asked without a surface, the sheet reads as it did before it knew where the
   reader was: Global, then the strip's order. *)
let test_without_a_surface_the_order_is_the_strips () =
  match Masc_tui_keys.help_sections () with
  | (title, _) :: (second, _) :: _ ->
      Alcotest.(check string) "Global first" "Global" title;
      Alcotest.(check string) "then the strip's first surface" "Overview" second
  | _ -> Alcotest.fail "expected at least two sections"

(* --- Lanes drill-down: the lane notice, the combined "/" search list, and
   the click geometry of the overview frame. --- *)

let standalone_lane ~lane_id ~label : Tui_decode.standalone_lane =
  { Tui_decode.sl_lane_id = lane_id
  ; sl_label = label
  ; sl_purpose = None
  ; sl_required = false
  ; sl_status = Tui_decode.Standalone_idle
  ; sl_configuration_state = Tui_decode.Lane_ready
  ; sl_jev = None
  ; sl_admitted_slots = []
  ; sl_cli_slots = []
  ; sl_dropped_slots = []
  ; sl_declared_slots = []
  ; sl_admission_error = None
  ; sl_retained_run_count = 0
  ; sl_running_count = 0
  ; sl_succeeded_count = 0
  ; sl_failed_count = 0
  ; sl_cancelled_count = 0
  ; sl_last_started_at = None
  ; sl_last_terminal_at = None
  ; sl_last_outcome = None
  ; sl_p50_elapsed_s = None
  ; sl_selected_slots = []
  ; sl_runs_without_slot =
      { Tui_decode.slws_vendor_system_one = 0; slws_server_restarted = 0; slws_no_slot = 0 }
  }

(* The four lanes the projection fixes, in its order
   (server_standalone_lane_projection.ml). *)
let four_standalone_lanes =
  [ standalone_lane ~lane_id:"board_attention_exact" ~label:"Board Attention"
  ; standalone_lane ~lane_id:"hitl_auto_judge" ~label:"HITL Auto Judge"
  ; standalone_lane ~lane_id:"librarian_exact" ~label:"Librarian"
  ; standalone_lane ~lane_id:"verifier_exact" ~label:"Verifier"
  ]

let standalone_snapshot lanes : Tui_decode.standalone_lanes_snapshot =
  { Tui_decode.sls_observed_at_unix = 0.
  ; sls_exact_run_projection_count = 0
  ; sls_exact_run_source_total = 0
  ; sls_exact_run_projection_truncated = false
  ; sls_lanes = lanes
  }

let keeper_lane name : Tui_decode.keeper_lane =
  { Tui_decode.kl_keeper = name
  ; kl_phase = Tui_decode.Lane_phase_running
  ; kl_turn_phase = Tui_decode.Lane_turn_idle
  ; kl_idle_seconds = 0
  ; kl_last_outcome = None
  ; kl_conditions =
      { Tui_decode.klc_launch_pending = false
      ; klc_heartbeat_healthy = true
      ; klc_turn_healthy = true
      }
  }

let keeper_snapshot lanes : Tui_decode.keeper_lanes_snapshot =
  { Tui_decode.kls_generated_at = 0.
  ; kls_count = List.length lanes
  ; kls_lanes = lanes
  }

let lanes_state ?(keepers = [ "alpha"; "beta" ]) () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Lanes;
  state.standalone_lanes <- Some (standalone_snapshot four_standalone_lanes);
  state.lanes <- Some (keeper_snapshot (List.map keeper_lane keepers));
  state

let test_lanes_search_texts_lead_with_the_standalone_labels () =
  let state = lanes_state () in
  Alcotest.(check (option (list string)))
    "only standalone labels are searchable"
    (Some
       [ "Board Attention"; "HITL Auto Judge"; "Librarian"
       ; "Verifier" ])
    (surface_row_texts state Lanes)

(* Resources draws a list beside a reading, and j/k means one thing in each.
   The search follows the same split: a match lands the list cursor, and with
   the reading focused there is no cursor for it to land on.

   The row text is the name the list actually draws -- the server's title
   when it sent one -- because a search that matches a name nothing on screen
   shows finds rows the reader cannot see. Both readers take it from
   [Masc_tui_mcp.display_name]. *)
let resources_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Resources;
  state.resources_list <-
    Some
      [ { Masc_tui_mcp.uri = "masc://board"; name = "board"
        ; title = Some "Board posts"; description = None
        ; mime_type = None; size = None }
      ; { Masc_tui_mcp.uri = "masc://keepers"; name = "keepers"
        ; title = None; description = None
        ; mime_type = None; size = None }
      ; { Masc_tui_mcp.uri = "masc://lanes"; name = "lanes"
        ; title = Some "   "; description = None
        ; mime_type = None; size = None }
      ];
  state

let test_resources_searches_the_names_the_list_draws () =
  let state = resources_state () in
  Alcotest.(check (option (list string)))
    "the title when there is one, the name otherwise, and a blank title is \
     not one"
    (Some [ "Board posts"; "keepers"; "lanes" ])
    (surface_row_texts state Resources)

let test_the_resource_reading_offers_no_row_search () =
  let state = resources_state () in
  state.resource_focus <- Right_pane;
  Alcotest.(check (option (list string)))
    "with the text focused there is no cursor to land a match on" None
    (surface_row_texts state Resources);
  state.resource_focus <- Left_pane;
  Alcotest.(check Alcotest.bool) "and the list has one again" true
    (Option.is_some (surface_row_texts state Resources))

let test_resources_without_a_list_answers_nothing () =
  let state = resources_state () in
  state.resources_list <- None;
  Alcotest.(check (option (list string)))
    "before the catalog arrives there are no rows" None
    (surface_row_texts state Resources)

let test_lanes_sub_modes_stay_unsearchable () =
  let state = lanes_state () in
  state.lanes_mode <- Lanes_run_list "librarian_exact";
  Alcotest.(check (option (list string))) "run list keeps / closed" None
    (surface_row_texts state Lanes);
  state.lanes_mode <- Lanes_run_detail ("verifier_exact", "vrf-1");
  Alcotest.(check (option (list string))) "run detail keeps / closed" None
    (surface_row_texts state Lanes)

(* Board and Planning answer "/" over the list they draw. Both panes window
   themselves around the cursor, so a landing is on screen without a scroll
   to follow it; what has to hold is that the searched text is the list the
   cursor counts positions in, and that the panes which are not a list keep
   the key closed. *)

let board_post ?(author = "alpha") id title =
  { bp_id = id
  ; bp_author = author
  ; bp_title = title
  ; bp_body = "body nobody searches"
  ; bp_votes = 0
  ; bp_comment_count = 0
  ; bp_created_at = "2026-09-04T00:00:00Z"
  ; bp_created_at_unix = None; bp_updated_at = None
  ; bp_hearth = None
  ; bp_kind = None
  }

let board_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Board;
  state.board_posts <-
    [ board_post "p-1" "release evidence sweep"
    ; board_post ~author:"beta" "p-2" "frame budget"
    ];
  state

let test_board_searches_the_post_list () =
  let state = board_state () in
  Alcotest.(check (option (list string)))
    "id, author and title -- what the list draws"
    (Some
       [ "p-1 alpha release evidence sweep"; "p-2 beta frame budget" ])
    (surface_row_texts state Board)

let test_board_reading_and_writing_keep_the_key_closed () =
  let state = board_state () in
  state.board_mode <- Board_read "p-1";
  Alcotest.(check (option (list string))) "reading a post" None
    (surface_row_texts state Board);
  state.board_mode <- Board_compose;
  (* Writing is the stronger case: "/" there is draft text. *)
  Alcotest.(check (option (list string))) "writing a post" None
    (surface_row_texts state Board)

let test_board_without_posts_offers_nothing_to_search () =
  let state = board_state () in
  state.board_posts <- [];
  Alcotest.(check (option (list string))) "no rows" None
    (surface_row_texts state Board)

let planning_goal_row id title =
  { pg_id = id
  ; pg_title = title
  ; pg_phase = Goal_phase.Executing
  ; pg_priority = 1
  ; pg_due_date = None
  ; pg_metric = None
  ; pg_target_value = None
  ; pg_proof = Tui_decode.Proof_idle
  ; pg_last_review_note = None
  ; pg_last_review_at = None
  ; pg_created_at = None
  ; pg_updated_at = None
  }

let planning_state () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Planning;
  state.planning <-
    Some
      { pl_goals =
          [ planning_goal_row "g-1" "cut the frame budget"
          ; planning_goal_row "g-2" "paste follows the field"
          ]
      ; pl_rollup = { pr_active = 2
          ; pr_verifying = 0
          ; pr_awaiting_confirmation = 0
          ; pr_done = 0
          ; pr_dropped = 0
          }
      ; pl_backlog =
          { pb_todo = 0; pb_claimed = 0; pb_running = 0
          ; pb_awaiting_verification = 0; pb_done = 0; pb_cancelled = 0 }
      (* This surface's key tests are about the rows the cursor walks, and the
         history lines sit above the divider outside them. Empty keeps the
         fixture about that. *)
      ; pl_goal_history = []
      ; pl_generated_at = "2026-09-04T00:00:00Z"
      };
  state

let test_planning_searches_the_goals_the_list_shows () =
  let state = planning_state () in
  Alcotest.(check (option (list string)))
    "id and title"
    (Some [ "g-1 cut the frame budget"; "g-2 paste follows the field" ])
    (surface_row_texts state Planning)

let test_planning_searches_what_the_filter_left () =
  (* The cursor counts positions in the filtered, sorted list, so the search
     has to walk that list and not the snapshot: a filter that hides a goal
     would otherwise land the cursor one row off for every goal it hid. *)
  let state = planning_state () in
  state.planning_filter <- Planning_filter_completed;
  Alcotest.(check (option (list string)))
    "nothing active survives the completed filter" None
    (surface_row_texts state Planning)

let test_planning_detail_keeps_the_key_closed () =
  let state = planning_state () in
  state.planning_mode <- Planning_detail "g-1";
  Alcotest.(check (option (list string))) "a goal is open" None
    (surface_row_texts state Planning)

let hit_to_string = function
  | Lanes_hit_standalone index -> Printf.sprintf "standalone %d" index
  | Lanes_hit_none -> "none"

let check_hit state ~terminal_rows ~row expected =
  check str (Printf.sprintf "row %d" row) expected
    (hit_to_string (lanes_overview_hit state ~terminal_rows ~row))

(* The overview frame, row by row: 1 strip, 2 box top, 3 header, 4 divider,
   5 standalone heading, 6 the Add-ons summary, 7 the table heading, and 8-11
   the four standalone rows. Everything below is note/padding/footer chrome,
   never a hidden Keeper table.

   This list is a second hand count of what [render_lanes_overview] draws, and
   it went on agreeing with the first while both were two rows short. The
   screen itself answers in the PTY walk "a press selects the lane drawn under
   it"; this case holds the edges around it. *)
let test_overview_hit_reads_the_frame_rows () =
  let state = lanes_state () in
  check_hit state ~terminal_rows:40 ~row:7 "none";
  check_hit state ~terminal_rows:40 ~row:8 "standalone 0";
  check_hit state ~terminal_rows:40 ~row:11 "standalone 3";
  check_hit state ~terminal_rows:40 ~row:12 "none";
  check_hit state ~terminal_rows:40 ~row:12 "none";
  check_hit state ~terminal_rows:40 ~row:13 "none";
  check_hit state ~terminal_rows:40 ~row:14 "none";
  check_hit state ~terminal_rows:40 ~row:15 "none"

let test_overview_hit_pays_for_the_error_rows () =
  let state = lanes_state () in
  state.lanes_error <- Some "lane fixture failed";
  (* Keeper-composite errors are not part of the Standalone frame geometry. *)
  check_hit state ~terminal_rows:40 ~row:14 "none";
  check_hit state ~terminal_rows:40 ~row:15 "none";
  state.lanes_action_error <- Some "Cannot open detail: no lane is selected";
  check_hit state ~terminal_rows:40 ~row:16 "none";
  check_hit state ~terminal_rows:40 ~row:17 "none"

let test_overview_hit_waits_for_the_matrix () =
  (* The matrix's single loading note is not a lane row. *)
  let state = lanes_state () in
  state.standalone_lanes <- None;
  check_hit state ~terminal_rows:40 ~row:8 "none";
  check_hit state ~terminal_rows:40 ~row:11 "none";
  check_hit state ~terminal_rows:40 ~row:12 "none"

(* The detail tabs used to draw a hand-written hint string in the renderer,
   a second key list this module did not own. The strip must project the
   table, and the sheet must carry the same keys -- otherwise the two can
   name different things again, which is how [T] ended up documented
   nowhere. *)
let has_substring haystack needle =
  let hl = String.length haystack and nl = String.length needle in
  let rec scan i = i + nl <= hl && (String.sub haystack i nl = needle || scan (i + 1)) in
  nl = 0 || scan 0

let test_detail_tab_hint_projects_the_table () =
  List.iter
    (fun tab ->
       let hint = Masc_tui_keys.keeper_detail_tab_hint tab in
       Alcotest.(check bool)
         ("the tab switch leads on " ^ keeper_detail_tab_label tab)
         true
         (String.length hint >= 7 && String.sub hint 0 7 = "[ ]:tab");
       List.iter
         (fun (binding : Masc_tui_keys.binding) ->
            Alcotest.(check bool)
              (binding.Masc_tui_keys.key ^ " reaches the strip")
              true
              (has_substring hint
                 (binding.Masc_tui_keys.key ^ ":" ^ binding.Masc_tui_keys.label)))
         (Masc_tui_keys.keeper_detail_tab_bindings tab))
    keeper_detail_tabs

(* The keys each tab's dispatcher arms actually handle, pinned. The earlier
   pair of assertions only checked that whatever the table held reached the
   strip and the sheet, so dropping a binding passed both -- the same shape
   as the drift they were written to close. This list is the contract:
   changing it is a decision, not a slip. Sources are the guarded arms in
   masc_tui.ml (T/A// at Detail_identity, R at Detail_identity, L/P and one
   digit per login scope on the GitHub tab, e for the settings form, Q for
   the Board requeue on Info). *)
let live_tab_keys : (Masc_tui_types.keeper_detail_tab * string list) list =
  [ Detail_info, [ "Q" ]
  ; Detail_sandbox, [ "o"; "d/m/s"; "PgUp/PgDn"; "R" ]
  ; Detail_instructions, [ "e" ]
  ; Detail_secrets, []
  ; Detail_github, [ "L"; "P"; "1"; "2" ]
  ; Detail_identity, [ "arrows+enter"; "T"; "A"; "/"; "R" ]
  ; Detail_channels, [ "j/k"; "J/K"; "PgUp/PgDn"; "b / e / u u"; "U U" ]
  ; Detail_automation, []
  ; Detail_runs, []
  ]

(* The table's own key notation, read as single keys. The Keeper detail
   footer drops a control whose key a tab answers itself, so the Sandbox
   tab's "d/m/s" has to be read as the [s] it takes from shutdown. *)
let test_key_atoms_read_the_table_notation () =
  let atoms = Masc_tui_keys.key_atoms in
  Alcotest.(check (list string)) "alternatives" [ "d"; "m"; "s" ] (atoms "d/m/s");
  Alcotest.(check (list string)) "spaced alternatives and a double press"
    [ "b"; "e"; "u" ] (atoms "b / e / u u");
  Alcotest.(check (list string)) "a chord" [ "arrows"; "enter" ] (atoms "arrows+enter");
  Alcotest.(check (list string)) "a single key" [ "L" ] (atoms "L");
  Alcotest.(check bool) "Sandbox takes s and o" true
    (List.for_all
       (fun key -> List.mem key (Masc_tui_keys.keeper_detail_tab_taken_keys Detail_sandbox))
       [ "s"; "o" ]);
  Alcotest.(check bool) "Channels takes e" true
    (List.mem "e" (Masc_tui_keys.keeper_detail_tab_taken_keys Detail_channels));
  Alcotest.(check bool) "Channels takes U for unbind all" true
    (List.mem "U" (Masc_tui_keys.keeper_detail_tab_taken_keys Detail_channels));
  Alcotest.(check (list string)) "Info takes only the Board requeue key" [ "Q" ]
    (Masc_tui_keys.keeper_detail_tab_taken_keys Detail_info)

let test_detail_tab_bindings_cover_the_live_keys () =
  List.iter
    (fun (tab, expected) ->
       let actual =
         List.map
           (fun (binding : Masc_tui_keys.binding) -> binding.Masc_tui_keys.key)
           (Masc_tui_keys.keeper_detail_tab_bindings tab)
       in
       Alcotest.(check (list string))
         (keeper_detail_tab_label tab ^ " tab keys")
         expected actual)
    live_tab_keys

let test_keeper_detail_reserves_lowercase_u_for_channel_unbind () =
  let keys =
    Masc_tui_keys.for_surface (Keepers Keeper_detail)
    |> List.map (fun (binding : Masc_tui_keys.binding) -> binding.key)
  in
  Alcotest.(check bool) "uppercase runtime remains" true (List.mem "U" keys);
  Alcotest.(check bool) "lowercase u is free for Channels" false
    (List.mem "u" keys)

let test_a_loop_turn_without_input_keeps_an_arm () =
  (* The defect this closes: the dispatch loop turns on its own timeout as
     well as on input, so reading that turn as an unrelated key left every
     two-press arm alive for exactly one iteration. Two [u] presses removed a
     channel binding only when both bytes arrived in the same read. *)
  check Alcotest.bool "a turn that read nothing cancels nothing" false
    (Masc_tui_keys.cancels_two_press ~input_seen:false ~key:None
       ~second_press:[ "u" ]);
  check Alcotest.bool "and the key it did not read is not the second press"
    false
    (Masc_tui_keys.cancels_two_press ~input_seen:false ~key:(Some "j")
       ~second_press:[ "u" ])

let test_input_that_is_not_the_second_press_cancels () =
  (* [key] is [None] for a mouse report, a paste, and a graphics reply. Those
     are input the operator produced, so they end the confirmation. *)
  check Alcotest.bool "a mouse report or a paste cancels" true
    (Masc_tui_keys.cancels_two_press ~input_seen:true ~key:None
       ~second_press:[ "u" ]);
  List.iter
    (fun (pressed, second_press, expected, label) ->
       check Alcotest.bool label expected
         (Masc_tui_keys.cancels_two_press ~input_seen:true
            ~key:(Some pressed) ~second_press))
    [ "u", [ "u" ], false, "the second press holds the arm"
    ; "j", [ "u" ], true, "a cursor move cancels it"
    ; "U", [ "u" ], true, "a different case is a different key"
    ; "Y", [ "y"; "Y"; "n"; "N" ], false, "either answer holds the approval"
    ; "e", [ "y"; "Y"; "n"; "N" ], true, "an unrelated key cancels it"
    ; "x", [], true, "an arm with no second press cancels on any key"
    ]

let surface_keys surface =
  List.map
    (fun (binding : Masc_tui_keys.binding) -> binding.Masc_tui_keys.key)
    (Masc_tui_keys.for_surface surface)

(* Every surface [Masc_tui_types.surface_row_texts] can answer with rows.
   Read off that function's arms, which is where the row search comes from:
   the arm that opens [/] asks it, and so does the arm that steps [n] / [N].
   Keeper detail is absent on purpose -- its rows exist only while the
   context inspector is open on the request tab, and both that inspector and
   the Identity tab's filter claim [/] above the surface search and declare
   it in their own tables. *)
let surfaces_that_answer_the_row_search =
  [ "Keepers", Keepers Keeper_list
  ; "Lanes", Lanes
  ; "Verification", Verification
  ; "Harness", Harness
  ; "Repositories", Repositories
  ; "Memory", Memory
  ; "Connectors", Connectors
  ; "Runtime", Runtime
  ; "System logs", System_logs
  ; "Code", Code
  ; "Board", Board
  ; "Planning", Planning
  ; "Fusion", Fusion
  ; "Changes", Changes
  (* The list pane. The reading has no cursor, and the footer it draws for
     that focus drops both keys. *)
  ; "Resources", Resources
  ]

let test_code_search_count_tracks_fetched_source () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Code;
  state.code_focus_file <- Right_pane;
  let load path rows =
    match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:path with
    | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
    | Masc_tui_fetched.Started (next, request) ->
        state.code_file <- Masc_tui_fetched.complete ~equal:String.equal next request (Ok rows)
  in
  let count query = surface_search_count state Code ~query in
  load "large.ml" (Array.init 20_000 (fun index ->
    [((if index mod 2 = 0 then "needle" else "other"), "")]));
  Alcotest.(check (option int)) "large file count" (Some 10_000) (count "needle");
  let first_reading = !code_search_count_memo in
  Alcotest.(check (option int)) "repaint keeps the count" (Some 10_000) (count "needle");
  Alcotest.(check bool) "repaint reuses the settled reading" true
    (first_reading == !code_search_count_memo);
  Alcotest.(check (option int)) "query change recounts" (Some 0) (count "absent");
  load "large.ml" [|[("needle", "")]|];
  Alcotest.(check (option int)) "same-path replacement recounts" (Some 1) (count "needle");
  state.code_focus_file <- Left_pane;
  Alcotest.(check (option int)) "tree does not reuse file matches" (Some 0) (count "needle");
  state.code_focus_file <- Right_pane;
  state.repository_changes_open <- true;
  Alcotest.(check (option int)) "overlay without a source has no count" None (count "needle");
  state.repository_changes_open <- false;
  state.code_file <- Masc_tui_fetched.clear state.code_file;
  Alcotest.(check (option int)) "closed file has no source" None (count "needle");
  load "empty.ml" [||];
  Alcotest.(check (option int)) "loaded empty file has zero matches" (Some 0) (count "needle")

let test_detail_search_counts_follow_the_active_pane () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.search_last <- "needle";
  state.harness <- Some
    { Tui_decode.hs_verdicts =
        [{ Tui_decode.hv_at = 1.; hv_task_id = "task-1";
           hv_task_title = "needle"; hv_agent = "agent"; hv_gate = "gate";
           hv_verdict = "approve"; hv_evaluator = "evaluator";
           hv_fallback_reason = None; hv_notes_hash = "hash" }];
      hs_calibration = None; hs_overview = None };
  state.system_logs <- Some
    { Tui_decode.sys_entries =
        [{ Tui_decode.sl_seq = 1; sl_ts = "2026-09-13T00:00:00Z";
           sl_level = Tui_decode.System_info;
           sl_source = Tui_decode.System_structured;
           sl_module = "test"; sl_keeper = None; sl_turn = None;
           sl_message = "needle"; sl_details = `Null; sl_category = None }];
      sys_total = 1; sys_latest_seq = 1 };
  let check_pane label surface set_detail =
    state.view <- surface;
    let count () = surface_search_count state surface ~query:state.search_last in
    Alcotest.(check (option int)) (label ^ " list count") (Some 1) (count ());
    Alcotest.(check bool) (label ^ " list has a cursor") true
      (Option.is_some (scrolled_surface_rows state surface));
    set_detail true;
    Alcotest.(check (option int)) (label ^ " detail has no count or n/N") None (count ());
    Alcotest.(check (option (list string))) (label ^ " detail has no search rows")
      None (surface_row_texts state surface);
    Alcotest.(check bool) (label ^ " detail has no cursor") false
      (Option.is_some (scrolled_surface_rows state surface));
    set_detail false;
    Alcotest.(check (option int)) (label ^ " return restores count") (Some 1) (count ());
    Alcotest.(check bool) (label ^ " return restores cursor") true
      (Option.is_some (scrolled_surface_rows state surface));
    Alcotest.(check string) (label ^ " keeps settled query") "needle" state.search_last
  in
  check_pane "Harness" Harness
    (fun detail -> state.harness_detail <- if detail then Some ("task-1", 1.) else None);
  check_pane "System logs" System_logs
    (fun detail -> state.system_logs_detail_seq <- if detail then Some 1 else None)

let test_changes_diff_uses_visible_search_rows () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let payload = Yojson.Safe.from_string {|{
    "keeper":"alpha", "window_hours":24, "calls_in_window":1,
    "over_budget":0, "malformed":0,
    "changes":[{"at":1, "keeper":"alpha", "turn":1, "task_id":"task-1",
      "execution_id":"exec-change", "line_evidence":null,
      "location":{"kind":"repo","repo_id":"masc","path":"needle.ml"},
      "change":{"kind":"write","content":"let value = 1"}, "succeeded":true}]
  }|} in
  state.changes <- Some (match Tui_decode.decode_file_change_snapshot payload with
    | Ok snapshot -> snapshot | Error detail -> Alcotest.fail detail);
  state.view <- Changes;
  state.search_last <- "needle";
  let check_list label =
    Alcotest.(check (option int)) (label ^ " visible count") (Some 1)
      (surface_search_count state Changes ~query:state.search_last);
    Alcotest.(check bool) (label ^ " cursor available") true
      (Option.is_some (scrolled_surface_rows state Changes)) in
  check_list "list";
  state.changes_diff_row <- Some 0;
  Alcotest.(check (option (list string))) "diff has no hidden search rows" None
    (surface_row_texts state Changes);
  Alcotest.(check (option int)) "diff has no hidden list count" None
    (surface_search_count state Changes ~query:state.search_last);
  Alcotest.(check bool) "diff cannot move a hidden list cursor" false
    (Option.is_some (scrolled_surface_rows state Changes));
  state.changes_diff_row <- None;
  check_list "return";
  state.changes_diff_row <- Some 1;
  Alcotest.(check bool) "stale index does not open a diff" false
    (Option.is_some (opened_file_change state));
  check_list "refresh removed open row";
  Alcotest.(check string) "settled query survives" "needle" state.search_last

let test_workspace_activity_offers_no_row_search () =
  (* [h] on a repository row replaces the list with that repository's own
     activity rows and its own cursor, and the handler there takes every key
     the surface has, "/" and n and N among them. What sits behind it is the
     repository list, so a settled query counted rows that no key on this
     screen could reach and the footer reported the number. *)
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let repository : Tui_decode.repository =
    { rp_id = "masc"; rp_name = "masc"; rp_codebase = None; rp_url = ""
    ; rp_local_path = "."; rp_resolved_local_path = "/tmp/masc"
    ; rp_default_branch = "main"
    ; rp_status = Tui_decode.Repository_status Repo_manager_types.Active
    ; rp_keepers = []
    ; rp_auto_sync = false }
  in
  state.view <- Repositories;
  state.repositories <-
    Some { Tui_decode.rs_repositories = [ repository ]; rs_total = 1 };
  Alcotest.(check (option int)) "the repository list answers the search"
    (Some 1) (surface_search_count state Repositories ~query:"masc");
  state.workspace_activity_repo <- Some "masc";
  Alcotest.(check (option int)) "Workspace Activity answers no search"
    None (surface_search_count state Repositories ~query:"masc")

let test_every_searchable_surface_names_its_search () =
  (* A key that works and is not listed is the same drift as a listed key
     that does nothing, pointing the other way. Eight of these ten answered
     [/] and said nothing about it. *)
  List.iter
    (fun (label, surface) ->
       let keys = surface_keys surface in
       check Alcotest.bool (label ^ " names /") true (List.mem "/" keys);
       check Alcotest.bool (label ^ " names n / N") true
         (List.mem "n / N" keys))
    surfaces_that_answer_the_row_search

let test_a_surface_without_rows_offers_no_row_search () =
  (* The other direction: [/] on these reaches the same arm and finds no row
     list, so listing it would advertise a key that does nothing. Board's
     Search-group [f] narrows to a hearth and is not the row search. *)
  List.iter
    (fun (label, surface) ->
       check Alcotest.bool (label ^ " has no row list to search") false
         (List.mem "/" (surface_keys surface)))
    [ "Overview", Overview
    ; "Activity", Acting
    ; "Keeper detail", Keepers Keeper_detail
    ; "Keeper logs", Keepers Keeper_logs
    ; "Keeper calls", Keepers Keeper_calls
    ; "Chat", Keepers Keeper_message
    ; "Runtime pick", Keepers Keeper_runtime_pick
      (* Both have rows worth searching and still say no "/", for the same
         reason and it is [n]. The key that steps to the next match is the
         key these two give to something else: on Approvals it denies the
         presented approval, unarmed and immediate, and on Schedules it opens
         the form for a new one. A search whose own follow-through refuses an
         approval is worse than no search, so these wait on a different step
         key rather than on another arm in [surface_row_texts] (#35306). *)
    ; "Approvals", Approvals
    ; "Schedules", Schedules
    ; "Config", Config
    ; "Tools", Tools
    ]

(* An open approval is a yes-or-no question, and its footer used to spell the
   answer as two items -- "y:confirm  n:deny" -- which a fitted row drops one
   at a time: at 44 cells it had lost [n], and at 34 both. The pinned spelling
   is "y / n", the one the queue's own row already used. *)
let test_an_open_approval_keeps_its_answer_keys_at_every_width () =
  let hints = Masc_tui_keys.footer_hints_approval_detail in
  let holds needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i =
      i + n <= h
      && (String.equal (String.sub haystack i n) needle || scan (i + 1))
    in
    scan 0
  in
  Alcotest.(check bool) "the queue and the open approval spell it alike" true
    (holds "y / n:decide" hints);
  List.iter
    (fun width ->
      let row =
        Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:width ~port:8935
          ~hints ()
      in
      Alcotest.(check bool)
        (Printf.sprintf "the answer survives %d cells" width)
        true
        (holds "y / n" row);
      Alcotest.(check bool)
        (Printf.sprintf "and so does the way out at %d cells" width)
        true
        (holds "Esc" row))
    [ 120; 60; 44; 34 ]

let test_the_code_footer_names_the_keys_of_the_pane_it_draws () =
  (* The renderer used to spell this footer by hand, naming d, H, m and w.
     The three language-server questions worked on that screen and never
     appeared on it; blame and the row search did not either once they
     arrived. Projected from the table now, narrowed per pane. *)
  let file = Masc_tui_keys.footer_hints_code ~pane:Masc_tui_keys.Code_file in
  let tree = Masc_tui_keys.footer_hints_code ~pane:Masc_tui_keys.Code_tree in
  let overlay =
    Masc_tui_keys.footer_hints_code ~pane:Masc_tui_keys.Code_overlay
  in
  let holds needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i =
      i + n <= h
      && (String.equal (String.sub haystack i n) needle || scan (i + 1))
    in
    scan 0
  in
  List.iter
    (fun hint ->
       check Alcotest.bool ("an open file names " ^ hint) true
         (holds hint file))
    [ "K:hover"; "D:definition"; "R:references"; "b:blame"; "/:find"
    ; "d:diff"; "H:history"; "m:notes" ];
  check Alcotest.bool "an open file scrolls" true (holds "j/k:scroll" file);
  (* The tree answers none of the file's keys, and says so by not naming
     them -- a hint for a key the pane will not take is the same lie as a
     key with no hint. *)
  List.iter
    (fun hint ->
       check Alcotest.bool ("the tree does not name " ^ hint) false
         (holds hint tree))
    [ "K:hover"; "D:definition"; "R:references"; "b:blame"; "H:history" ];
  check Alcotest.bool "the tree moves" true (holds "j/k:move" tree);
  (* An overlay covers the code, so the keys that act on it are gone while
     it is up. *)
  check Alcotest.bool "an overlay drops the code keys" false
    (holds "b:blame" overlay);
  (* The history view has commits to open; the other two panes do not, and
     named the key anyway until it was read off a running screen. *)
  check Alcotest.bool "an overlay opens a commit" true
    (holds "Enter (history):open" overlay);
  List.iter
    (fun (label, hints) ->
       check Alcotest.bool (label ^ " has no commit to open") false
         (holds "Enter (history)" hints))
    [ ("the tree", tree); ("an open file", file) ]

let test_code_asks_the_language_server_three_questions () =
  (* K hover, D definition, R references -- one family, one case each, and
     uppercase throughout so the surface's lowercase keys stay its own. The
     route behind them refused [references] until it was opened; the key
     table is where an operator finds out it is there. *)
  let keys = surface_keys Code in
  List.iter
    (fun key ->
       check Alcotest.bool ("Code asks " ^ key) true (List.mem key keys))
    [ "K"; "D"; "R" ]

let test_code_separates_blame_from_the_definition_walk () =
  (* [b] and [B] sit next to each other on one surface and mean unrelated
     things: the margin naming who last touched each run, and the walk back
     through definition jumps. The surface already pairs [d] diff with [D]
     definition the same way, so the hazard is the pair being read as one
     binding -- both spellings stay listed, and separately.

     This pins the declaration, not the dispatch: the ordered match lives
     inside the event loop where no test reaches it. *)
  let keys = surface_keys Code in
  check Alcotest.bool "blame is listed" true (List.mem "b" keys);
  check Alcotest.bool "the definition walk kept its own key" true
    (List.mem "B" keys);
  let labelled key =
    List.find_map
      (fun (binding : Masc_tui_keys.binding) ->
         if String.equal binding.Masc_tui_keys.key key then
           Some binding.Masc_tui_keys.label
         else None)
      (Masc_tui_keys.for_surface Code)
  in
  check (Alcotest.option str) "b reads as blame" (Some "blame") (labelled "b");
  check (Alcotest.option str) "B reads as back" (Some "back") (labelled "B")

let test_a_searchable_surface_does_not_also_bind_n () =
  (* [n] / [N] step the last row search on every surface that does not bind
     the key itself, and [search_last] outlives the surface it was typed on.
     A surface that both answers the row search and binds [n] therefore loses
     that key for the rest of the session. Harness did: its overrule now
     spells [x], the way Verification spells its own rejection, and since
     #36652 that [x] rides inside the pinned pair [y / x].

     Read over the same list the declaration test uses, so the two cannot
     disagree about which surfaces the row search reaches. *)
  List.iter
    (fun (label, surface) ->
       check Alcotest.bool (label ^ " leaves n to the search step") false
         (List.mem "n" (surface_keys surface)))
    surfaces_that_answer_the_row_search;
  (* Read the atoms, not the whole key: #36652 put the overrule inside the
     pinned pair ([y / x]) so a narrow verdict pane cannot drop the keys that
     answer a ruling. What this asserts is unchanged -- this surface's
     rejection is [x], not [n].

     The [n] check above stays whole on purpose. [n / N] *is* the row search,
     so a surface carrying that item is fine; what would cost the session is
     binding a bare [n] to something else. *)
  check Alcotest.bool "Harness overrules with x" true
    (List.exists
       (fun key ->
         List.mem "x" (List.map String.trim (String.split_on_char '/' key)))
       (surface_keys Harness))

let test_detail_tab_keys_reach_the_help_sheet () =
  let sheet = Masc_tui_keys.help_sections ~current:(Keepers Keeper_detail) () in
  let detail_keys =
    List.concat_map
      (fun (title, keys) ->
         if has_substring title "Keeper detail" then List.map fst keys else [])
      sheet
  in
  List.iter
    (fun (binding : Masc_tui_keys.binding) ->
       Alcotest.(check bool)
         (binding.Masc_tui_keys.key ^ " is documented in the sheet")
         true
         (List.exists (String.equal binding.Masc_tui_keys.key) detail_keys))
    (List.concat_map Masc_tui_keys.keeper_detail_tab_bindings keeper_detail_tabs)

let () =
  Alcotest.run "masc_tui_keys"
    [ ( "table"
      , [ Alcotest.test_case "detail tab bindings cover the live keys" `Quick
            test_detail_tab_bindings_cover_the_live_keys
        ; Alcotest.test_case "board compose footers are projected" `Quick
            test_board_compose_footers_are_projected
        ; Alcotest.test_case "key atoms read the table notation" `Quick
            test_key_atoms_read_the_table_notation
        ; Alcotest.test_case "detail tab strip projects the table" `Quick
            test_detail_tab_hint_projects_the_table
        ; Alcotest.test_case "detail tab keys reach the help sheet" `Quick
            test_detail_tab_keys_reach_the_help_sheet
        ; Alcotest.test_case "every surface names one key that acts on the cursor"
            `Quick test_every_surface_names_one_key_that_acts_on_the_cursor
        ; Alcotest.test_case "every Enter exception names a sheet surface"
            `Quick test_every_enter_atom_exception_names_a_sheet_surface
        ; Alcotest.test_case "every surface answers" `Quick
            test_every_surface_answers
        ; Alcotest.test_case "no surface repeats a key" `Quick
            test_no_surface_repeats_a_key
        ; Alcotest.test_case "one spelling per key" `Quick
            test_one_spelling_per_key
        ; Alcotest.test_case "a key is spelled one way across every surface"
            `Quick test_a_key_is_spelled_one_way_across_every_surface
        ; Alcotest.test_case "Config declares the page keys it handles" `Quick
            test_config_declares_the_page_keys_it_handles
        ; Alcotest.test_case "chat help names the Memory cycle" `Quick
            test_chat_help_names_memory_cycle
        ; Alcotest.test_case "chat help names the voice keys" `Quick
            test_chat_help_names_the_voice_keys
        ; Alcotest.test_case "a searchable surface does not also bind n" `Quick
            test_a_searchable_surface_does_not_also_bind_n
        ; Alcotest.test_case "Code separates blame from the definition walk"
            `Quick test_code_separates_blame_from_the_definition_walk
        ; Alcotest.test_case "Code asks the language server three questions"
            `Quick test_code_asks_the_language_server_three_questions
        ; Alcotest.test_case "the Code footer names the keys of its pane"
            `Quick test_the_code_footer_names_the_keys_of_the_pane_it_draws
        ; Alcotest.test_case "an open approval keeps its answer keys" `Quick
            test_an_open_approval_keeps_its_answer_keys_at_every_width
        ; Alcotest.test_case "every searchable surface names its search"
            `Quick test_every_searchable_surface_names_its_search
        ; Alcotest.test_case "Code search counts follow immutable fetched rows"
            `Quick test_code_search_count_tracks_fetched_source
        ; Alcotest.test_case "Changes diff uses visible search rows" `Quick
            test_changes_diff_uses_visible_search_rows
        ; Alcotest.test_case "detail search counts follow the active pane"
            `Quick test_detail_search_counts_follow_the_active_pane
        ; Alcotest.test_case "Workspace Activity offers no row search"
            `Quick test_workspace_activity_offers_no_row_search
        ; Alcotest.test_case "a surface without rows offers no row search"
            `Quick test_a_surface_without_rows_offers_no_row_search
        ] )
    ; ( "two-press arms"
      , [ Alcotest.test_case "a loop turn without input keeps an arm" `Quick
            test_a_loop_turn_without_input_keeps_an_arm
        ; Alcotest.test_case "input that is not the second press cancels"
            `Quick test_input_that_is_not_the_second_press_cancels
        ] )
    ; ( "projections"
      , [ Alcotest.test_case "plain listing footer shape" `Quick
            test_plain_listing_footer_shape
        ; Alcotest.test_case "System logs browser footer" `Quick
            test_system_logs_footer_names_browser_controls
        ; Alcotest.test_case "Tools carries the Keeper axis" `Quick
            test_tools_footer_carries_the_keeper_axis
        ; Alcotest.test_case "Resources steps through detail" `Quick
            test_resources_footer_steps_through_detail
        ; Alcotest.test_case "Lanes opens standalone runs" `Quick
            test_lanes_footer_opens_standalone_runs
        ; Alcotest.test_case "Lanes reserves standalone matrix rows" `Quick
            test_lanes_scroll_reserves_standalone_matrix_rows
        ; Alcotest.test_case "Harness links to Overview task" `Quick
            test_harness_footer_links_to_overview_task
        ; Alcotest.test_case "Schedules names write and read controls" `Quick
            test_schedules_footer_names_write_and_read_controls
        ; Alcotest.test_case "schedule create form names required fields" `Quick
            test_schedule_create_form_names_the_canonical_required_fields
        ; Alcotest.test_case
            "modify refuses exactly the statuses the store refuses" `Quick
            test_modify_refuses_exactly_the_statuses_the_store_refuses
        ; Alcotest.test_case "modify refusal is the shared predicate" `Quick
            test_modify_refusal_is_the_shared_predicate
        ; Alcotest.test_case "modify names the status it refuses" `Quick
            test_modify_names_the_status_it_refuses
        ; Alcotest.test_case
            "modify leaves an unnamed status to the server" `Quick
            test_modify_leaves_an_unnamed_status_to_the_server
        ; Alcotest.test_case "schedule update form preserves definition" `Quick
            test_schedule_update_form_preserves_exact_editable_definition
        ; Alcotest.test_case "Repositories offers Code and Git changes" `Quick
            test_repositories_footer_offers_code_and_git_changes
        ; Alcotest.test_case "Memory offers the fact browser" `Quick
            test_memory_footer_offers_the_fact_browser
        ; Alcotest.test_case "Memory facts footer names filter and back"
            `Quick test_memory_facts_footer_names_filter_and_way_back
        ; Alcotest.test_case "Memory fact rows follow the category filter"
            `Quick test_memory_fact_rows_follow_the_category_filter
        ; Alcotest.test_case "Memory category cycle returns to All" `Quick
            test_memory_category_cycle_returns_to_all
        ; Alcotest.test_case "Git changes has changed-file actions only" `Quick
            test_git_changes_footer_names_only_changed_file_actions
        ; Alcotest.test_case "Git diff has diff navigation and jump actions" `Quick
            test_git_diff_footer_names_scroll_code_and_files
        ; Alcotest.test_case "Verification carries the verdict keys" `Quick
            test_verification_footer_carries_the_verdict_keys
        ; Alcotest.test_case "Verification pins the way to answer" `Quick
            test_the_verdict_pair_is_pinned_by_the_spelling_the_table_uses
        ; Alcotest.test_case "Fusion pins the shared list projection" `Quick
            test_fusion_footer_pins_the_shared_list_projection
        ; Alcotest.test_case "fusion detail footer names the caller and board keys" `Quick
            test_fusion_detail_footer_names_the_caller_and_board_keys
        ; Alcotest.test_case "Fusion history is selectable without a retained run" `Quick
            test_fusion_historical_evidence_is_a_selectable_board_reference
        ; Alcotest.test_case "Board read footer carries the post keys" `Quick
            test_board_read_footer_carries_the_post_keys
        ; Alcotest.test_case "Keeper Runs clamps selection after list changes" `Quick
            test_keeper_runs_selection_survives_a_shorter_list
        ; Alcotest.test_case "Lanes run list names the drill-down" `Quick
            test_lanes_run_list_footer_names_the_drill_down
        ; Alcotest.test_case "Lanes run detail appends the scroll position" `Quick
            test_lanes_run_detail_footer_appends_the_scroll_position
        ; Alcotest.test_case "Overview footer projects by focus" `Quick
            test_overview_footer_projects_by_focus
        ; Alcotest.test_case "System logs owns only real filter keys" `Quick
            test_system_logs_owns_only_its_real_filter_keys
        ; Alcotest.test_case "every detail surface steps through its list"
            `Quick test_every_detail_surface_steps_through_its_list
        ; Alcotest.test_case "Planning carries filter and sort" `Quick
            test_planning_footer_carries_filter_and_sort
        ; Alcotest.test_case "Board names both hearth directions and chooser"
            `Quick test_board_footer_names_reversible_hearth_navigation
        ; Alcotest.test_case "Board and Planning explain order" `Quick
            test_board_and_planning_explain_their_order
        ; Alcotest.test_case "every view has a ring stop" `Quick
            test_every_view_has_a_ring_stop
        ; Alcotest.test_case "Task Review is a Planning child" `Quick
            test_task_review_is_a_planning_child
        ; Alcotest.test_case "Verdicts is a Planning child" `Quick
            test_verdicts_is_a_planning_child
        ; Alcotest.test_case "Changes is a Keepers child" `Quick
            test_changes_is_a_keeper_child
        ; Alcotest.test_case "Keeper operations are detail tabs" `Quick
            test_keeper_operations_are_not_top_level_tabs
        ; Alcotest.test_case "the memory marks are in the sheet" `Quick
            test_the_memory_marks_are_in_the_sheet_not_on_the_roster
        ; Alcotest.test_case "the Config marks are in the sheet" `Quick
            test_the_config_marks_are_in_the_sheet
        ; Alcotest.test_case "no surface gives one answer two rows" `Quick
            test_no_surface_gives_one_answer_two_rows
        ; Alcotest.test_case "every Config pane answers once" `Quick
            test_every_config_pane_answers_once
        ; Alcotest.test_case "the file marks are in the sheet" `Quick
            test_the_file_marks_are_in_the_sheet
        ; Alcotest.test_case "Lanes is a main destination" `Quick
            test_lanes_is_a_main_destination
        ; Alcotest.test_case "Code is a Workspace child" `Quick
            test_code_is_a_workspace_child
        ; Alcotest.test_case "Resources is a Config child" `Quick
            test_resources_is_a_config_child
        ; Alcotest.test_case "Tools is a Config child" `Quick
            test_tools_is_a_config_child
        ; Alcotest.test_case "the sheet names every keeper mark" `Quick
            test_the_sheet_names_every_keeper_mark
        ; Alcotest.test_case "the sheet explains the keeper columns" `Quick
            test_the_sheet_explains_the_keeper_columns
        ; Alcotest.test_case "the sheet explains the chat marks" `Quick
            test_the_sheet_explains_the_chat_marks
        ; Alcotest.test_case "the sheet says the listing tail once" `Quick
            test_the_sheet_says_the_listing_tail_once
        ; Alcotest.test_case "Config names child hops" `Quick
            test_config_footer_names_child_hops
        ; Alcotest.test_case "Runtime footer is the table's" `Quick
            test_runtime_footer_is_the_tables
        ; Alcotest.test_case "Config footer follows active pane and width" `Quick
            test_config_pane_footer_actions
        ; Alcotest.test_case "the keeper-voice screen names its two axes" `Quick
            test_the_keeper_voice_screen_names_its_two_axes
        ; Alcotest.test_case "the voice pane offers the keeper-voice key" `Quick
            test_the_voice_pane_offers_the_keeper_voice_key
        ; Alcotest.test_case "Activity filter survives evidence hint" `Quick
            test_activity_footer_keeps_filter_before_evidence
        ; Alcotest.test_case "Logs is an Activity child" `Quick
            test_logs_is_an_activity_child
        ; Alcotest.test_case "Metrics is an Overview child" `Quick
            test_metrics_is_an_overview_child
        ; Alcotest.test_case "Browser reader belongs to Config" `Quick
            test_browser_lanes_highlight_config
        ; Alcotest.test_case "smart declutter hides empty approvals" `Quick
            test_visible_surface_ring_declutter
        ; Alcotest.test_case "open ask keeps approvals in the ring" `Quick
            test_visible_surface_ring_open_ask
        ; Alcotest.test_case "the question count counts questions" `Quick
            test_the_question_count_counts_questions
        ; Alcotest.test_case "braille sparkline renders levels" `Quick
            test_braille_sparkline
        ; Alcotest.test_case "fleet total cost sums correctly" `Quick
            test_fleet_total_cost
        ; Alcotest.test_case "help documents what was missing" `Quick
            test_help_documents_what_was_missing
        ; Alcotest.test_case "the sheet files the fact detail keys" `Quick
            test_the_sheet_carries_the_fact_detail_keys
        ; Alcotest.test_case "Keeper detail reserves u for channel unbind"
            `Quick test_keeper_detail_reserves_lowercase_u_for_channel_unbind
        ; Alcotest.test_case "Keepers jump shares dispatch and help" `Quick
            test_keepers_jump_uses_one_binding_for_dispatch_and_help
        ; Alcotest.test_case "the sheet opens on the current surface" `Quick
            test_the_sheet_opens_on_the_current_surface
        ; Alcotest.test_case "keeper sub-modes do not share a section" `Quick
            test_the_keeper_sub_modes_do_not_share_a_section
        ; Alcotest.test_case "without a surface the order is the strip's" `Quick
            test_without_a_surface_the_order_is_the_strips
        ] )
    ; ( "board and planning rows"
      , [ Alcotest.test_case "Board searches the post list" `Quick
            test_board_searches_the_post_list
        ; Alcotest.test_case "reading and writing keep the key closed" `Quick
            test_board_reading_and_writing_keep_the_key_closed
        ; Alcotest.test_case "no posts, nothing to search" `Quick
            test_board_without_posts_offers_nothing_to_search
        ; Alcotest.test_case "Planning searches the goals the list shows"
            `Quick test_planning_searches_the_goals_the_list_shows
        ; Alcotest.test_case "Planning searches what the filter left" `Quick
            test_planning_searches_what_the_filter_left
        ; Alcotest.test_case "a goal detail keeps the key closed" `Quick
            test_planning_detail_keeps_the_key_closed
        ] )
    ; ( "lanes rows"
      , [ Alcotest.test_case "search leads with the standalone labels" `Quick
            test_lanes_search_texts_lead_with_the_standalone_labels
        ; Alcotest.test_case "sub-modes stay unsearchable" `Quick
            test_lanes_sub_modes_stay_unsearchable
        ; Alcotest.test_case "Resources searches the names it draws" `Quick
            test_resources_searches_the_names_the_list_draws
        ; Alcotest.test_case "the resource reading offers no row search"
            `Quick test_the_resource_reading_offers_no_row_search
        ; Alcotest.test_case "Resources without a list answers nothing" `Quick
            test_resources_without_a_list_answers_nothing
        ; Alcotest.test_case "a click reads the frame rows" `Quick
            test_overview_hit_reads_the_frame_rows
        ; Alcotest.test_case "a click pays for the error rows" `Quick
            test_overview_hit_pays_for_the_error_rows
        ; Alcotest.test_case "a click waits for the matrix" `Quick
            test_overview_hit_waits_for_the_matrix
        ] )
    ]
