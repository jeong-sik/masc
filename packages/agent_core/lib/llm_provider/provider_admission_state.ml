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

type allowance =
  { max : int
  ; priority_run_limit : int option
  }

let allowance_equal left right =
  Int.equal left.max right.max
  && Option.equal Int.equal left.priority_run_limit right.priority_run_limit
;;

type conflict =
  { kind : string
  ; base_url : string
  ; authoritative : allowance
  ; declared : allowance
  }

type 'scheduler resolution =
  { scheduler : 'scheduler
  ; conflict : conflict option
  }

type 'scheduler entry =
  { key : key
  ; scheduler : 'scheduler
  ; declared : allowance
  ; published : bool
      (** The consumer published [declared] for this identity, so it is the
          allowance every request on the identity runs under. *)
  }

type 'scheduler t = 'scheduler entry list

let empty = []

let conflict_for entry ~declared =
  if entry.published || allowance_equal entry.declared declared
  then None, entry
  else
    ( Some
        { kind = entry.key.kind
        ; base_url = entry.key.base_url
        ; authoritative = entry.declared
        ; declared
        }
    , entry )
;;

let resolve_existing key ~declared state =
  let rec loop before = function
    | [] -> None
    | entry :: after when key_equal key entry.key ->
      let conflict, entry = conflict_for entry ~declared in
      let state = List.rev_append before (entry :: after) in
      Some (state, { scheduler = entry.scheduler; conflict })
    | entry :: after -> loop (entry :: before) after
  in
  loop [] state
;;

let install key ~declared ~candidate state =
  match resolve_existing key ~declared state with
  | Some resolution -> resolution
  | None ->
    let entry =
      { key
      ; scheduler = candidate
      ; declared
      ; published = false
      }
    in
    entry :: state, { scheduler = candidate; conflict = None }
;;

type 'scheduler publication =
  | Published_new of 'scheduler
  | Published_unchanged of 'scheduler
  | Published_changed of 'scheduler

let publish key ~declared ~candidate state =
  let rec loop before = function
    | [] ->
      ( { key; scheduler = candidate; declared; published = true } :: state
      , Published_new candidate )
    | entry :: after when key_equal key entry.key ->
      let unchanged = allowance_equal entry.declared declared in
      let entry = { entry with declared; published = true } in
      ( List.rev_append before (entry :: after)
      , if unchanged
        then Published_unchanged entry.scheduler
        else Published_changed entry.scheduler )
    | entry :: after -> loop (entry :: before) after
  in
  loop [] state
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
    install test_key ~declared:{ max = 1; priority_run_limit = None } ~candidate:"first" empty
  in
  String.equal resolution.scheduler "first"
  && Option.is_none resolution.conflict
  && Option.equal String.equal (find_scheduler test_key state) (Some "first")
;;

let%test "a conflicting declaration remains conflicting and keeps the first scheduler" =
  let state, _ = install test_key ~declared:{ max = 1; priority_run_limit = None } ~candidate:"first" empty in
  match resolve_existing test_key ~declared:{ max = 5; priority_run_limit = None } state with
  | None -> false
  | Some (state, resolution) ->
    String.equal resolution.scheduler "first"
    && (match resolution.conflict with
        | Some conflict ->
          conflict.authoritative.max = 1 && conflict.declared.max = 5
        | None -> false)
    && (match resolve_existing test_key ~declared:{ max = 5; priority_run_limit = None } state with
        | Some (_, resolution) ->
          (match resolution.conflict with
           | Some conflict ->
             conflict.authoritative.max = 1 && conflict.declared.max = 5
           | None -> false)
        | None -> false)
;;

let%test "a different priority run limit is a conflict" =
  let state, _ =
    install test_key ~declared:{ max = 4; priority_run_limit = Some 3 } ~candidate:"first" empty
  in
  match resolve_existing test_key ~declared:{ max = 4; priority_run_limit = None } state with
  | Some (_, { conflict = Some conflict; _ }) ->
    conflict.authoritative.priority_run_limit = Some 3
    && Option.is_none conflict.declared.priority_run_limit
  | Some (_, { conflict = None; _ }) | None -> false
;;

let%test "a published identity resolves every declaration to the published allowance" =
  let state, _ =
    install test_key ~declared:{ max = 2; priority_run_limit = None } ~candidate:"first" empty
  in
  let state, publication =
    publish test_key ~declared:{ max = 4; priority_run_limit = Some 3 } ~candidate:"unused" state
  in
  (match publication with
   | Published_changed scheduler -> String.equal scheduler "first"
   | Published_new _ | Published_unchanged _ -> false)
  && (match resolve_existing test_key ~declared:{ max = 2; priority_run_limit = None } state with
      | Some (_, { scheduler; conflict = None }) -> String.equal scheduler "first"
      | Some (_, { conflict = Some _; _ }) | None -> false)
;;

let%test "publishing an absent identity installs its candidate" =
  match
    publish test_key ~declared:{ max = 1; priority_run_limit = None } ~candidate:"new" empty
  with
  | state, Published_new scheduler ->
    String.equal scheduler "new"
    && Option.equal String.equal (find_scheduler test_key state) (Some "new")
  | _, (Published_changed _ | Published_unchanged _) -> false
;;

let%test "a raced installer reuses the winner" =
  let state, _ = install test_key ~declared:{ max = 2; priority_run_limit = None } ~candidate:"winner" empty in
  let _, resolution =
    install test_key ~declared:{ max = 2; priority_run_limit = None } ~candidate:"loser" state
  in
  String.equal resolution.scheduler "winner"
;;
