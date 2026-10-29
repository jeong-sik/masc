(* Replays the stored board posts through the recipient resolution of
   RFC-at-name-resolves-to-declared-recipient (section 7) and lists the posts
   whose recorded addressees change.

   Same code as the write path, deliberately: the names come from
   [Board_addressing.parse] and the shape check and the sorting from
   [Recipient_resolution]. A replay that wrote them again would measure itself.

   The declaration is the one part that differs. Here it is read from the
   Keeper settings, [keepers/<name>.toml] with [mention_targets] under
   [keeper], and a Keeper's name counts as its own alias. The write path will
   read persisted Keeper metadata. Both are the Keeper's declaration, but they
   are two readers, and these numbers are about the settings.

   Board posts are internal and the output carries their titles. It is for the
   operator's terminal and is not meant to be committed.

   Usage:
     recipient_replay --keepers <dir of keeper .toml files> --posts <board_posts.jsonl> *)

module Candidate = Recipient_resolution.Candidate

type keeper =
  { name : string;
    aliases : string list }

type failure = Ambiguous_alias of string * string list

let fold = String.lowercase_ascii
let mention_targets_path = [ "keeper"; "mention_targets" ]

let read_keeper path =
  let name = Filename.remove_extension (Filename.basename path) in
  match Otoml.Parser.from_file_result path with
  | Error detail -> Error (Printf.sprintf "%s: %s" path detail)
  | Ok toml ->
    if not (Otoml.path_exists toml mention_targets_path)
    then Ok { name; aliases = [] }
    else
      Otoml.find_result toml (Otoml.get_array Otoml.get_string) mention_targets_path
      |> Result.map (fun aliases -> { name; aliases })
      |> Result.map_error (fun detail -> Printf.sprintf "%s: %s" path detail)

let read_keepers dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun file -> Filename.check_suffix file ".toml")
  |> List.sort String.compare
  |> List.fold_left
       (fun keepers file ->
          match keepers, read_keeper (Filename.concat dir file) with
          | (Error _ as failed), _ -> failed
          | Ok _, Error detail -> Error detail
          | Ok keepers, Ok keeper -> Ok (keeper :: keepers))
       (Ok [])
  |> Result.map List.rev

(* A Keeper's own name is answered first. Otherwise the Keepers that list the
   name as an alias answer, and two of them are a failure, as the alias lookup
   of the write path treats them. *)
let declared keepers candidate =
  let wanted = fold (Candidate.to_string candidate) in
  match List.find_opt (fun keeper -> String.equal (fold keeper.name) wanted) keepers with
  | Some keeper -> Ok (Some keeper.name)
  | None ->
    let claims keeper =
      List.exists (fun alias -> String.equal (fold alias) wanted) keeper.aliases
    in
    (match List.filter claims keepers with
     | [] -> Ok None
     | [ keeper ] -> Ok (Some keeper.name)
     | _ :: _ :: _ as claimants ->
       Error (Ambiguous_alias (wanted, List.map (fun keeper -> keeper.name) claimants)))

type post =
  { id : string;
    author : string;
    title : string;
    body : string;
    recorded : string list }

(* The record shape is the one lib/board_types writes. A line the replay cannot
   read is counted and reported, not skipped quietly. *)
let post_of_line line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ -> None
  | json ->
    let open Yojson.Safe.Util in
    let text key = Option.value ~default:"" (to_string_option (member key json)) in
    let recorded =
      match member "audience" json with
      | `Assoc _ as audience ->
        (match to_string_option (member "kind" audience) with
         | Some "targets" ->
           List.filter_map to_string_option (to_list (member "targets" audience))
         | Some _ | None -> [])
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
    in
    Some
      { id = text "id";
        author = text "author";
        title = text "title";
        body = text "body";
        recorded }

(* What the board write path reads: the title and the body, one per line. *)
let address_text post =
  String.concat "\n"
    (List.filter (fun value -> not (String.equal (String.trim value) "")) [ post.title; post.body ])

let candidates_of_text text =
  match Board_addressing.parse text with
  | Board_addressing.Raw_targets names -> List.filter_map Candidate.of_string names
  | Board_addressing.No_explicit_address
  | Board_addressing.Broadcast_all
  | Board_addressing.Unsupported_broadcast _ -> []

(* What the declaration says a recorded name is: [None] when it is no longer a
   recipient, because it is not shaped like a name, is not declared, or the
   lookup failed. *)
let recipient_of_recorded keepers name =
  match Candidate.of_string name with
  | None -> None
  | Some candidate ->
    (match declared keepers candidate with
     | Ok recipient -> recipient
     | Error (Ambiguous_alias _) -> None)

type verdict =
  | Unchanged
  | Leaves_targets
  | Narrows
  | Differs
  | Lookup_failed of failure

let verdict_label = function
  | Unchanged -> "unchanged"
  | Leaves_targets -> "leaves-targets"
  | Narrows -> "narrows"
  | Differs -> "differs"
  | Lookup_failed (Ambiguous_alias (alias, claimants)) ->
    Printf.sprintf "lookup-failed(%s is listed by %s)" alias (String.concat "," claimants)

let same_set left right =
  List.equal String.equal (List.sort_uniq String.compare left) (List.sort_uniq String.compare right)

type replayed =
  { post : post;
    verdict : verdict;
    recipients : string list;
    unresolved : string list;
    lost : string list }

let replay keepers post =
  let resolved =
    Recipient_resolution.resolve ~equal:String.equal ~declared:(declared keepers)
      (candidates_of_text (address_text post))
  in
  let kept = List.filter_map (recipient_of_recorded keepers) post.recorded in
  let lost =
    List.filter (fun name -> Option.is_none (recipient_of_recorded keepers name)) post.recorded
  in
  match resolved with
  | Error failure ->
    { post; verdict = Lookup_failed failure; recipients = []; unresolved = []; lost }
  | Ok { Recipient_resolution.recipients; unresolved } ->
    let verdict =
      if not (same_set kept recipients) then Differs
      else if lost = [] then Unchanged
      else if recipients = [] then Leaves_targets
      else Narrows
    in
    { post; verdict; recipients; unresolved; lost }

let one_line value =
  String.map (function '\t' | '\n' | '\r' -> ' ' | character -> character) value

let list_field values = "[" ^ String.concat "," values ^ "]"

let print_replayed replayed =
  Printf.printf "%s\t%s\t%s\trecorded=%s\trecipients=%s\tunresolved=%s\tlost=%s\t%s\n"
    (verdict_label replayed.verdict) replayed.post.id replayed.post.author
    (list_field replayed.post.recorded) (list_field replayed.recipients)
    (list_field replayed.unresolved) (list_field replayed.lost)
    (one_line replayed.post.title)

let print_ambiguous_aliases keepers =
  let claimants = Hashtbl.create 64 in
  List.iter
    (fun keeper ->
       List.iter
         (fun alias ->
            let key = fold alias in
            let seen = Option.value ~default:[] (Hashtbl.find_opt claimants key) in
            Hashtbl.replace claimants key (keeper.name :: seen))
         (List.sort_uniq String.compare keeper.aliases))
    keepers;
  Hashtbl.iter
    (fun alias names ->
       match names with
       | _ :: _ :: _ -> Printf.printf "# alias %S is listed by %s\n" alias (String.concat ", " names)
       | [] | [ _ ] -> ())
    claimants

let read_lines path = In_channel.with_open_text path In_channel.input_lines

let run ~keepers_dir ~posts_file =
  match read_keepers keepers_dir with
  | Error detail ->
    prerr_endline detail;
    2
  | Ok keepers ->
    let lines = List.filter (fun line -> not (String.equal (String.trim line) "")) (read_lines posts_file) in
    let posts = List.filter_map post_of_line lines in
    let unreadable = List.length lines - List.length posts in
    Printf.printf "# keepers=%d posts=%d unreadable_lines=%d\n" (List.length keepers)
      (List.length posts) unreadable;
    print_ambiguous_aliases keepers;
    let addressed = List.filter (fun post -> post.recorded <> []) posts in
    let replayed = List.map (replay keepers) addressed in
    List.iter (fun entry -> if entry.verdict <> Unchanged then print_replayed entry) replayed;
    let count verdict =
      List.length (List.filter (fun entry -> entry.verdict = verdict) replayed)
    in
    let failed =
      List.length
        (List.filter
           (fun entry ->
              match entry.verdict with
              | Lookup_failed _ -> true
              | Unchanged | Leaves_targets | Narrows | Differs -> false)
           replayed)
    in
    Printf.printf "# posts with recorded targets=%d\n" (List.length addressed);
    List.iter
      (fun verdict -> Printf.printf "# %s=%d\n" (verdict_label verdict) (count verdict))
      [ Unchanged; Leaves_targets; Narrows; Differs ];
    Printf.printf "# lookup-failed=%d\n" failed;
    let lost_posts = Hashtbl.create 64 in
    List.iter
      (fun entry ->
         List.iter
           (fun name ->
              Hashtbl.replace lost_posts name
                (1 + Option.value ~default:0 (Hashtbl.find_opt lost_posts name)))
           (List.sort_uniq String.compare entry.lost))
      replayed;
    Hashtbl.to_seq lost_posts
    |> List.of_seq
    |> List.sort (fun (_, left) (_, right) -> Int.compare right left)
    |> List.iter (fun (name, posts) -> Printf.printf "# lost name %s in %d posts\n" name posts);
    0

let () =
  let keepers_dir = ref "" in
  let posts_file = ref "" in
  let usage = "recipient_replay --keepers <dir of keeper .toml files> --posts <board_posts.jsonl>" in
  Arg.parse
    [ "--keepers", Arg.Set_string keepers_dir, "DIR  Keeper settings, one <name>.toml each";
      "--posts", Arg.Set_string posts_file, "FILE  board_posts.jsonl" ]
    (fun argument -> raise (Arg.Bad ("unexpected argument " ^ argument)))
    usage;
  if String.equal !keepers_dir "" || String.equal !posts_file "" then (
    prerr_endline usage;
    exit 2);
  exit (run ~keepers_dir:!keepers_dir ~posts_file:!posts_file)
