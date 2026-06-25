(** GitHub-backed external verifier for the grounding reconciler (RFC-0259 §3.3 P2).

    See the .mli. Every failure path collapses to [Unverifiable] so the
    reconciler never treats an unreachable/ambiguous ref as a contradiction. *)

open Keeper_memory_os_types
module R = Keeper_memory_os_reconcile

(* Map a GitHub state token to external_state. OPEN -> live; MERGED/CLOSED ->
   terminal. Unknown token -> conservative Unverifiable; do not invent a verdict
   for a state we do not model. *)
let external_state_of_token = function
  | "OPEN" -> R.Still_open
  | "MERGED" | "CLOSED" -> R.Terminal
  | _ -> R.Unverifiable
;;

let node_field = function
  | Pr -> Some "pullRequest"
  | Issue -> Some "issue"
  | Task -> None
;;

let parse_state_response ~(kind : external_ref_kind) (body : string) : R.external_state =
  match Yojson.Safe.from_string body with
  | exception _ -> R.Unverifiable
  | json ->
    (try
       let open Yojson.Safe.Util in
       match member "errors" json with
       | `List (_ :: _) -> R.Unverifiable
       | _ ->
         (match node_field kind with
          | None -> R.Unverifiable
          | Some field ->
            let node = json |> member "data" |> member "repository" |> member field in
            (match node with
             | `Null -> R.Unverifiable
             | _ ->
               (match member "state" node with
                | `String state ->
                  external_state_of_token (String.uppercase_ascii (String.trim state))
                | _ -> R.Unverifiable)))
     with
     | _ -> R.Unverifiable)
;;

let repo_owner_name repo =
  match String.split_on_char '/' (String.trim repo) with
  | [ owner; name ] when String.trim owner <> "" && String.trim name <> "" ->
    Some (String.trim owner, String.trim name)
  | _ -> None
;;

let graphql_node_query ~(kind : external_ref_kind) ~(number : int) =
  match kind with
  | Pr -> Some (Printf.sprintf "pullRequest(number:%d){state}" number)
  | Issue -> Some (Printf.sprintf "issue(number:%d){state}" number)
  | Task -> None
;;

let graphql_query ~(owner : string) ~(name : string) ~(kind : external_ref_kind) ~(number : int) =
  graphql_node_query ~kind ~number
  |> Option.map (fun node ->
    Printf.sprintf "query{repository(owner:%S,name:%S){%s}}" owner name node)
;;

let no_token_verify (_ : external_ref) : R.external_state = R.Unverifiable

let verify_external
      ~token
      ~clock
      ~timeout_sec
      ~repo
      (r : external_ref)
  : R.external_state
  =
  match r.kind, repo_owner_name repo, int_of_string_opt r.id with
  | Task, _, _ -> R.Unverifiable
  | (Pr | Issue), None, _ -> R.Unverifiable
  | (Pr | Issue), _, None -> R.Unverifiable
  | (Pr | Issue), Some (owner, name), Some number ->
    (match graphql_query ~owner ~name ~kind:r.kind ~number with
     | None -> R.Unverifiable
     | Some query ->
       let body = `Assoc [ "query", `String query ] |> Yojson.Safe.to_string in
       (match
          Masc_http_client.post_sync
            ~clock
            ~timeout_sec
            ~url:"https://api.github.com/graphql"
            ~headers:
              [ "Authorization", "bearer " ^ String.trim token
              ; "Accept", "application/vnd.github+json"
              ; "User-Agent", "masc-memory-os-reconcile"
              ; "Content-Type", "application/json"
              ]
            ~body
            ()
        with
        | Error _ -> R.Unverifiable
        | Ok (status, response_body) ->
          if status < 200 || status >= 300
          then R.Unverifiable
          else parse_state_response ~kind:r.kind response_body))
;;
