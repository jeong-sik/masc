(** The [masc keeper-create] flag surface and its reading of one [/up]
    response. Everything asserted here is pure, so no server runs and no
    keeper is created.

    The regression each case holds is named in its own comment. The one they
    share: a keeper was created through [masc_keeper_up] for web search and
    board posting, and it landed with [network_mode = "none"] because the tool
    could not carry the field and its default blocks the guest's network. The
    operator edited the keeper TOML by hand afterwards. *)

open Alcotest

module C = Masc_cli_keeper_create

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1))
  in
  scan 0
;;

let no_booleans : C.booleans = { autoboot = None; proactive = None }

let minimal_flags : C.flags =
  { name = "scout"
  ; instructions = "Search the web."
  ; sandbox_profile = "docker"
  ; network_mode = Some "inherit"
  ; remote_endpoint = None
  ; mention_targets = []
  ; skills = None
  ; max_context_override = None
  ; booleans = no_booleans
  }
;;

let every_flag : C.flags =
  { name = "scout"
  ; instructions = "Search the web."
  ; sandbox_profile = "remote_ssh"
  ; network_mode = Some "inherit"
  ; remote_endpoint = Some "gondolin"
  ; mention_targets = [ "scout" ]
  ; skills = Some [ "web-search" ]
  ; max_context_override = Some 120_000
  ; booleans = { autoboot = Some true; proactive = Some false }
  }
;;

let declaration_exn label flags =
  match C.declaration_of_flags flags with
  | Ok declaration -> declaration
  | Error message -> failf "%s: expected a declaration, got %S" label message
;;

let object_keys label json =
  match json with
  | `Assoc fields -> List.map fst fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    failf "%s: expected a JSON object" label
;;

let field label key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    failf "%s: expected a JSON object" label
;;

(* The original defect at the new surface: a declaration that leaves
   [network_mode] unsaid takes the server's default, which is [none] for both
   docker and microvm, and a keeper whose work is web search is created unable
   to do it. Refused before a socket opens, so no declaration exists to
   inspect. *)
let test_declaration_refuses_a_missing_network_mode () =
  match C.declaration_of_flags { minimal_flags with network_mode = None } with
  | Ok declaration ->
    failf
      "expected a refusal, got the declaration %s"
      (Yojson.Safe.to_string declaration)
  | Error message ->
    List.iter
      (fun spelling ->
         check
           bool
           (Printf.sprintf "the refusal names %s" spelling)
           true
           (contains spelling message))
      Keeper_types_profile_sandbox.valid_network_mode_strings;
    (* One behaviour line per mode, rendered from the typed owner. The
       behaviour lines are the indented ones; the requirement sentence above
       them and the "Nothing was created." below are not. A mode the owner
       gains with no line for it is what this pins. *)
    let behaviour_lines =
      List.filter
        (fun line -> String.length line > 2 && String.equal (String.sub line 0 2) "  ")
        (String.split_on_char '\n' message)
    in
    check
      int
      "one behaviour line per network mode"
      (List.length Keeper_types_profile_sandbox.all_network_modes)
      (List.length behaviour_lines);
    List.iter
      (fun (spelling, behaviour) ->
         check
           bool
           (Printf.sprintf "the %s line says what the mode does" spelling)
           true
           (List.exists
              (fun line -> contains spelling line && contains behaviour line)
              behaviour_lines))
      C.network_mode_behaviours
;;

(* The spellings the manpage and the refusal render are the typed owner's,
   in its order: a mode the owner gains reaches both surfaces without an
   edit here. *)
let test_behaviours_cover_every_network_mode () =
  check
    (list string)
    "network_mode_behaviours spellings"
    Keeper_types_profile_sandbox.valid_network_mode_strings
    (List.map fst C.network_mode_behaviours)
;;

(* A flag the server would reject as [turn_up_arg_unknown]. That drift is what
   put the descriptor and the parser out of step in the first place, so it is
   caught here rather than by an operator. *)
let test_declaration_keys_are_all_known_turn_up_args () =
  let keys = object_keys "every flag" (declaration_exn "every flag" every_flag) in
  List.iter
    (fun key ->
       check
         bool
         (Printf.sprintf "%s is a known keeper_up argument" key)
         true
         (List.exists
            (String.equal key)
            Masc.Keeper_turn_up_args.known_turn_up_args))
    keys
;;

(* The parity claim, made enforceable: nothing the editor form can say is out
   of reach of the flags. The form's own fields are the floor, because a field
   [parse] starts requiring lands in the stem first. *)
let test_every_creation_stem_field_is_reachable_by_flag () =
  let stem_keys =
    object_keys "the stem" (Yojson.Safe.from_string C.form_stem)
  in
  let flag_keys = object_keys "every flag" (declaration_exn "every flag" every_flag) in
  List.iter
    (fun key ->
       check
         bool
         (Printf.sprintf "%s is reachable by flag" key)
         true
         (List.exists (String.equal key) flag_keys))
    stem_keys
;;

(* A two-valued flag would settle [autoboot_enabled] by default, and the
   config writer persists whatever the meta holds — so an operator who named
   neither spelling would find a decision written for them. *)
let test_declaration_omits_unset_booleans () =
  let keys = object_keys "minimal" (declaration_exn "minimal" minimal_flags) in
  List.iter
    (fun key ->
       check
         bool
         (Printf.sprintf "%s is absent when neither flag was passed" key)
         false
         (List.exists (String.equal key) keys))
    [ "autoboot_enabled"; "proactive_enabled" ]
;;

(* A second copy of the profile enum in this command is how the descriptor and
   [known_turn_up_args] drifted apart. The spelling is the server's to judge. *)
let test_declaration_passes_an_unrecognised_sandbox_profile_through () =
  let declaration =
    declaration_exn "vm" { minimal_flags with sandbox_profile = "vm" }
  in
  check
    (option string)
    "the unrecognised profile reaches the declaration unchanged"
    (Some "vm")
    (match field "vm" "sandbox_profile" declaration with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
;;

(* Built by the producer, not by hand. The create-or-reconfigure reading below
   probes two untagged keys of this envelope, and a hand-written copy would go
   on passing after [create_response_json] renamed or dropped one -- at which
   point a fresh create prints the sentence saying a keeper of that name
   already existed, exits 0, and reports nothing wrong. *)
let created_body =
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool true
        ; "action", `String "up"
        ; "name", `String "scout"
        ; ( "detail"
          , Masc.Keeper_turn_up_create.create_response_json
              ~name:"scout"
              ~trace_id:"trace-fixture"
              ~instructions:"Search the web."
              ~proactive_enabled:false
              ~max_context_override:None
              ~sandbox_profile:Keeper_types_profile_sandbox.Docker
              ~network_mode:Keeper_types_profile_sandbox.Network_inherit
              ~agent_core_env:[] )
        ])
;;

(* Printing an isolation this command did not read is reporting an unmeasured
   value. Only the create branch answers with the pair: the update branch
   returns the keeper meta, which carries neither because both are TOML-owned,
   and that answer is a reconfiguration rather than a create. *)
let test_outcome_reads_the_landed_isolation () =
  (match C.outcome_of_response ~status:200 ~body:created_body with
   | C.Created { name; sandbox_profile; network_mode } ->
     check string "the created keeper's name" "scout" name;
     check string "the landed sandbox profile" "docker" sandbox_profile;
     check string "the landed network mode" "inherit" network_mode
   | C.Reconfigured _ | C.Revision_conflict | C.Unauthorized _ | C.Refused _
   | C.Unreachable _ -> failf "expected a create outcome from the create envelope");
  match
    C.outcome_of_response
      ~status:200
      ~body:{json|{"ok":true,"action":"up","name":"scout","detail":{"name":"scout"}}|json}
  with
  | C.Reconfigured { name } ->
    check string "the reconfigured keeper's name" "scout" name
  | C.Created _ | C.Revision_conflict | C.Unauthorized _ | C.Refused _
  | C.Unreachable _ ->
    failf "an answer without the isolation pair is a reconfiguration, not a create"
;;

(* Matched on the exported constant. Matching the sentence around it is how a
   string classifier starts, and this rejection is the one the tool's own
   contract says is safe to re-run. *)
let test_revision_conflict_is_matched_on_the_exported_code () =
  let body code =
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; "error", `String "keeper manifest changed under this call"
         ; "detail", `Assoc [ "code", `String code ]
         ])
  in
  (match
     C.outcome_of_response
       ~status:400
       ~body:(body Masc.Keeper_turn_up_update.config_revision_conflict_code)
   with
   | C.Revision_conflict -> ()
   | C.Created _ | C.Reconfigured _ | C.Unauthorized _ | C.Refused _
   | C.Unreachable _ -> failf "the exported conflict code must classify as a conflict");
  match C.outcome_of_response ~status:400 ~body:(body "keeper_sandbox_unreachable") with
  | C.Refused _ -> ()
  | C.Created _ | C.Reconfigured _ | C.Revision_conflict | C.Unauthorized _
  | C.Unreachable _ -> failf "another code must not classify as a conflict"
;;

(* A [--edit] that blocks in a pipe, a CI step or a subagent. The refusal
   names the flags that carry the same declaration without an editor. *)
let test_edit_without_a_terminal_is_refused () =
  (match C.form_input_refusal ~stdin_is_tty:false ~editor:(Some "vi") with
   | None -> failf "an --edit without a terminal must be refused"
   | Some _ -> ());
  (match C.form_input_refusal ~stdin_is_tty:true ~editor:None with
   | None -> failf "an --edit without $EDITOR must be refused"
   | Some _ -> ());
  check
    bool
    "a terminal and an editor together are not refused"
    true
    (Option.is_none (C.form_input_refusal ~stdin_is_tty:true ~editor:(Some "vi")))
;;

(* The exit codes are read by scripts, so they are pinned rather than left to
   whichever branch happened to run. *)
let test_render_pairs_text_with_an_exit_code () =
  let code outcome = snd (C.render outcome) in
  check
    int
    "a create exits zero"
    0
    (code (C.Created { name = "scout"; sandbox_profile = "docker"; network_mode = "inherit" }));
  check int "a reconfiguration exits zero" 0 (code (C.Reconfigured { name = "scout" }));
  check int "a revision conflict exits four" 4 (code C.Revision_conflict);
  check int "a refusal exits one" 1 (code (C.Refused "no"));
  check int "an unauthorized call exits one" 1 (code (C.Unauthorized "no"));
  check int "an unreachable server exits one" 1 (code (C.Unreachable "no"))
;;

(* A form with no name has nothing to address the route with, and the route
   puts the name in the path. *)
let test_form_without_a_name_is_refused () =
  match
    C.declaration_of_form
      {json|{"sandbox_profile":"docker","network_mode":"inherit"}|json}
  with
  | Ok _ -> failf "a form with no name must be refused"
  | Error _ ->
    (match
       C.declaration_of_form
         {json|{"name":"scout","sandbox_profile":"docker","network_mode":"inherit"}|json}
     with
     | Ok (_, name) -> check string "a complete form's own name" "scout" name
     | Error message -> failf "a complete form must be accepted: %S" message)
;;

(* The hole [--edit] had. The manpage says --network-mode is required and does
   not qualify it, but only the flags path judged the field: the stem ships
   the key blank so that the refusal teaches the two spellings, and an
   operator who deleted that line rather than filling it in sent a declaration
   with the key absent. The server then took the profile default of "none" --
   the original incident, reached through the command written to stop it.
   Both shapes are refused before a socket opens. *)
let test_form_without_a_network_mode_is_refused () =
  List.iter
    (fun (label, form) ->
       match C.declaration_of_form form with
       | Ok (declaration, _) ->
         failf "%s must be refused, got %s" label (Yojson.Safe.to_string declaration)
       | Error message ->
         List.iter
           (fun spelling ->
              check
                bool
                (Printf.sprintf "%s: the refusal names %s" label spelling)
                true
                (contains spelling message))
           Keeper_types_profile_sandbox.valid_network_mode_strings)
    [ ( "a form whose network_mode line was deleted"
      , {json|{"name":"scout","sandbox_profile":"docker"}|json} )
    ; "the stem itself, whose network_mode is blank", C.form_stem
    ]
;;

let () =
  run
    "masc_cli_keeper_create"
    [ ( "network_mode"
      , [ test_case
            "a missing network_mode is refused before any request"
            `Quick
            test_declaration_refuses_a_missing_network_mode
        ; test_case
            "the behaviour sentences cover every network mode"
            `Quick
            test_behaviours_cover_every_network_mode
        ] )
    ; ( "declaration"
      , [ test_case
            "every key is a known keeper_up argument"
            `Quick
            test_declaration_keys_are_all_known_turn_up_args
        ; test_case
            "every creation stem field is reachable by flag"
            `Quick
            test_every_creation_stem_field_is_reachable_by_flag
        ; test_case
            "unset booleans stay out of the declaration"
            `Quick
            test_declaration_omits_unset_booleans
        ; test_case
            "an unrecognised sandbox profile passes through"
            `Quick
            test_declaration_passes_an_unrecognised_sandbox_profile_through
        ] )
    ; ( "response"
      , [ test_case
            "the landed isolation is read, not echoed"
            `Quick
            test_outcome_reads_the_landed_isolation
        ; test_case
            "a revision conflict is matched on the exported code"
            `Quick
            test_revision_conflict_is_matched_on_the_exported_code
        ; test_case
            "each outcome pairs with its exit code"
            `Quick
            test_render_pairs_text_with_an_exit_code
        ] )
    ; ( "form"
      , [ test_case
            "an --edit without a terminal or an editor is refused"
            `Quick
            test_edit_without_a_terminal_is_refused
        ; test_case
            "a form without a name is refused"
            `Quick
            test_form_without_a_name_is_refused
        ; test_case
            "a form without a network_mode is refused"
            `Quick
            test_form_without_a_network_mode_is_refused
        ] )
    ]
;;
