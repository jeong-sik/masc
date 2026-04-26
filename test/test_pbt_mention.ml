(** Property-based tests for Mention module.

    Properties:
    1. parse(@@X) = Broadcast(X) for valid agent names
    2. parse(@X-Y-Z) = Stateful(X-Y-Z) for 3-part nicknames
    3. parse(@X) = Stateless(X) for simple names
    4. extract is consistent with parse
    5. is_nickname agrees with parse mode *)

let gen_agent_name =
  QCheck.Gen.(
    let* len = int_range 1 12 in
    let* chars =
      list_size
        (return len)
        (oneof [ char_range 'a' 'z'; char_range 'A' 'Z'; char_range '0' '9'; return '_' ])
    in
    return (String.init len (fun i -> List.nth chars i)))
;;

(* Nickname parts 2 and 3 must match [a-zA-Z0-9]+ (no underscore)
   per mention.ml stateful_re pattern *)
let gen_alnum_part =
  QCheck.Gen.(
    let* len = int_range 1 8 in
    let* chars =
      list_size
        (return len)
        (oneof [ char_range 'a' 'z'; char_range 'A' 'Z'; char_range '0' '9' ])
    in
    return (String.init len (fun i -> List.nth chars i)))
;;

let gen_nickname =
  QCheck.Gen.(
    let* a = gen_agent_name in
    let* b = gen_alnum_part in
    let* c = gen_alnum_part in
    return (a ^ "-" ^ b ^ "-" ^ c))
;;

let arb_agent_name = QCheck.make gen_agent_name ~print:Fun.id
let arb_nickname = QCheck.make gen_nickname ~print:Fun.id

(* Property 1: @@X always parses as Broadcast *)
let prop_broadcast_parse =
  QCheck.Test.make ~count:1000 ~name:"@@agent -> Broadcast" arb_agent_name (fun name ->
    let content = "Hey @@" ^ name ^ " check this" in
    match Mention.parse content with
    | Mention.Broadcast parsed -> String.equal parsed name
    | _ -> false)
;;

(* Property 2: @X-Y-Z always parses as Stateful *)
let prop_stateful_parse =
  QCheck.Test.make
    ~count:1000
    ~name:"@agent-adj-animal -> Stateful"
    arb_nickname
    (fun nickname ->
       let content = "Hello @" ^ nickname ^ " world" in
       match Mention.parse content with
       | Mention.Stateful parsed -> String.equal parsed nickname
       | _ -> false)
;;

(* Property 3: @X (no hyphen) always parses as Stateless *)
let prop_stateless_parse =
  QCheck.Test.make ~count:1000 ~name:"@agent -> Stateless" arb_agent_name (fun name ->
    (* Filter out names with hyphens — those would be Stateful *)
    QCheck.assume (not (String.contains name '-'));
    let content = "Message @" ^ name in
    match Mention.parse content with
    | Mention.Stateless parsed -> String.equal parsed name
    | _ -> false)
;;

(* Property 4: extract is consistent with parse *)
let prop_extract_consistent =
  QCheck.Test.make
    ~count:1000
    ~name:"extract consistent with parse"
    arb_agent_name
    (fun name ->
       let content = "@" ^ name in
       let parsed = Mention.parse content in
       let extracted = Mention.extract content in
       match parsed, extracted with
       | Mention.None, None -> true
       | Mention.Stateless s, Some e -> String.equal s e
       | Mention.Stateful s, Some e -> String.equal s e
       | Mention.Broadcast s, Some e -> String.equal s e
       | _ -> false)
;;

(* Property 5: is_nickname agrees with parse stateful mode *)
let prop_nickname_agreement =
  QCheck.Test.make
    ~count:1000
    ~name:"is_nickname true <=> 3+ parts"
    arb_nickname
    (fun nickname -> Mention.is_nickname nickname = true)
;;

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ prop_broadcast_parse
      ; prop_stateful_parse
      ; prop_stateless_parse
      ; prop_extract_consistent
      ; prop_nickname_agreement
      ]
  in
  Alcotest.run "pbt_mention" [ "properties", suite ]
;;
