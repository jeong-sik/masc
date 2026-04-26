(** Property-based tests for Validation module.

    Properties:
    1. Valid agent IDs always pass validation
    2. Empty string always fails
    3. Path separators always fail
    4. Path traversal always fails
    5. Validated agent_id roundtrips through to_string *)

let gen_valid_agent_id =
  QCheck.Gen.(
    let* len = int_range 1 64 in
    let* chars =
      list_size
        (return len)
        (oneof
           [ char_range 'a' 'z'
           ; char_range 'A' 'Z'
           ; char_range '0' '9'
           ; return '_'
           ; return '-'
           ])
    in
    return (String.init len (fun i -> List.nth chars i)))
;;

let gen_invalid_char_agent_id =
  QCheck.Gen.(
    let* valid_part = gen_valid_agent_id in
    let* bad_char =
      oneof [ return '/'; return '\\'; return ' '; return '@'; return '!'; return '#' ]
    in
    let* pos = int_range 0 (String.length valid_part) in
    let s = Bytes.of_string valid_part in
    if Bytes.length s > pos
    then (
      Bytes.set s pos bad_char;
      return (Bytes.to_string s))
    else return (valid_part ^ String.make 1 bad_char))
;;

let arb_valid_id = QCheck.make gen_valid_agent_id ~print:Fun.id
let arb_invalid_id = QCheck.make gen_invalid_char_agent_id ~print:Fun.id

(* Property 1: Valid IDs always pass *)
let prop_valid_always_ok =
  QCheck.Test.make ~count:1000 ~name:"valid agent_id always Ok" arb_valid_id (fun id ->
    Validation.reset_rejection_stats ();
    match Validation.Agent_id.validate id with
    | Ok _ -> true
    | Error _ -> false)
;;

(* Property 2: Empty string always fails *)
let prop_empty_fails =
  QCheck.Test.make
    ~count:1
    ~name:"empty agent_id always Error"
    QCheck.(make Gen.(return ""))
    (fun id ->
       Validation.reset_rejection_stats ();
       match Validation.Agent_id.validate id with
       | Error _ -> true
       | Ok _ -> false)
;;

(* Property 3: Path separators always cause rejection *)
let prop_path_sep_fails =
  QCheck.Test.make ~count:1000 ~name:"path separators rejected" arb_valid_id (fun base ->
    QCheck.assume (String.length base > 0);
    Validation.reset_rejection_stats ();
    let with_slash = base ^ "/" ^ base in
    match Validation.Agent_id.validate with_slash with
    | Error _ -> true
    | Ok _ -> false)
;;

(* Property 4: Path traversal always fails *)
let prop_traversal_fails =
  QCheck.Test.make ~count:1000 ~name:"path traversal rejected" arb_valid_id (fun suffix ->
    QCheck.assume (String.length suffix > 0);
    Validation.reset_rejection_stats ();
    let traversal = ".." ^ suffix in
    match Validation.Agent_id.validate traversal with
    | Error _ -> true
    | Ok _ -> false)
;;

(* Property 5: Validated ID roundtrips through to_string *)
let prop_roundtrip =
  QCheck.Test.make
    ~count:1000
    ~name:"validate -> to_string roundtrip"
    arb_valid_id
    (fun id ->
       Validation.reset_rejection_stats ();
       match Validation.Agent_id.validate id with
       | Ok validated -> String.equal (Validation.Agent_id.to_string validated) id
       | Error _ -> false)
;;

(* Property 6: IDs with invalid chars always fail *)
let prop_invalid_chars_fail =
  QCheck.Test.make ~count:1000 ~name:"invalid chars rejected" arb_invalid_id (fun id ->
    Validation.reset_rejection_stats ();
    match Validation.Agent_id.validate id with
    | Error _ -> true
    | Ok _ -> false)
;;

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ prop_valid_always_ok
      ; prop_empty_fails
      ; prop_path_sep_fails
      ; prop_traversal_fails
      ; prop_roundtrip
      ; prop_invalid_chars_fail
      ]
  in
  Alcotest.run "pbt_validation" [ "properties", suite ]
;;
