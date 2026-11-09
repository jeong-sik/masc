(* Checks for the body of an authorization scope: the bytes it writes, that it
   reads back what it wrote, the labels of every effect and channel, and every
   way a body fails to be a scope. No files, clock, or network. *)

open Authz_types
module B = Authz_scope_body

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let runtime text = get (Runtime_id.of_string text)

(* Every constructor, in declaration order. A new effect or channel needs a
   line here; [Effect.to_string] and [Channel.to_string] fail to compile until
   it has a label. *)
let every_effect =
  Effect.
    [ Read_state
    ; Invoke_model
    ; Use_tool
    ; Manage_own_provider
    ; Manage_own_runtime
    ; Manage_own_grant
    ; Manage_own_keeper
    ; Manage_machine_shared
    ; Admin_disable_block
    ; Read_audit_metadata
    ]
;;

let every_channel =
  Channel.
    [ Direct
    ; Delegate
    ; Schedule
    ; Board_trigger
    ; Retry
    ; Resume
    ; Fusion
    ; Vision
    ; Verifier
    ; Autonomous
    ]
;;

let scope ~runtimes ~channels ~allowed_effects =
  { Authorization_scope.runtimes; channels; allowed_effects }
;;

let only_runtimes texts = Runtime_scope.only (Runtime_id.Set.of_list (List.map runtime texts))
let only_channels channels = Channel_scope.only (Channel.Set.of_list channels)
let only_effects effects = Effect_scope.only (Effect.Set.of_list effects)

let some_scope =
  scope
    ~runtimes:(only_runtimes [ "r-b"; "r-a" ])
    ~channels:(only_channels [ Channel.Schedule; Channel.Direct ])
    ~allowed_effects:Effect_scope.all
;;

let empty_scope =
  scope ~runtimes:Runtime_scope.empty ~channels:Channel_scope.empty ~allowed_effects:Effect_scope.empty
;;

let scope_equal (a : Authorization_scope.t) (b : Authorization_scope.t) =
  Runtime_scope.equal a.runtimes b.runtimes
  && Channel_scope.equal a.channels b.channels
  && Effect_scope.equal a.allowed_effects b.allowed_effects
;;

let to_body_exn t =
  match B.to_body t with
  | Ok body -> body
  | Error error -> Alcotest.failf "the body was refused: %s" (Authz_body.error_to_string error)
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let error = Alcotest.testable (fun ppf e -> Format.pp_print_string ppf (B.error_to_string e)) ( = )

(* ---- labels ---- *)

let every_effect_has_a_label_that_reads_back () =
  List.iter
    (fun kind ->
       let label = Effect.to_string kind in
       Alcotest.(check bool) label true (Option.equal ( = ) (Some kind) (Effect.of_string label)))
    every_effect;
  let labels = List.map Effect.to_string every_effect in
  Alcotest.(check int) "distinct" (List.length labels) (List.length (List.sort_uniq String.compare labels));
  Alcotest.(check bool) "unknown" true (Option.is_none (Effect.of_string "Read_state"))
;;

let every_channel_has_a_label_that_reads_back () =
  List.iter
    (fun channel ->
       let label = Channel.to_string channel in
       Alcotest.(check bool) label true (Option.equal Channel.equal (Some channel) (Channel.of_string label)))
    every_channel;
  let labels = List.map Channel.to_string every_channel in
  Alcotest.(check int) "distinct" (List.length labels) (List.length (List.sort_uniq String.compare labels));
  Alcotest.(check bool) "unknown" true (Option.is_none (Channel.of_string "email"))
;;

(* ---- the bytes ---- *)

let the_bytes_of_a_scope () =
  Alcotest.(check string)
    "only and all"
    {|{"runtimes":["r-a","r-b"],"channels":["direct","schedule"],"allowed_effects":"all"}|}
    (Authz_body.to_string (to_body_exn some_scope));
  Alcotest.(check string)
    "empty"
    {|{"runtimes":[],"channels":[],"allowed_effects":[]}|}
    (Authz_body.to_string (to_body_exn empty_scope));
  Alcotest.(check string)
    "all"
    {|{"runtimes":"all","channels":"all","allowed_effects":"all"}|}
    (Authz_body.to_string (to_body_exn Authorization_scope.all));
  (* The effects in byte order of their labels, not in declaration order. *)
  Alcotest.(check string)
    "effects sorted"
    {|{"runtimes":"all","channels":"all","allowed_effects":["read_state","use_tool"]}|}
    (Authz_body.to_string
       (to_body_exn
          (scope
             ~runtimes:Runtime_scope.all
             ~channels:Channel_scope.all
             ~allowed_effects:(only_effects [ Effect.Use_tool; Effect.Read_state ]))))
;;

let a_scope_reads_back () =
  List.iter
    (fun (name, t) ->
       match B.of_body (to_body_exn t) with
       | Ok back -> Alcotest.(check bool) name true (scope_equal t back)
       | Error e -> Alcotest.failf "%s: %s" name (B.error_to_string e))
    [ "some", some_scope
    ; "empty", empty_scope
    ; "all", Authorization_scope.all
    ; ( "every channel and effect"
      , scope
          ~runtimes:(only_runtimes [ "r.1"; "r:2"; "R_3" ])
          ~channels:(only_channels every_channel)
          ~allowed_effects:(only_effects every_effect) )
    ]
;;

(* ---- refusals ---- *)

let members ?(runtimes = `String "all") ?(channels = `String "all") ?(allowed_effects = `String "all") () =
  `Assoc [ "runtimes", runtimes; "channels", channels; "allowed_effects", allowed_effects ]
;;

let strings texts = `List (List.map (fun text -> `String text) texts)

let refused () =
  List.iter
    (fun (name, json, expected) ->
       match B.of_body (body_of_json json) with
       | Ok _ -> Alcotest.failf "%s: read as a scope" name
       | Error e -> Alcotest.check error name expected e)
    [ "a list", `List [], B.Not_an_object
    ; "a string", `String "all", B.Not_an_object
    ; "null", `Null, B.Not_an_object
    ; ( "a member missing"
      , `Assoc [ "runtimes", `String "all"; "channels", `String "all" ]
      , B.Wrong_members )
    ; ( "a member more"
      , `Assoc
          [ "runtimes", `String "all"
          ; "channels", `String "all"
          ; "allowed_effects", `String "all"
          ; "expires_at", `Null
          ]
      , B.Wrong_members )
    ; ( "another order"
      , `Assoc
          [ "channels", `String "all"; "runtimes", `String "all"; "allowed_effects", `String "all" ]
      , B.Wrong_members )
    ; ( "another name"
      , `Assoc [ "runtimes", `String "all"; "channels", `String "all"; "effects", `String "all" ]
      , B.Wrong_members )
    ; "all in capitals", members ~runtimes:(`String "All") (), B.Not_a_scope B.Runtimes
    ; "null runtimes", members ~runtimes:`Null (), B.Not_a_scope B.Runtimes
    ; "a number", members ~channels:(`Int 1) (), B.Not_a_scope B.Channels
    ; "a list of numbers", members ~runtimes:(`List [ `Int 1 ]) (), B.Not_a_scope B.Runtimes
    ; ( "a null in the list"
      , members ~allowed_effects:(`List [ `String "read_state"; `Null ]) ()
      , B.Not_a_scope B.Allowed_effects )
    ; "an object", members ~channels:(`Assoc [ "direct", `Bool true ]) (), B.Not_a_scope B.Channels
    ; "descending", members ~runtimes:(strings [ "r-b"; "r-a" ]) (), B.Not_ascending B.Runtimes
    ; "repeated", members ~runtimes:(strings [ "r-a"; "r-a" ]) (), B.Not_ascending B.Runtimes
    ; ( "effects in declaration order"
      , members ~allowed_effects:(strings [ "use_tool"; "read_state" ]) ()
      , B.Not_ascending B.Allowed_effects )
    (* The order is checked before the labels. *)
    ; ( "unknown labels out of order"
      , members ~channels:(strings [ "zz"; "aa" ]) ()
      , B.Not_ascending B.Channels )
    ; ( "a bad runtime id"
      , members ~runtimes:(strings [ "a/b" ]) ()
      , B.Invalid_runtime_id (Authz_id.Invalid_byte { index = 1 }) )
    ; "an empty runtime id", members ~runtimes:(strings [ "" ]) (), B.Invalid_runtime_id Authz_id.Empty
    ; "a channel in capitals", members ~channels:(strings [ "Direct" ]) (), B.Unknown_channel "Direct"
    ; ( "an unknown channel after a known one"
      , members ~channels:(strings [ "direct"; "email" ]) ()
      , B.Unknown_channel "email" )
    ; "an unknown effect", members ~allowed_effects:(strings [ "write" ]) (), B.Unknown_effect "write"
    (* The members are read in order. *)
    ; ( "runtimes first"
      , members ~runtimes:`Null ~channels:(strings [ "email" ]) ()
      , B.Not_a_scope B.Runtimes )
    ]
;;

(* ---- a set of effects alone ---- *)

let an_effect_set () =
  let set = Effect.Set.of_list Effect.[ Use_tool; Read_state; Invoke_model ] in
  (match B.effect_set_to_body set with
   | Error _ -> Alcotest.fail "the set was not written"
   | Ok body ->
     Alcotest.(check string)
       "the bytes"
       {|["invoke_model","read_state","use_tool"]|}
       (Authz_body.to_string body);
     (match B.effect_set_of_body body with
      | Ok read -> Alcotest.(check bool) "reads back" true (Effect.Set.equal set read)
      | Error e -> Alcotest.failf "not read back: %s" (B.error_to_string e)));
  List.iter
    (fun (name, json, expected) ->
       match B.effect_set_of_body (body_of_json json) with
       | Ok _ -> Alcotest.failf "%s: read as a set" name
       | Error e -> Alcotest.check error name expected e)
    [ "all", `String "all", B.Not_a_scope B.Allowed_effects
    ; "an object", `Assoc [], B.Not_a_scope B.Allowed_effects
    ; "out of order", strings [ "use_tool"; "read_state" ], B.Not_ascending B.Allowed_effects
    ; "an unknown effect", strings [ "write" ], B.Unknown_effect "write"
    ]
;;

let () =
  Alcotest.run
    "authz_scope_body"
    [ ( "labels"
      , [ Alcotest.test_case
            "every effect has a label that reads back"
            `Quick
            every_effect_has_a_label_that_reads_back
        ; Alcotest.test_case
            "every channel has a label that reads back"
            `Quick
            every_channel_has_a_label_that_reads_back
        ] )
    ; ( "body"
      , [ Alcotest.test_case "the bytes of a scope" `Quick the_bytes_of_a_scope
        ; Alcotest.test_case "a scope reads back" `Quick a_scope_reads_back
        ] )
    ; "refused", [ Alcotest.test_case "bodies that are not a scope" `Quick refused ]
    ; "effect set", [ Alcotest.test_case "written, read back and refused" `Quick an_effect_set ]
    ]
;;
