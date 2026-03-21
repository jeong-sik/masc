(** Social - Moltbook-style social features for MASC

    Implements posts, threaded comments, and voting for agent collaboration.
    Storage is file-based under .masc/social/
*)

(** {1 Types} *)

type post = {
  id: string;
  author: string;
  content: string;
  submolt: string option;
  created_at: float;
  votes: int;
}

type comment = {
  id: string;
  post_id: string;
  parent_id: string option;
  author: string;
  content: string;
  created_at: float;
  votes: int;
}

type vote_direction = Up | Down

type vote_record = {
  voter: string;
  direction: vote_direction;
  voted_at: float;
}

(** {1 ID Generation} *)

let id_nonce = Atomic.make 0

let fresh_id_suffix () =
  Atomic.fetch_and_add id_nonce 1 land 0xFFFFFF

let generate_post_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  Printf.sprintf "post-%d-%06x" ts (fresh_id_suffix ())

let generate_comment_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  Printf.sprintf "cmt-%d-%06x" ts (fresh_id_suffix ())

(** {1 JSON Serialization} *)

let direction_to_string = function
  | Up -> "up"
  | Down -> "down"

let direction_of_string = function
  | "up" -> Ok Up
  | "down" -> Ok Down
  | s -> Error (Printf.sprintf "Unknown vote direction: %s" s)

let post_to_yojson (p : post) : Yojson.Safe.t =
  `Assoc [
    ("id", `String p.id);
    ("author", `String p.author);
    ("content", `String p.content);
    ("submolt", match p.submolt with Some s -> `String s | None -> `Null);
    ("created_at", `Float p.created_at);
    ("votes", `Int p.votes);
  ]

let post_of_yojson (json : Yojson.Safe.t) : (post, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let author = json |> member "author" |> to_string in
    let content = json |> member "content" |> to_string in
    let submolt = match json |> member "submolt" with
      | `Null -> None
      | `String s -> Some s
      | _ -> None
    in
    let created_at = json |> member "created_at" |> to_float in
    let votes = json |> member "votes" |> to_int in
    Ok { id; author; content; submolt; created_at; votes }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse post: %s" (Printexc.to_string e))

let comment_to_yojson (c : comment) : Yojson.Safe.t =
  `Assoc [
    ("id", `String c.id);
    ("post_id", `String c.post_id);
    ("parent_id", match c.parent_id with Some s -> `String s | None -> `Null);
    ("author", `String c.author);
    ("content", `String c.content);
    ("created_at", `Float c.created_at);
    ("votes", `Int c.votes);
  ]

let comment_of_yojson (json : Yojson.Safe.t) : (comment, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let post_id = json |> member "post_id" |> to_string in
    let parent_id = match json |> member "parent_id" with
      | `Null -> None
      | `String s -> Some s
      | _ -> None
    in
    let author = json |> member "author" |> to_string in
    let content = json |> member "content" |> to_string in
    let created_at = json |> member "created_at" |> to_float in
    let votes = json |> member "votes" |> to_int in
    Ok { id; post_id; parent_id; author; content; created_at; votes }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse comment: %s" (Printexc.to_string e))

let vote_record_to_yojson (v : vote_record) : Yojson.Safe.t =
  `Assoc [
    ("voter", `String v.voter);
    ("direction", `String (direction_to_string v.direction));
    ("voted_at", `Float v.voted_at);
  ]

let vote_record_of_yojson (json : Yojson.Safe.t) : (vote_record, string) result =
  let open Yojson.Safe.Util in
  try
    let voter = json |> member "voter" |> to_string in
    let dir_str = json |> member "direction" |> to_string in
    match direction_of_string dir_str with
    | Ok direction ->
        let voted_at = json |> member "voted_at" |> to_float in
        Ok { voter; direction; voted_at }
    | Error e -> Error e
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse vote_record: %s" (Printexc.to_string e))

(** {1 Storage Operations} *)

let masc_dir config =
  Room_utils.masc_dir config

let social_dir config =
  Filename.concat (masc_dir config) "social"

let posts_dir config =
  Filename.concat (social_dir config) "posts"

let comments_dir config =
  Filename.concat (social_dir config) "comments"

let votes_dir config =
  Filename.concat (social_dir config) "votes"

let ensure_dirs config =
  Fs_compat.mkdir_p (social_dir config);
  Fs_compat.mkdir_p (posts_dir config);
  Fs_compat.mkdir_p (comments_dir config);
  Fs_compat.mkdir_p (votes_dir config)

let post_path config post_id =
  Filename.concat (posts_dir config) (post_id ^ ".json")

let comment_path config comment_id =
  Filename.concat (comments_dir config) (comment_id ^ ".json")

let votes_path config ~target_type:_ ~target_id =
  (* target_id already includes type prefix (post-xxx or cmt-xxx) *)
  Filename.concat (votes_dir config) (target_id ^ ".json")

(** Write JSON to file atomically (temp file + rename) *)
let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base = Filename.basename path in
  let tmp_path = Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base (Unix.getpid ())) in
  Fs_compat.save_file tmp_path content;
  Sys.rename tmp_path path

(** Read JSON from file *)
let read_json path =
  match Safe_ops.read_file_safe path with
  | Ok content ->
      (match Safe_ops.parse_json_safe ~context:path content with
       | Ok json -> Some json
       | Error _ -> None)
  | Error _ -> None

(** {1 Post Operations} *)

let create_post config ~author ~content ?submolt () =
  ensure_dirs config;
  let id = generate_post_id () in
  let post : post = {
    id;
    author;
    content;
    submolt;
    created_at = Time_compat.now ();
    votes = 0;
  } in
  let path = post_path config id in
  try
    write_json path (post_to_yojson post);
    Ok post
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to create post: %s" (Printexc.to_string e))

let get_post config ~post_id : (post, string) result =
  let path = post_path config post_id in
  match read_json path with
  | Some json -> post_of_yojson json
  | None -> Error (Printf.sprintf "Post not found: %s" post_id)

let save_post config (post : post) : unit =
  let path = post_path config post.id in
  write_json path (post_to_yojson post)

let list_posts config ?submolt ?(limit=50) () : post list =
  ensure_dirs config;
  let dir = posts_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      let json_files = List.filter (fun f -> Filename.check_suffix f ".json") files in
      let posts : post list = List.filter_map (fun f ->
        let path = Filename.concat dir f in
        match read_json path with
        | Some json ->
            (match post_of_yojson json with
             | Ok p -> Some p
             | Error _ -> None)
        | None -> None
      ) json_files in
      (* Filter by submolt if specified *)
      let filtered : post list = match submolt with
        | None -> posts
        | Some s -> List.filter (fun (p : post) -> p.submolt = Some s) posts
      in
      (* Sort by votes desc, then by created_at desc *)
      let sorted = List.sort (fun (a : post) (b : post) ->
        let cmp = compare b.votes a.votes in
        if cmp <> 0 then cmp
        else compare b.created_at a.created_at
      ) filtered in
      (* Apply limit *)
      let rec take n lst = match n, lst with
        | 0, _ -> []
        | _, [] -> []
        | n, x :: xs -> x :: take (n-1) xs
      in
      take limit sorted

(** {1 Comment Operations} *)

let add_comment config ~post_id ~author ~content ?parent_id () : (comment, string) result =
  ensure_dirs config;
  (* Verify post exists *)
  match get_post config ~post_id with
  | Error e -> Error e
  | Ok _ ->
      let id = generate_comment_id () in
      let comment : comment = {
        id;
        post_id;
        parent_id;
        author;
        content;
        created_at = Time_compat.now ();
        votes = 0;
      } in
      let path = comment_path config id in
      try
        write_json path (comment_to_yojson comment);
        Ok comment
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
        Error (Printf.sprintf "Failed to add comment: %s" (Printexc.to_string e))

let save_comment config (comment : comment) : unit =
  let path = comment_path config comment.id in
  write_json path (comment_to_yojson comment)

let get_comments config ~post_id : comment list =
  ensure_dirs config;
  let dir = comments_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> []
  | Ok files ->
      let json_files = List.filter (fun f -> Filename.check_suffix f ".json") files in
      let comments : comment list = List.filter_map (fun f ->
        let path = Filename.concat dir f in
        match read_json path with
        | Some json ->
            (match comment_of_yojson json with
             | Ok c when c.post_id = post_id -> Some c
             | _ -> None)
        | None -> None
      ) json_files in
      (* Sort by created_at asc *)
      List.sort (fun (a : comment) (b : comment) -> compare a.created_at b.created_at) comments

let get_comments_threaded config ~post_id : (comment * comment list) list =
  let all_comments : comment list = get_comments config ~post_id in
  (* Separate top-level and replies *)
  let top_level = List.filter (fun (c : comment) -> c.parent_id = None) all_comments in
  let replies = List.filter (fun (c : comment) -> c.parent_id <> None) all_comments in
  (* Group replies by parent *)
  List.map (fun (parent : comment) ->
    let children = List.filter (fun (c : comment) -> c.parent_id = Some parent.id) replies in
    (parent, List.sort (fun (a : comment) (b : comment) -> compare a.created_at b.created_at) children)
  ) top_level

(** {1 Voting} *)

(** Execute a function with an exclusive file lock.
    Creates the lock file if it doesn't exist. *)
let with_file_lock path f =
  let lock_path = path ^ ".lock" in
  let fd = Unix.openfile lock_path [Unix.O_CREAT; Unix.O_WRONLY] 0o644 in
  Common.protect ~module_name:"social" ~finally_label:"finalizer" ~finally:(fun () ->
    (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
    Unix.close fd
  ) (fun () ->
    Unix.lockf fd Unix.F_LOCK 0;
    f ()
  )

(** Load votes for a target *)
let load_votes config ~target_type ~target_id : vote_record list =
  let path = votes_path config ~target_type ~target_id in
  match read_json path with
  | Some (`Assoc [("votes", `List votes_json)]) ->
      List.filter_map (fun j ->
        match vote_record_of_yojson j with
        | Ok v -> Some v
        | Error _ -> None
      ) votes_json
  | _ -> []

(** Save votes for a target *)
let save_votes config ~target_type ~target_id votes =
  let path = votes_path config ~target_type ~target_id in
  let json = `Assoc [
    ("votes", `List (List.map vote_record_to_yojson votes))
  ] in
  write_json path json

(** Calculate net score from votes *)
let calculate_score votes =
  List.fold_left (fun acc (v : vote_record) ->
    match v.direction with
    | Up -> acc + 1
    | Down -> acc - 1
  ) 0 votes

let vote config ~voter ~target_type ~target_id ~direction : (int, string) result =
  ensure_dirs config;
  let votes_file = votes_path config ~target_type ~target_id in
  (* Use file lock to prevent race conditions in read-modify-write *)
  with_file_lock votes_file (fun () ->
    let votes = load_votes config ~target_type ~target_id in
    (* Remove any existing vote from this voter *)
    let votes_without_current = List.filter (fun (v : vote_record) -> v.voter <> voter) votes in
    (* Add new vote *)
    let new_vote : vote_record = { voter; direction; voted_at = Time_compat.now () } in
    let new_votes = new_vote :: votes_without_current in
    (* Save votes *)
    save_votes config ~target_type ~target_id new_votes;
    (* Calculate and update the target's vote count *)
    let new_score = calculate_score new_votes in
    (match target_type with
     | `Post ->
         (match get_post config ~post_id:target_id with
          | Ok post ->
              save_post config { post with votes = new_score }
          | Error msg -> Log.Social.info "vote update (post get): %s" msg)
     | `Comment ->
         let dir = comments_dir config in
         (match Safe_ops.list_dir_safe dir with
          | Error msg -> Log.Social.info "vote update (comment list): %s" msg
          | Ok files ->
              List.iter (fun f ->
                let path = Filename.concat dir f in
                match read_json path with
                | Some json ->
                    (match comment_of_yojson json with
                     | Ok c when c.id = target_id ->
                         save_comment config { c with votes = new_score }
                     | _ -> ())
                | None -> ()
              ) (List.filter (fun f -> Filename.check_suffix f ".json") files)));
    Ok new_score
  )

let get_votes config ~target_type ~target_id : int =
  let votes = load_votes config ~target_type ~target_id in
  calculate_score votes
