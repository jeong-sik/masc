type key =
  { kind : string
  ; base_url : string
  ; secret : Secret.identity option
  }

let key ~kind ~base_url ~secret = { kind; base_url; secret }

let key_equal left right =
  String.equal left.kind right.kind
  && String.equal left.base_url right.base_url
  && Option.equal Secret.equal_identity left.secret right.secret
;;

type conflict =
  { kind : string
  ; base_url : string
  ; authoritative_max : int
  ; declared_max : int
  }

type 'scheduler resolution =
  { scheduler : 'scheduler
  ; conflict : conflict option
  }

type 'scheduler entry =
  { key : key
  ; scheduler : 'scheduler
  ; declared_max : int
  ; conflict_reported : bool
  }

type 'scheduler t = 'scheduler entry list

let empty = []

let conflict_for entry ~declared_max =
  if entry.declared_max = declared_max || entry.conflict_reported
  then None, entry
  else
    ( Some
        { kind = entry.key.kind
        ; base_url = entry.key.base_url
        ; authoritative_max = entry.declared_max
        ; declared_max
        }
    , { entry with conflict_reported = true } )
;;

let resolve_existing key ~declared_max state =
  let rec loop before = function
    | [] -> None
    | entry :: after when key_equal key entry.key ->
      let conflict, entry = conflict_for entry ~declared_max in
      let state = List.rev_append before (entry :: after) in
      Some (state, { scheduler = entry.scheduler; conflict })
    | entry :: after -> loop (entry :: before) after
  in
  loop [] state
;;

let install key ~declared_max ~candidate state =
  match resolve_existing key ~declared_max state with
  | Some resolution -> resolution
  | None ->
    let entry =
      { key
      ; scheduler = candidate
      ; declared_max
      ; conflict_reported = false
      }
    in
    entry :: state, { scheduler = candidate; conflict = None }
;;

let find_scheduler key state =
  List.find_map
    (fun entry -> if key_equal key entry.key then Some entry.scheduler else None)
    state
;;

let[@warning "-32"] test_key =
  key ~kind:"test" ~base_url:"https://provider.test" ~secret:None
;;

let%test "first declaration installs its scheduler" =
  let state, resolution =
    install test_key ~declared_max:1 ~candidate:"first" empty
  in
  String.equal resolution.scheduler "first"
  && Option.is_none resolution.conflict
  && Option.equal String.equal (find_scheduler test_key state) (Some "first")
;;

let%test "a conflicting declaration reports once and keeps the first scheduler" =
  let state, _ = install test_key ~declared_max:1 ~candidate:"first" empty in
  match resolve_existing test_key ~declared_max:5 state with
  | None -> false
  | Some (state, resolution) ->
    String.equal resolution.scheduler "first"
    && (match resolution.conflict with
        | Some conflict ->
          conflict.authoritative_max = 1 && conflict.declared_max = 5
        | None -> false)
    && (match resolve_existing test_key ~declared_max:5 state with
        | Some (_, resolution) -> Option.is_none resolution.conflict
        | None -> false)
;;

let%test "a raced installer reuses the winner" =
  let state, _ = install test_key ~declared_max:2 ~candidate:"winner" empty in
  let _, resolution =
    install test_key ~declared_max:2 ~candidate:"loser" state
  in
  String.equal resolution.scheduler "winner"
;;
