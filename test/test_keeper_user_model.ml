(** Tests for Keeper_user_model projection from Memory OS facts. *)

open Alcotest

module Types = Masc.Keeper_memory_os_types
module Memory_io = Masc.Keeper_memory_os_io
module User_model = Masc.Keeper_user_model

let contains substring s =
  let sub_len = String.length substring in
  let str_len = String.length s in
  let rec loop i =
    if i + sub_len > str_len
    then false
    else if String.equal (String.sub s i sub_len) substring
    then true
    else loop (i + 1)
  in
  if sub_len = 0 then true else loop 0
;;

let with_temp_keepers_dir f =
  let dir = Filename.temp_dir "keeper-user-model-" "" in
  Memory_io.For_testing.with_keepers_dir dir (fun () -> f dir)
;;

let fact
      ?(observed_by = [])
      ?valid_until
      ?last_verified_at
      ~now
      ~category
      ~claim
      ~trace_id
      ~turn
      ()
  =
  { Types.claim
  ; category
  ; external_ref = None
  ; claim_kind = None
  ; source = { trace_id; turn; tool_call_id = None }
  ; observed_by
  ; first_seen = now -. float_of_int turn
  ; valid_until
  ; last_verified_at
  ; schema_version = Types.schema_version
  ; claim_id = None
  }
;;

let test_build_filters_user_model_categories_and_private_precedence () =
  with_temp_keepers_dir
  @@ fun _ ->
  let now = 10_000.0 in
  Memory_io.append_fact ~keeper_id:"sangsu"
    (fact
       ~now
       ~category:Types.Preference
       ~claim:"User prefers concise answers"
       ~trace_id:"trace-private-pref"
       ~turn:10
       ~last_verified_at:(now -. 10.0)
       ());
  Memory_io.append_fact ~keeper_id:"sangsu"
    (fact
       ~now
       ~category:Types.Constraint
       ~claim:"Do not recommend launchd unless the user explicitly asks"
       ~trace_id:"trace-private-constraint"
       ~turn:11
       ~last_verified_at:(now -. 20.0)
       ());
  Memory_io.append_fact ~keeper_id:"sangsu"
    (fact
       ~now
       ~category:Types.Fact
       ~claim:"This ordinary fact must not become user model context"
       ~trace_id:"trace-fact"
       ~turn:12
       ());
  Memory_io.append_fact ~keeper_id:"sangsu"
    (fact
       ~now
       ~category:Types.Preference
       ~claim:"Expired user preference"
       ~trace_id:"trace-expired"
       ~turn:13
       ~valid_until:(now -. 1.0)
       ());
  Memory_io.append_fact ~keeper_id:Types.shared_store_id
    (fact
       ~now
       ~category:Types.Preference
       ~claim:"User prefers concise answers"
       ~trace_id:"trace-shared-duplicate"
       ~turn:99
       ~observed_by:[ "rondo"; "qa-king" ]
       ~last_verified_at:(now -. 1.0)
       ());
  Memory_io.append_fact ~keeper_id:Types.shared_store_id
    (fact
       ~now
       ~category:Types.Constraint
       ~claim:"Let CI be the authority for full builds"
       ~trace_id:"trace-shared-constraint"
       ~turn:14
       ~observed_by:[ "qa-king"; "verifier" ]
       ~last_verified_at:(now -. 5.0)
       ());
  let model =
    User_model.build ~keeper_id:"sangsu" ~now ~max_preferences:5 ~max_constraints:5 ()
  in
  check int "preference count" 1 (List.length model.preferences);
  check int "constraint count" 2 (List.length model.constraints);
  (match model.preferences with
   | [ preference ] ->
     check string "private preference wins duplicate"
       "User prefers concise answers"
       preference.claim
   | _ -> fail "expected exactly one preference");
  check bool "shared constraint surfaced" true
    (List.exists
       (fun (item : User_model.item) ->
          String.equal item.claim "Let CI be the authority for full builds")
       model.constraints);
  let rendered =
    match User_model.render_prompt_block model with
    | None -> fail "expected rendered user model"
    | Some block -> block
  in
  check bool "renders header" true (contains "[USER MODEL]" rendered);
  check bool "renders preferences section" true (contains "Preferences:" rendered);
  check bool "renders memory notes section" true (contains "Memory notes:" rendered);
  check bool "renders shared provenance" true (contains "shared via qa-king,verifier" rendered);
  check bool "does not render ordinary fact" false
    (contains "ordinary fact" rendered);
  check bool "does not render expired preference" false
    (contains "Expired user preference" rendered);
  check bool "does not use shared duplicate turn" false (contains "turn=99" rendered)
;;

let test_render_empty_model_is_none () =
  let model =
    { User_model.preferences = []
    ; constraints = []
    ; source_fact_count = 0
    ; shared_fact_count = 0
    }
  in
  check bool "empty render" true (Option.is_none (User_model.render_prompt_block model))
;;

let test_render_truncates_on_utf8_boundary () =
  let claim = String.make 218 'a' ^ "한글" in
  let item : User_model.item =
    { claim
    ; category = Types.Preference
    ; source = User_model.Keeper_private
    ; turn = 1
    ; first_seen = 1.0
    ; last_verified_at = None
    }
  in
  let model =
    { User_model.preferences = [ item ]
    ; constraints = []
    ; source_fact_count = 1
    ; shared_fact_count = 0
    }
  in
  let rendered =
    match User_model.render_prompt_block model with
    | None -> fail "expected rendered user model"
    | Some block -> block
  in
  check bool "rendered prompt remains valid UTF-8" true
    (String.is_valid_utf_8 rendered);
  check bool "rendered prompt shows truncation marker" true
    (contains "..." rendered)
;;

let () =
  run
    "Keeper_user_model"
    [ ( "projection"
      , [ test_case
            "filters user model categories and preserves private precedence"
            `Quick
            test_build_filters_user_model_categories_and_private_precedence
        ; test_case "empty model renders no block" `Quick test_render_empty_model_is_none
        ; test_case
            "render truncates on UTF-8 boundary"
            `Quick
            test_render_truncates_on_utf8_boundary
        ] )
    ]
;;
