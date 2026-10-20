let ( let* ) = Result.bind

type grant =
  | Board of { source_id : string; visibilities : Board_types.visibility list }
  | Repository of { source_id : string; repository_id : string; paths : string list }
  | Wiki of { source_id : string }
  | Github_pulls of { source_id : string; repository_id : string }

let source_id = function
  | Board { source_id; _ } | Repository { source_id; _ } | Wiki { source_id }
  | Github_pulls { source_id; _ } -> source_id
let source_id_of = source_id

let exact_keys keys fields =
  match List.find_opt (fun (key, _) -> not (List.mem key keys)) fields with
  | Some (key, _) -> Error ("a record grant has no key " ^ key)
  | None -> Ok ()

let text fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" && String.trim value = value -> Ok value
  | Some _ | None -> Error (key ^ " requires a non-blank string")

let strings fields key =
  match List.assoc_opt key fields with
  | Some (`List (_ :: _ as values)) ->
    let* values =
      List.fold_right
        (fun value acc ->
           let* acc = acc in
           match value with
           | `String text -> Ok (text :: acc)
           | _ -> Error (key ^ " holds strings"))
        values (Ok [])
    in
    if List.length (List.sort_uniq String.compare values) = List.length values then Ok values
    else Error (key ^ " names a value twice")
  | Some _ | None -> Error (key ^ " requires a non-empty array")

(* A path is relative to the repository root and never leaves it. *)
let valid_path path =
  path <> "" && path.[0] <> '/'
  && List.for_all (fun segment -> segment <> ".." && segment <> ".")
       (List.filter (fun segment -> segment <> "") (String.split_on_char '/' path))

let grant_of_json = function
  | `Assoc fields ->
    let* source_id = text fields "source_id" in
    (match List.assoc_opt "kind" fields with
     | Some (`String "board") ->
       let* () = exact_keys [ "source_id"; "kind"; "visibilities" ] fields in
       let* names = strings fields "visibilities" in
       let* visibilities =
         List.fold_right
           (fun name acc ->
              let* acc = acc in
              match Board_core_classify.visibility_of_string name with
              | Some visibility -> Ok (visibility :: acc)
              | None -> Error ("visibilities has no value " ^ name))
           names (Ok [])
       in
       Ok (Board { source_id; visibilities })
     | Some (`String "repository") ->
       let* () = exact_keys [ "source_id"; "kind"; "repository_id"; "paths" ] fields in
       let* repository_id = text fields "repository_id" in
       let* paths = strings fields "paths" in
       (match List.find_opt (fun path -> not (valid_path path)) paths with
        | Some path -> Error ("paths must stay inside the repository: " ^ path)
        | None -> Ok (Repository { source_id; repository_id; paths }))
     | Some (`String "wiki") ->
       let* () = exact_keys [ "source_id"; "kind" ] fields in
       Ok (Wiki { source_id })
     | Some (`String "github_pulls") ->
       let* () = exact_keys [ "source_id"; "kind"; "repository_id" ] fields in
       let* repository_id = text fields "repository_id" in
       Ok (Github_pulls { source_id; repository_id })
     | Some (`String kind) -> Error ("this host has no record kind " ^ kind)
     | Some _ | None -> Error "a record grant requires a string kind")
  | _ -> Error "a record grant must be an object"

let grants ~operator_owned = function
  | `Assoc fields ->
    (match List.assoc_opt "records" fields with
     | None -> Ok []
     | Some _ when not operator_owned -> Error "only an operator-owned declaration may hold record grants"
     | Some (`List values) ->
       let* grants =
         List.fold_right
           (fun value acc ->
              let* acc = acc in
              let* grant = grant_of_json value in
              Ok (grant :: acc))
           values (Ok [])
       in
       let ids = List.map source_id grants in
       if List.length (List.sort_uniq String.compare ids) = List.length ids then Ok grants
       else Error "records names the same source_id twice"
     | Some _ -> Error "records requires an array of grants")
  | _ -> Error "a binding must be an object"

let covers ~paths file =
  valid_path file
  && List.exists
    (fun path ->
       if String.ends_with ~suffix:"/" path then String.starts_with ~prefix:path file
       else String.equal path file)
    paths

type read =
  | Page of Yojson.Safe.t
  | Not_allowed of string
  | Unavailable of string

type start =
  | From_beginning
  | After of string
  | Since of float

(* The cursor a read with no record answers: the one it was given. *)
let start_cursor = function After cursor -> Some cursor | From_beginning | Since _ -> None

(* A record's place in the oldest-first order. The package gets it back as an
   opaque cursor. *)
type key = { at : float; kind : string; id : string }

let compare_key a b =
  match Float.compare a.at b.at with
  | 0 -> (match String.compare a.kind b.kind with 0 -> String.compare a.id b.id | order -> order)
  | order -> order

let cursor_of_key key = Printf.sprintf "%h|%s|%s" key.at key.kind key.id

let key_of_cursor cursor =
  match String.index_opt cursor '|' with
  | None -> None
  | Some first ->
    (match String.index_from_opt cursor (first + 1) '|' with
     | None -> None
     | Some second ->
       let at = float_of_string_opt (String.sub cursor 0 first) in
       let kind = String.sub cursor (first + 1) (second - first - 1) in
       let id = String.sub cursor (second + 1) (String.length cursor - second - 1) in
       (match at, kind with
        | Some at, ("post" | "comment") when Float.is_finite at && id <> "" -> Some { at; kind; id }
        | (Some _ | None), _ -> None))

let board_records ~visibilities =
  let* () =
    Board_dispatch.require_persisted_sources_readable () |> Result.map_error Board.show_board_error
  in
  match Board_dispatch.backend () with
  | Board_dispatch.Jsonl store ->
    let posts =
      Board.search_posts store
        ~predicate:(fun (post : Board.post) -> List.mem post.visibility visibilities)
        ~limit:max_int
    in
    let post_record (post : Board.post) =
      let id = Board.Post_id.to_string post.id in
      ( { at = post.created_at; kind = "post"; id }
      , `Assoc
          [ "kind", `String "post"; "id", `String id
          ; "author", `String (Board.Agent_id.to_string post.author)
          ; "created_at", `Float post.created_at; "updated_at", `Float post.updated_at
          ; "visibility", `String (Board_core_classify.visibility_to_string post.visibility)
          ; "title", `String post.title; "body", `String post.body ] )
    in
    let comment_record (comment : Board.comment) =
      let id = Board.Comment_id.to_string comment.id in
      ( { at = comment.created_at; kind = "comment"; id }
      , `Assoc
          [ "kind", `String "comment"; "id", `String id
          ; "post_id", `String (Board.Post_id.to_string comment.post_id)
          ; "author", `String (Board.Agent_id.to_string comment.author)
          ; "created_at", `Float comment.created_at; "body", `String comment.content ] )
    in
    let* comments =
      List.fold_left
        (fun acc (post : Board.post) ->
           let* acc = acc in
           match Board.read_comments store ~post_id:(Board.Post_id.to_string post.id) with
           | Ok comments -> Ok (List.rev_append (List.map comment_record comments) acc)
           | Error error -> Error (Board.show_board_read_error error))
        (Ok []) posts
    in
    Ok (List.rev_append (List.map post_record posts) comments)

(* The page body for the records taken so far. *)
let page_body ?head ~source_id ~records ~next_cursor ~complete ~sha256 () =
  `Assoc
    ([ "status", `String "records"; "source_id", `String source_id ]
     @ (match head with None -> [] | Some head -> [ "head", `String head ])
     @ [ "records", `List records
       ; "next_cursor", (match next_cursor with None -> `Null | Some cursor -> `String cursor)
       ; "complete", `Bool complete; "sha256", `String sha256 ])

(* Every page has a 64-hex SHA-256; measuring with a placeholder of that size
   gives the exact size of the answered body. *)
let sha256_placeholder = String.make 64 '0'

(* What a page took: its records, the cursor of the last item it passed, and
   whether it passed every item. *)
type taken = { records : Yojson.Safe.t list; passed : string option; complete : bool }

(* [items] pairs each item's cursor with the work that produces its record, so
   a reader that pays per item (a commit) stops at the first record that does
   not fit. An item with no record ([None], a commit no pull request merged)
   moves the cursor past it and takes no bytes. [Yojson] writes an array as
   its elements joined by commas, so a page's size is the size of the same
   body with no records, plus each record, plus one comma between two. *)
let take_page ~measure ~max_bytes ~empty_body items =
  let rec take records passed bytes = function
    | [] -> Ok { records = List.rev records; passed; complete = true }
    | (cursor, record) :: rest ->
      let* json = record () in
      (match json with
       | None -> take records (Some cursor) bytes rest
       | Some json ->
         let encoded = String.length (Yojson.Safe.to_string json) in
         let separator = match records with [] -> 0 | _ :: _ -> 1 in
         let base = measure (empty_body ~next_cursor:(Some cursor)) in
         let fits = base + bytes + separator + encoded <= max_bytes in
         (match records with
          | [] -> take [ json ] (Some cursor) (bytes + separator + encoded) rest
          | _ :: _ when fits -> take (json :: records) (Some cursor) (bytes + separator + encoded) rest
          | _ :: _ -> Ok { records = List.rev records; passed; complete = false }))
  in
  take [] None 0 items

(* Retains the page's records, then answers it. *)
let answer_page ?head ~store ~source_id ~start { records; passed; complete } =
  let next_cursor = match passed with Some cursor -> Some cursor | None -> start_cursor start in
  match
    Eio_unix.run_in_systhread (fun () ->
      Lane_addon_store.write_blob store (Yojson.Safe.to_string (`List records)))
  with
  | Error detail -> Unavailable ("the page could not be retained: " ^ detail)
  | Ok { Lane_addon_types.sha256 = None; _ } -> Unavailable "the retained page has no digest"
  | Ok { Lane_addon_types.sha256 = Some sha256; _ } ->
    Page (page_body ?head ~source_id ~records ~next_cursor ~complete ~sha256 ())

let git ~cwd args = Repo_git.run_git_read_only_raw ~cwd args

let commit_id_shaped value =
  (String.length value = 40 || String.length value = 64)
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let checkout ~base_path ~repository_id =
  let* repository = Repo_store.find ~base_path repository_id in
  let cwd = Repo_store.local_path ~base_path repository in
  let* head = git ~cwd [ "rev-parse"; "--verify"; "refs/heads/" ^ repository.Repo_manager_types.default_branch ^ "^{commit}" ] in
  Ok (cwd, String.trim head)

(* Whether [commit] is a commit the default branch's head reaches. *)
let reached ~cwd ~head commit =
  match git ~cwd [ "cat-file"; "-t"; commit ] with
  | Ok kind when String.trim kind = "commit" ->
    (match git ~cwd [ "merge-base"; commit; head ] with
     | Ok base -> String.equal (String.trim base) commit
     | Error _ -> false)
  | Ok _ | Error _ -> false

let commit_record ~cwd sha () =
  let* header = git ~cwd [ "show"; "-s"; "-z"; "--format=%H%x00%an%x00%ct%x00%s%x00%b"; sha ] in
  let* names = git ~cwd [ "show"; "--format="; "--name-only"; "-z"; "--diff-merges=first-parent"; sha ] in
  let fields = String.split_on_char '\000' header in
  match fields with
  | [ sha; author; time; subject; body ] | [ sha; author; time; subject; body; "" ] ->
    let* committed_at = Option.to_result ~none:("commit time of " ^ sha) (int_of_string_opt time) in
    let paths = List.filter (fun name -> name <> "") (String.split_on_char '\000' (String.trim names)) in
    Ok
      (`Assoc
         [ "kind", `String "commit"; "sha", `String sha; "author", `String author
         ; "committed_at", `Int committed_at; "subject", `String subject; "body", `String body
         ; "paths", `List (List.map (fun path -> `String path) paths) ])
  | _ -> Error ("unreadable commit " ^ sha)

(* What reading the default branch's history can come to. *)
type history =
  | Commits of string list  (** First-parent commits from the start, oldest first. *)
  | Not_on_branch  (** [after] is not a commit the head reaches. *)
  | Unreadable of string

(* A [Since] read compares each commit's commit time, the time its record
   reports. *)
let first_parent_commits ~cwd ~head start =
  let lines output = List.filter (fun line -> line <> "") (String.split_on_char '\n' output) in
  let listed = function Ok output -> Commits (lines output) | Error detail -> Unreadable detail in
  match start with
  | From_beginning -> listed (git ~cwd [ "rev-list"; "--first-parent"; "--reverse"; head ])
  | After after when commit_id_shaped after && reached ~cwd ~head after ->
    listed (git ~cwd [ "rev-list"; "--first-parent"; "--reverse"; after ^ ".." ^ head ])
  | After _ -> Not_on_branch
  | Since at ->
    (match git ~cwd [ "log"; "--first-parent"; "--reverse"; "--format=%H %ct"; head ] with
     | Error detail -> Unreadable detail
     | Ok output ->
       let newer =
         List.fold_right
           (fun line acc ->
              let* acc = acc in
              match String.split_on_char ' ' line with
              | [ sha; time ] ->
                (match float_of_string_opt time with
                 | Some committed_at when committed_at >= at -> Ok (sha :: acc)
                 | Some _ -> Ok acc
                 | None -> Error ("commit time of " ^ sha))
              | _ -> Error ("unreadable history line " ^ line))
           (lines output) (Ok [])
       in
       (match newer with Ok shas -> Commits shas | Error detail -> Unreadable detail))

(* The registered checkout, its head, and the default branch's first-parent
   commits from [start], oldest first. *)
let branch_commits ~base_path ~repository_id start =
  match checkout ~base_path ~repository_id with
  | Error detail -> Error (Unavailable ("repository " ^ repository_id ^ " cannot be read: " ^ detail))
  | Ok (cwd, head) ->
    (match first_parent_commits ~cwd ~head start with
     | Not_on_branch -> Error (Not_allowed "after is not a commit of the default branch")
     | Unreadable detail -> Error (Unavailable ("the history cannot be read: " ^ detail))
     | Commits shas -> Ok (cwd, head, shas))

let repository_records ~base_path ~store ~measure ~max_bytes ~source_id ~repository_id ~start =
  match branch_commits ~base_path ~repository_id start with
  | Error read -> read
  | Ok (cwd, head, shas) ->
    let empty_body ~next_cursor =
      page_body ~head ~source_id ~records:[] ~next_cursor ~complete:false ~sha256:sha256_placeholder ()
    in
    let items = List.map (fun sha -> sha, fun () -> Result.map Option.some (commit_record ~cwd sha ())) shas in
    (match take_page ~measure ~max_bytes ~empty_body items with
     | Error detail -> Unavailable ("a commit cannot be read: " ^ detail)
     | Ok page -> answer_page ~head ~store ~source_id ~start page)

(* A wiki log line read up to and including [position] lines, with the page
   and revision that line names. The host checks all three against the log
   it reads now, so a log that was rewritten refuses the cursor. *)
let wiki_cursor ~position (line : Wiki_log.line) = Printf.sprintf "%d|%s|%d" position line.page line.revision

let wiki_position lines cursor =
  match String.index_opt cursor '|' with
  | None -> None
  | Some bar ->
    (match int_of_string_opt (String.sub cursor 0 bar) with
     | Some position when position >= 1 && position <= Array.length lines ->
       if String.equal (wiki_cursor ~position lines.(position - 1)) cursor then Some position else None
     | Some _ | None -> None)

let wiki_log ~root =
  match Fs_compat.load_file_opt (Filename.concat root Wiki_journal.log_file) with
  | exception Sys_error detail -> Error detail
  | None -> Ok [||]
  | Some content -> Ok (Array.of_list (Wiki_log.parse content).Wiki_log.lines)

(* The page as it is now, or [None] when no page by that name reads. *)
let wiki_page ~root name =
  match Wiki_page_name.validate_page_name name with
  | Error _ -> Ok None
  | Ok name ->
    (match Fs_compat.load_file_opt (Filename.concat root (name ^ ".md")) with
     | exception Sys_error detail -> Error detail
     | None -> Ok None
     | Some content ->
       (match Wiki_page.parse_frontmatter content with
        | Error _ -> Ok None
        | Ok (header : Wiki_page.frontmatter) ->
          Ok
            (Some
               (`Assoc
                  [ "kind", `String "page"; "name", `String name; "revision", `Int header.revision
                  ; "title", `String (header.title :> string); "summary", `String (header.summary :> string)
                  ; "author", `String (header.author :> string); "body", `String (Wiki_page.page_body content) ]))))

(* Which log positions a read may answer from. The log stamps only the
   minute, so a [Since] read keeps a line whose minute ends after that time:
   a page written in the same minute is not missed, at the cost of one
   written up to a minute before. *)
let wiki_window lines start =
  match start with
  | From_beginning -> Ok (fun _ -> true)
  | After cursor ->
    (match wiki_position lines cursor with
     | Some position -> Ok (fun index -> index >= position)
     | None -> Error "after is not a cursor this host gave")
  | Since at -> Ok (fun index -> lines.(index).Wiki_log.written_at +. 60. > at)

let wiki_records ~base_path ~store ~measure ~max_bytes ~source_id ~start =
  let root = Config_dir_resolver.wiki_dir ~base_path in
  match wiki_log ~root with
  | Error detail -> Unavailable ("the wiki log cannot be read: " ^ detail)
  | Ok lines ->
    (match wiki_window lines start with
     | Error reason -> Not_allowed reason
     | Ok within ->
       let latest = Hashtbl.create (Array.length lines) in
       Array.iteri (fun position (line : Wiki_log.line) -> Hashtbl.replace latest line.page position) lines;
       let pending =
         List.filter
           (fun position -> within position && Hashtbl.find_opt latest lines.(position).Wiki_log.page = Some position)
           (List.init (Array.length lines) Fun.id)
       in
       let items =
         List.fold_right
           (fun position acc ->
              let* acc = acc in
              let line = lines.(position) in
              let* page = wiki_page ~root line.Wiki_log.page in
              match page with
              | None -> Ok acc
              | Some json -> Ok ((wiki_cursor ~position:(position + 1) line, fun () -> Ok (Some json)) :: acc))
           pending (Ok [])
       in
       (match items with
        | Error detail -> Unavailable ("a wiki page cannot be read: " ^ detail)
        | Ok items ->
          let empty_body ~next_cursor =
            page_body ~source_id ~records:[] ~next_cursor ~complete:false ~sha256:sha256_placeholder ()
          in
          (match take_page ~measure ~max_bytes ~empty_body items with
           | Error detail -> Unavailable detail
           | Ok page -> answer_page ~store ~source_id ~start page)))

type github_repository = {
  owner : string;
  name : string;
  post : Yojson.Safe.t -> (Yojson.Safe.t, string) result;
}

type github = repository_id:string -> (github_repository, string) result

(* GitHub's largest [first] on a connection. *)
let github_page_size = 100

let associated_query =
  {|query($owner: String!, $name: String!, $oid: GitObjectID!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        associatedPullRequests(first: $first, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { id number title body merged mergedAt mergeCommit { oid } author { login } }
        }
      }
    }
  }
}|}

let comment_fields = "databaseId author { login } createdAt path line body"

let reviews_query =
  Printf.sprintf
    {|query($id: ID!, $first: Int!, $after: String) {
  node(id: $id) {
    ... on PullRequest {
      reviews(first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id databaseId author { login } submittedAt state body
          comments(first: $first) { pageInfo { hasNextPage endCursor } nodes { %s } }
        }
      }
    }
  }
}|}
    comment_fields

let review_comments_query =
  Printf.sprintf
    {|query($id: ID!, $first: Int!, $after: String) {
  node(id: $id) {
    ... on PullRequestReview {
      comments(first: $first, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes { %s }
      }
    }
  }
}|}
    comment_fields

let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let path json keys = List.fold_left (fun json key -> Option.bind json (member key)) (Some json) keys

let gh_text json key =
  match member key json with Some (`String value) -> Ok value | _ -> Error (key ^ " is not a string")

let gh_text_or_null json key =
  match member key json with
  | Some (`String value) -> Ok (`String value)
  | Some `Null -> Ok `Null
  | _ -> Error (key ^ " is not a string or null")

let gh_int json key = match member key json with Some (`Int value) -> Ok value | _ -> Error (key ^ " is not an integer")

let gh_int_or_null json key =
  match member key json with
  | Some (`Int value) -> Ok (`Int value)
  | Some `Null -> Ok `Null
  | _ -> Error (key ^ " is not an integer or null")

(* GitHub answers [null] for the author of a deleted account. *)
let gh_author json =
  match member "author" json with
  | Some `Null -> Ok `Null
  | Some author -> Result.map (fun login -> `String login) (gh_text author "login")
  | None -> Error "author is absent"

let map_result f values =
  List.fold_right (fun value acc -> let* acc = acc in let* mapped = f value in Ok (mapped :: acc)) values (Ok [])

let github_request ~query ~variables ~after =
  `Assoc
    [ "query", `String query
    ; ( "variables"
      , `Assoc
          (("first", `Int github_page_size)
           :: ("after", match after with None -> `Null | Some cursor -> `String cursor)
           :: variables) ) ]

(* One page of a connection: its nodes and the cursor of the next page. *)
let page_of connection =
  let info key = Option.bind (member "pageInfo" connection) (member key) in
  match member "nodes" connection, info "hasNextPage", info "endCursor" with
  | Some (`List nodes), Some (`Bool false), _ -> Ok (nodes, None)
  | Some (`List nodes), Some (`Bool true), Some (`String cursor) -> Ok (nodes, Some cursor)
  | _ -> Error "a connection page has no nodes or no next page cursor"

let in_data keys answer =
  match path answer ("data" :: keys) with
  | Some connection -> page_of connection
  | None -> Error ("the answer has no data." ^ String.concat "." keys)

(* Every node of a connection, from a page already read and then page by
   page until GitHub reports no next page. *)
let rest_of ~session ~query ~variables ~extract (nodes, next) =
  let rec pages taken seen = function
    | None -> Ok (List.concat (List.rev taken))
    | Some cursor when List.mem cursor seen -> Error "GitHub repeated a page cursor"
    | Some cursor ->
      let* answer = session.post (github_request ~query ~variables ~after:(Some cursor)) in
      let* nodes, next = extract answer in
      pages (nodes :: taken) (cursor :: seen) next
  in
  pages [ nodes ] [] next

let all_nodes ~session ~query ~variables ~extract =
  let* answer = session.post (github_request ~query ~variables ~after:None) in
  let* page = extract answer in
  rest_of ~session ~query ~variables ~extract page

(* A commit GitHub does not hold was merged by no pull request. *)
let associated_page answer =
  match path answer [ "data"; "repository"; "object" ] with
  | Some `Null -> Ok ([], None)
  | Some _ -> in_data [ "repository"; "object"; "associatedPullRequests" ] answer
  | None -> Error "the answer has no data.repository.object"

let merges sha node =
  member "merged" node = Some (`Bool true)
  && (match Option.bind (member "mergeCommit" node) (member "oid") with
      | Some (`String oid) -> String.equal oid sha
      | _ -> false)

let comment_record node =
  let* id = gh_int node "databaseId" in
  let* author = gh_author node in
  let* created_at = gh_text node "createdAt" in
  let* file = gh_text node "path" in
  let* line = gh_int_or_null node "line" in
  let* body = gh_text node "body" in
  Ok
    (`Assoc
       [ "id", `Int id; "author", author; "created_at", `String created_at; "path", `String file
       ; "line", line; "body", `String body ])

let review_record ~session node =
  let* node_id = gh_text node "id" in
  let* id = gh_int node "databaseId" in
  let* author = gh_author node in
  let* submitted_at = gh_text_or_null node "submittedAt" in
  let* state = gh_text node "state" in
  let* body = gh_text node "body" in
  let* first = match member "comments" node with Some connection -> page_of connection | None -> Error "a review has no comments" in
  let* comments =
    rest_of ~session ~query:review_comments_query ~variables:[ "id", `String node_id ]
      ~extract:(in_data [ "node"; "comments" ]) first
  in
  let* comments = map_result comment_record comments in
  Ok
    (`Assoc
       [ "id", `Int id; "author", author; "submitted_at", submitted_at; "state", `String state
       ; "body", `String body; "comments", `List comments ])

let pull_record ~session ~sha node =
  let* node_id = gh_text node "id" in
  let* number = gh_int node "number" in
  let* title = gh_text node "title" in
  let* body = gh_text node "body" in
  let* merged_at = gh_text node "mergedAt" in
  let* author = gh_author node in
  let* reviews =
    all_nodes ~session ~query:reviews_query ~variables:[ "id", `String node_id ]
      ~extract:(in_data [ "node"; "reviews" ])
  in
  let* reviews = map_result (review_record ~session) reviews in
  Ok
    (`Assoc
       [ "kind", `String "pull_request"; "number", `Int number; "title", `String title; "body", `String body
       ; "merge_commit", `String sha; "merged_at", `String merged_at; "author", author
       ; "reviews", `List reviews ])

(* The pull request that merged [sha], with its reviews. A commit no pull
   request merged, such as one pushed straight to the branch or an earlier
   commit of a rebase merge, has no record. *)
let merged_pull ~session sha () =
  let* nodes =
    all_nodes ~session ~query:associated_query
      ~variables:[ "owner", `String session.owner; "name", `String session.name; "oid", `String sha ]
      ~extract:associated_page
  in
  match List.filter (merges sha) nodes with
  | [] -> Ok None
  | [ node ] -> Result.map Option.some (pull_record ~session ~sha node)
  | _ :: _ :: _ -> Error ("GitHub names more than one pull request merged as " ^ sha)

let github_records ~base_path ~store ~github ~measure ~max_bytes ~source_id ~repository_id ~start =
  match branch_commits ~base_path ~repository_id start with
  | Error read -> read
  | Ok (_, head, shas) ->
    (match github ~repository_id with
     | Error detail -> Unavailable ("GitHub cannot be read for repository " ^ repository_id ^ ": " ^ detail)
     | Ok session ->
       let empty_body ~next_cursor =
         page_body ~head ~source_id ~records:[] ~next_cursor ~complete:false ~sha256:sha256_placeholder ()
       in
       let items = List.map (fun sha -> sha, merged_pull ~session sha) shas in
       (match take_page ~measure ~max_bytes ~empty_body items with
        | Error detail -> Unavailable ("GitHub could not be read: " ^ detail)
        | Ok page -> answer_page ~head ~store ~source_id ~start page))

let granted grants source_id = List.find_opt (fun grant -> String.equal (source_id_of grant) source_id) grants
let not_granted source_id = Not_allowed ("source " ^ source_id ^ " is not granted to this installation")

(* Which Board records a read keeps, or why its cursor is refused. *)
let board_pending start =
  match start with
  | From_beginning -> Ok (fun _ -> true)
  | Since at -> Ok (fun (key : key) -> key.at >= at)
  | After cursor ->
    (match key_of_cursor cursor with
     | Some after -> Ok (fun key -> compare_key key after > 0)
     | None -> Error "after is not a cursor this host gave")

let read_records ~base_path ~store ~grants ~github ~measure ~max_bytes ~source_id ~start =
  match granted grants source_id with
  | None -> not_granted source_id
  | Some (Repository { repository_id; _ }) ->
    repository_records ~base_path ~store ~measure ~max_bytes ~source_id ~repository_id ~start
  | Some (Wiki _) -> wiki_records ~base_path ~store ~measure ~max_bytes ~source_id ~start
  | Some (Github_pulls { repository_id; _ }) ->
    github_records ~base_path ~store ~github ~measure ~max_bytes ~source_id ~repository_id ~start
  | Some (Board { visibilities; _ }) ->
    (match board_pending start with
     | Error reason -> Not_allowed reason
     | Ok keep ->
       (match board_records ~visibilities with
        | Error detail -> Unavailable ("the Board cannot be read: " ^ detail)
        | Ok records ->
          let sorted = List.sort (fun (a, _) (b, _) -> compare_key a b) records in
          let pending = List.filter (fun (key, _) -> keep key) sorted in
          let empty_body ~next_cursor =
            page_body ~source_id ~records:[] ~next_cursor ~complete:false ~sha256:sha256_placeholder ()
          in
          let items = List.map (fun (key, json) -> cursor_of_key key, fun () -> Ok (Some json)) pending in
          (match take_page ~measure ~max_bytes ~empty_body items with
           | Error detail -> Unavailable detail
           | Ok page -> answer_page ~store ~source_id ~start page)))

let read_file ~base_path ~store ~grants ~source_id ~commit ~path =
  match granted grants source_id with
  | None -> not_granted source_id
  | Some (Board _) -> Not_allowed ("source " ^ source_id ^ " is a board; read_file reads a repository")
  | Some (Wiki _) -> Not_allowed ("source " ^ source_id ^ " is a wiki; read_file reads a repository")
  | Some (Github_pulls _) ->
    Not_allowed ("source " ^ source_id ^ " is GitHub pull requests; read_file reads a repository")
  | Some (Repository { repository_id; paths; _ }) ->
    if not (covers ~paths path) then Not_allowed ("path " ^ path ^ " is outside the grant's paths")
    else if not (commit_id_shaped commit) then Not_allowed "commit must be a full commit id"
    else
      (match checkout ~base_path ~repository_id with
       | Error detail -> Unavailable ("repository " ^ repository_id ^ " cannot be read: " ^ detail)
       | Ok (cwd, head) ->
         if not (reached ~cwd ~head commit) then Not_allowed "commit is not on the default branch"
         else
           (match git ~cwd [ "cat-file"; "blob"; commit ^ ":" ^ path ] with
            | Error _ -> Not_allowed ("path " ^ path ^ " is not a file at that commit")
            | Ok bytes ->
              (match Eio_unix.run_in_systhread (fun () -> Lane_addon_store.write_blob store bytes) with
               | Error detail -> Unavailable ("the file could not be retained: " ^ detail)
               | Ok { Lane_addon_types.sha256 = None; _ } -> Unavailable "the retained file has no digest"
               | Ok { Lane_addon_types.sha256 = Some sha256; _ } ->
                 let encoding, content =
                   if String.is_valid_utf_8 bytes then "utf-8", bytes else "base64", Base64.encode_string bytes
                 in
                 Page
                   (`Assoc
                      [ "status", `String "file"; "source_id", `String source_id; "commit", `String commit
                      ; "path", `String path; "encoding", `String encoding; "content", `String content
                      ; "bytes", `Int (String.length bytes); "sha256", `String sha256 ]))))
