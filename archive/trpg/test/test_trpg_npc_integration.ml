open Masc_mcp

let get_ok = function
  | Ok x -> x
  | Error e -> Alcotest.fail e

let make_base_dir () =
  let pid = Unix.getpid () in
  let r = Random.int 1_000_000 in
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-trpg-npc-integ-%d-%d" pid r)

(** Build a minimal JSON state with a party.
    [party] is an assoc list of (actor_id, actor_json) pairs. *)
let make_state ?(turn = 1) ?(phase = "round") (party : (string * Yojson.Safe.t) list) :
    Yojson.Safe.t =
  `Assoc
    [
      ("turn", `Int turn);
      ("phase", `String phase);
      ("party", `Assoc party);
    ]

let make_player_actor ?(hp = 20) ?(alive = true) name =
  `Assoc
    [
      ("name", `String name);
      ("role", `String "player");
      ("hp", `Int hp);
      ("max_hp", `Int hp);
      ("alive", `Bool alive);
    ]

let make_npc_actor ?(hp = 15) ?(alive = true) name =
  `Assoc
    [
      ("name", `String name);
      ("role", `String "npc");
      ("hp", `Int hp);
      ("max_hp", `Int hp);
      ("alive", `Bool alive);
    ]

(* ================================================================ *)
(* Group 1: NPC Spawn Pipeline                                      *)
(* ================================================================ *)

let test_npc_spawns_when_no_npc_alive () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-spawn-1" in
  let state =
    make_state
      [ ("player-1", make_player_actor "Hero"); ("player-2", make_player_actor "Mage") ]
  in
  let result =
    Tool_trpg.ensure_round_npc_spawn_event ~store ~room_id ~turn:1 ~state
  in
  match get_ok result with
  | None -> Alcotest.fail "expected an NPC spawn event, got None"
  | Some (event : Trpg.Engine_event.t) ->
      Alcotest.(check string)
        "event_type is actor.spawned"
        "actor.spawned"
        (Trpg.Engine_event.string_of_event_type event.event_type);
      (* Verify spawned actor has positive HP *)
      let open Yojson.Safe.Util in
      let actor = event.payload |> member "actor" in
      let hp = actor |> member "hp" |> to_int in
      Alcotest.(check bool) "spawned NPC has positive HP" true (hp > 0);
      let role = actor |> member "role" |> to_string in
      Alcotest.(check string) "spawned actor role is npc" "npc" role;
      let alive = actor |> member "alive" |> to_bool in
      Alcotest.(check bool) "spawned NPC is alive" true alive

let test_npc_not_spawned_when_npc_alive () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-spawn-2" in
  let tmpl = Tool_trpg.npc_bestiary.(0) in
  let state =
    make_state
      [
        ("player-1", make_player_actor "Hero");
        ("npc-t1-01", make_npc_actor tmpl.npc_name);
      ]
  in
  let result =
    Tool_trpg.ensure_round_npc_spawn_event ~store ~room_id ~turn:1 ~state
  in
  match get_ok result with
  | None -> () (* correct: no spawn when live NPC exists *)
  | Some _ -> Alcotest.fail "should not spawn when a live NPC already exists"

let test_spawned_npc_has_scaled_hp () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-spawn-3" in
  let turn = 10 in
  let state =
    make_state ~turn
      [ ("player-1", make_player_actor "Hero") ]
  in
  let result =
    Tool_trpg.ensure_round_npc_spawn_event ~store ~room_id ~turn ~state
  in
  match get_ok result with
  | None -> Alcotest.fail "expected spawn at turn 10"
  | Some (event : Trpg.Engine_event.t) ->
      let open Yojson.Safe.Util in
      let actor = event.payload |> member "actor" in
      let hp = actor |> member "hp" |> to_int in
      (* At turn 10 (mid tier), HP = base_hp + base_hp/2 = 1.5x.
         The template selected at turn 10 determines exact base_hp.
         We verify the scaling property: hp > base_hp of the template. *)
      let tmpl = Tool_trpg.select_npc_template ~turn in
      let expected_hp = Tool_trpg.scale_hp ~turn ~base_hp:tmpl.base_hp in
      Alcotest.(check int)
        "HP matches scale_hp for mid tier"
        expected_hp hp;
      (* Mid-tier scaling: hp should be strictly greater than base *)
      Alcotest.(check bool)
        "mid-tier HP > base HP" true (hp > tmpl.base_hp)

(* ================================================================ *)
(* Group 2: Counterattack Pipeline                                  *)
(* ================================================================ *)

let test_counterattack_produces_attack_and_hp_events () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-counter-1" in
  let tmpl = Tool_trpg.npc_bestiary.(0) in
  (* Use odd turn to avoid skill effects for a skirmisher (NoSkill on odd turns) *)
  let state =
    make_state
      [
        ("player-1", make_player_actor "Hero");
        ("npc-t1-01", make_npc_actor tmpl.npc_name);
      ]
  in
  let result =
    Tool_trpg.append_npc_counterattack_events ~store ~room_id ~phase:"round"
      ~turn:1 ~state
  in
  let events = get_ok result in
  (* At minimum, counterattack produces a combat.attack and hp.changed pair.
     Skill effects may add extra events (e.g. SelfHeal prepends, MultiTarget appends). *)
  Alcotest.(check bool) "at least 2 events" true (List.length events >= 2);
  (* Find the combat.attack and hp.changed events *)
  let has_attack =
    List.exists
      (fun (e : Trpg.Engine_event.t) -> e.event_type = Trpg.Engine_event.Combat_attack)
      events
  in
  let has_hp_changed =
    List.exists
      (fun (e : Trpg.Engine_event.t) -> e.event_type = Trpg.Engine_event.Hp_changed)
      events
  in
  Alcotest.(check bool) "has combat.attack event" true has_attack;
  Alcotest.(check bool) "has hp.changed event" true has_hp_changed

let test_counterattack_damage_uses_template_range () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-counter-2" in
  let tmpl = Tool_trpg.npc_bestiary.(0) in
  let state =
    make_state
      [
        ("player-1", make_player_actor "Hero");
        ("npc-t1-01", make_npc_actor tmpl.npc_name);
      ]
  in
  (* Run across multiple turns to exercise various hash values.
     Skill effects (BonusDamage, DoubleDamage) can modify the final damage
     beyond the template's raw range. We compute the max possible damage
     by resolving the skill for each turn. *)
  for turn = 1 to 20 do
    let result =
      Tool_trpg.append_npc_counterattack_events ~store ~room_id ~phase:"round"
        ~turn ~state
    in
    let events = get_ok result in
    (* Find the combat.attack event *)
    let attack_opt =
      List.find_opt
        (fun (e : Trpg.Engine_event.t) ->
          e.event_type = Trpg.Engine_event.Combat_attack)
        events
    in
    match attack_opt with
    | Some attack_event ->
        let open Yojson.Safe.Util in
        let damage = attack_event.payload |> member "damage" |> to_int in
        (* Compute skill-adjusted bounds *)
        let skill = Tool_trpg.resolve_npc_skill ~turn ~npc_template:tmpl in
        let adjust_min base = match skill with
          | Tool_trpg.BonusDamage n -> base + n
          | Tool_trpg.DoubleDamage -> base * 2
          | _ -> base
        in
        let adjust_max base = match skill with
          | Tool_trpg.BonusDamage n -> base + n
          | Tool_trpg.DoubleDamage -> base * 2
          | _ -> base
        in
        let eff_min = adjust_min tmpl.damage_min in
        let eff_max = adjust_max tmpl.damage_max in
        Alcotest.(check bool)
          (Printf.sprintf "turn %d damage >= effective min (%d)" turn eff_min)
          true (damage >= eff_min);
        Alcotest.(check bool)
          (Printf.sprintf "turn %d damage <= effective max (%d)" turn eff_max)
          true (damage <= eff_max)
    | None ->
        Alcotest.failf "turn %d: no combat.attack event found" turn
  done

let test_counterattack_narration_from_template () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-counter-3" in
  let tmpl = Tool_trpg.npc_bestiary.(0) in
  let state =
    make_state
      [
        ("player-1", make_player_actor "Hero");
        ("npc-t1-01", make_npc_actor tmpl.npc_name);
      ]
  in
  (* Use odd turn to get NoSkill for a skirmisher, so narration has no prefix *)
  let result =
    Tool_trpg.append_npc_counterattack_events ~store ~room_id ~phase:"round"
      ~turn:1 ~state
  in
  let events = get_ok result in
  let attack_opt =
    List.find_opt
      (fun (e : Trpg.Engine_event.t) -> e.event_type = Trpg.Engine_event.Combat_attack)
      events
  in
  match attack_opt with
  | Some attack_event ->
      let open Yojson.Safe.Util in
      let narration = attack_event.payload |> member "action" |> to_string in
      (* When a skill is active, narration gets a "[SkillName] " prefix.
         We check that the narration contains one of the template's narrations. *)
      let contains_known =
        List.exists
          (fun known -> String.length narration >= String.length known
                        && (narration = known
                            || (String.length narration > String.length known
                                && String.sub narration
                                     (String.length narration - String.length known)
                                     (String.length known) = known)))
          tmpl.attack_narrations
      in
      Alcotest.(check bool)
        "narration contains a template attack_narration"
        true contains_known
  | None ->
      Alcotest.fail "expected counterattack attack event but got none"

(* ================================================================ *)
(* Group 3: Full Round Integration                                  *)
(* ================================================================ *)

let test_full_round_spawn_and_counterattack () =
  let base_dir = make_base_dir () in
  let store = Trpg.Store.make_sqlite ~base_dir in
  let room_id = "room-full-1" in
  let turn = 3 in

  (* Step 1: Start with players only, no NPC *)
  let state =
    make_state ~turn
      [
        ("player-1", make_player_actor "Hero");
        ("player-2", make_player_actor "Mage");
      ]
  in

  (* Step 2: NPC spawn *)
  let spawn_result =
    Tool_trpg.ensure_round_npc_spawn_event ~store ~room_id ~turn ~state
  in
  let spawn_event =
    match get_ok spawn_result with
    | Some ev -> ev
    | None -> Alcotest.failf "expected NPC spawn at turn %d" turn
  in
  Alcotest.(check string)
    "spawn event type"
    "actor.spawned"
    (Trpg.Engine_event.string_of_event_type spawn_event.event_type);

  (* Step 3: Build updated state with spawned NPC *)
  let open Yojson.Safe.Util in
  let npc_actor_id = spawn_event.payload |> member "actor_id" |> to_string in
  let npc_actor_json = spawn_event.payload |> member "actor" in
  let npc_name = npc_actor_json |> member "name" |> to_string in
  let state_with_npc =
    make_state ~turn
      [
        ("player-1", make_player_actor "Hero");
        ("player-2", make_player_actor "Mage");
        (npc_actor_id, npc_actor_json);
      ]
  in

  (* Step 4: NPC counterattack *)
  let counter_result =
    Tool_trpg.append_npc_counterattack_events ~store ~room_id ~phase:"round"
      ~turn ~state:state_with_npc
  in
  let counter_events = get_ok counter_result in
  (* At minimum: 1 combat.attack + 1 hp.changed.
     Skill effects may add more (SelfHeal prepends, MultiTarget appends). *)
  Alcotest.(check bool) "counterattack produces >= 2 events" true
    (List.length counter_events >= 2);

  (* Step 5: Verify event types and consistency *)
  let attack_event =
    List.find
      (fun (e : Trpg.Engine_event.t) -> e.event_type = Trpg.Engine_event.Combat_attack)
      counter_events
  in
  let hp_events =
    List.filter
      (fun (e : Trpg.Engine_event.t) -> e.event_type = Trpg.Engine_event.Hp_changed)
      counter_events
  in
  Alcotest.(check bool) "at least one hp.changed event" true
    (List.length hp_events >= 1);

  (* Attack comes from the NPC *)
  let attacker_id = attack_event.payload |> member "actor_id" |> to_string in
  Alcotest.(check string) "attacker is NPC" npc_actor_id attacker_id;

  (* Find the hp.changed event targeting a player (reason = "combat.attack") *)
  let player_hp_event =
    List.find
      (fun (e : Trpg.Engine_event.t) ->
        let reason = e.payload |> member "reason" |> to_string_option in
        reason = Some "combat.attack")
      hp_events
  in

  (* HP change targets a player, not the NPC *)
  let hp_target_id = player_hp_event.payload |> member "actor_id" |> to_string in
  Alcotest.(check bool) "HP target is a player, not the NPC" true
    (hp_target_id <> npc_actor_id);

  (* Damage is negative (delta < 0) *)
  let delta = player_hp_event.payload |> member "delta" |> to_int in
  Alcotest.(check bool) "HP delta is negative" true (delta < 0);

  (* Source of HP change is the NPC *)
  let source_id = player_hp_event.payload |> member "source_actor_id" |> to_string in
  Alcotest.(check string) "HP source is the NPC" npc_actor_id source_id;

  (* Step 6: Verify all events are in the store *)
  let stored_events =
    get_ok (Trpg.Engine_store_sqlite.read_events ~base_dir ~room_id)
  in
  (* At minimum: spawn (1) + attack (1) + hp_changed (1) = 3.
     Skill effects may add more events. *)
  Alcotest.(check bool) "at least 3 events in store" true
    (List.length stored_events >= 3);

  (* Verify seq ordering *)
  let seqs = List.map (fun (e : Trpg.Engine_event.t) -> e.seq) stored_events in
  let sorted = List.sort compare seqs in
  Alcotest.(check (list int)) "seqs are ascending" sorted seqs;

  (* Verify the NPC name matches a bestiary template *)
  (match Tool_trpg.find_npc_template_by_name npc_name with
  | Some _ -> ()
  | None -> Alcotest.failf "spawned NPC name '%s' not found in bestiary" npc_name)

(* ================================================================ *)
(* Test runner                                                      *)
(* ================================================================ *)

let () =
  Alcotest.run "TRPG NPC Integration"
    [
      ( "npc_spawn_pipeline",
        [
          Alcotest.test_case "spawns when no NPC alive" `Quick
            test_npc_spawns_when_no_npc_alive;
          Alcotest.test_case "no spawn when NPC alive" `Quick
            test_npc_not_spawned_when_npc_alive;
          Alcotest.test_case "scaled HP at mid tier" `Quick
            test_spawned_npc_has_scaled_hp;
        ] );
      ( "counterattack_pipeline",
        [
          Alcotest.test_case "produces two events" `Quick
            test_counterattack_produces_attack_and_hp_events;
          Alcotest.test_case "damage within template range" `Quick
            test_counterattack_damage_uses_template_range;
          Alcotest.test_case "narration from template" `Quick
            test_counterattack_narration_from_template;
        ] );
      ( "full_round_integration",
        [
          Alcotest.test_case "spawn then counterattack pipeline" `Quick
            test_full_round_spawn_and_counterattack;
        ] );
    ]
