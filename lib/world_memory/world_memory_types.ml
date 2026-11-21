open Keeper_memory_os_types

type lifecycle =
  | Working
  | Consolidated
  | Canonical
  | Superseded
  | Molted

let lifecycle_to_string = function
  | Working -> "working"
  | Consolidated -> "consolidated"
  | Canonical -> "canonical"
  | Superseded -> "superseded"
  | Molted -> "molted"
;;

let lifecycle_of_string = function
  | "working" -> Some Working
  | "consolidated" -> Some Consolidated
  | "canonical" -> Some Canonical
  | "superseded" -> Some Superseded
  | "molted" -> Some Molted
  | _ -> None
;;

let is_active_lifecycle = function
  | Working | Consolidated | Canonical -> true
  | Superseded | Molted -> false
;;

type invalid_lifecycle_transition =
  { from : lifecycle
  ; to_ : lifecycle
  ; reason : string
  }

let invalid_lifecycle_transition_to_string { from; to_; reason } =
  Printf.sprintf "invalid world memory lifecycle transition %s -> %s: %s"
    (lifecycle_to_string from) (lifecycle_to_string to_) reason
;;

let transition_lifecycle ~from ~to_ =
  match from, to_ with
  | (Superseded | Molted), _ ->
    Error { from; to_; reason = "terminal world lifecycle state cannot resurrect" }
  | Working, (Consolidated | Canonical | Superseded | Molted) -> Ok to_
  | Working, Working -> Error { from; to_; reason = "no-op lifecycle transition" }
  | Consolidated, (Canonical | Superseded | Molted) -> Ok to_
  | Consolidated, (Working | Consolidated) ->
    Error { from; to_; reason = "world lifecycle cannot regress" }
  | Canonical, (Superseded | Molted) -> Ok to_
  | Canonical, (Working | Consolidated | Canonical) ->
    Error { from; to_; reason = "canonical world fact can only be superseded or molted" }
;;

type edge_kind =
  | Supersedes
  | Refines
  | Contradicts
  | Synthesizes_from

let edge_kind_to_string = function
  | Supersedes -> "supersedes"
  | Refines -> "refines"
  | Contradicts -> "contradicts"
  | Synthesizes_from -> "synthesizes_from"
;;

let edge_kind_of_string = function
  | "supersedes" -> Some Supersedes
  | "refines" -> Some Refines
  | "contradicts" -> Some Contradicts
  | "synthesizes_from" -> Some Synthesizes_from
  | _ -> None
;;

type provenance =
  | Proposed_by of
      { keeper_id : string
      ; source_fact_ids : string list
      }
  | Cross_keeper_synthesized of
      { keeper_ids : string list
      ; source_world_fact_ids : string list
      }

let provenance_to_json = function
  | Proposed_by { keeper_id; source_fact_ids } ->
    `Assoc
      [ "kind", `String "proposed_by"
      ; "keeper_id", `String keeper_id
      ; "source_fact_ids", `List (List.map (fun s -> `String s) source_fact_ids)
      ]
  | Cross_keeper_synthesized { keeper_ids; source_world_fact_ids } ->
    `Assoc
      [ "kind", `String "cross_keeper_synthesized"
      ; "keeper_ids", `List (List.map (fun s -> `String s) keeper_ids)
      ; "source_world_fact_ids", `List (List.map (fun s -> `String s) source_world_fact_ids)
      ]
;;

let decode_strings = function
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String s :: rest -> loop (s :: acc) rest
      | _ -> Error "expected string array"
    in
    loop [] items
  | _ -> Error "expected JSON array"
;;

let provenance_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "proposed_by") ->
       (match List.assoc_opt "keeper_id" fields, List.assoc_opt "source_fact_ids" fields with
        | Some (`String keeper_id), Some ids_json ->
          Result.map
            (fun source_fact_ids -> Proposed_by { keeper_id; source_fact_ids })
            (decode_strings ids_json)
        | _ -> Error "invalid proposed_by provenance")
     | Some (`String "cross_keeper_synthesized") ->
       (match
          List.assoc_opt "keeper_ids" fields, List.assoc_opt "source_world_fact_ids" fields
        with
        | Some keepers_json, Some world_ids_json ->
          Result.bind (decode_strings keepers_json) (fun keeper_ids ->
            Result.map
              (fun source_world_fact_ids ->
                 Cross_keeper_synthesized { keeper_ids; source_world_fact_ids })
              (decode_strings world_ids_json))
        | _ -> Error "invalid cross_keeper_synthesized provenance")
     | _ -> Error "unknown provenance kind")
  | _ -> Error "provenance must be a JSON object"
;;

type world_fact =
  { fact_id : string
  ; claim : string
  ; category : category
  ; facets : string list
  ; scope : string
  ; provenance : provenance
  ; lifecycle : lifecycle
  ; revision : int
  ; created_seq : int
  ; updated_seq : int
  }

let fact_id_of_claim ~scope ~claim =
  let payload = String.trim scope ^ "\n" ^ String.trim claim in
  let hex = Agent_core_sha256.(digest_string payload |> to_hex) in
  "wf-" ^ String.sub hex 0 24
;;

let world_fact_to_json (f : world_fact) =
  `Assoc
    [ "fact_id", `String f.fact_id
    ; "claim", `String f.claim
    ; "category", `String (category_to_string f.category)
    ; "facets", `List (List.map (fun s -> `String s) f.facets)
    ; "scope", `String f.scope
    ; "provenance", provenance_to_json f.provenance
    ; "lifecycle", `String (lifecycle_to_string f.lifecycle)
    ; "revision", `Int f.revision
    ; "created_seq", `Int f.created_seq
    ; "updated_seq", `Int f.updated_seq
    ]
;;

type world_edge =
  { from_fact_id : string
  ; to_fact_id : string
  ; kind : edge_kind
  ; reason : string
  ; created_seq : int
  }

let world_edge_to_json (e : world_edge) =
  `Assoc
    [ "from_fact_id", `String e.from_fact_id
    ; "to_fact_id", `String e.to_fact_id
    ; "kind", `String (edge_kind_to_string e.kind)
    ; "reason", `String e.reason
    ; "created_seq", `Int e.created_seq
    ]
;;

type index_entry_kind =
  | Wiki_page
  | Artifact
  | Mcp_resource

let index_entry_kind_to_string = function
  | Wiki_page -> "wiki_page"
  | Artifact -> "artifact"
  | Mcp_resource -> "mcp_resource"
;;

let index_entry_kind_of_string = function
  | "wiki_page" -> Some Wiki_page
  | "artifact" -> Some Artifact
  | "mcp_resource" -> Some Mcp_resource
  | _ -> None
;;

type index_entry =
  { entry_id : string
  ; kind : index_entry_kind
  ; title : string
  ; uri : string
  ; summary : string
  ; facets : string list
  ; sha256 : string option
  ; updated_seq : int
  }

let index_entry_to_json (e : index_entry) =
  `Assoc
    [ "entry_id", `String e.entry_id
    ; "kind", `String (index_entry_kind_to_string e.kind)
    ; "title", `String e.title
    ; "uri", `String e.uri
    ; "summary", `String e.summary
    ; "facets", `List (List.map (fun s -> `String s) e.facets)
    ; "sha256", Option.fold ~none:`Null ~some:(fun s -> `String s) e.sha256
    ; "updated_seq", `Int e.updated_seq
    ]
;;

type world_digest =
  { digest_revision : int
  ; digest_sha256 : string
  ; fact_count : int
  ; canonical_count : int
  ; wiki_count : int
  ; artifact_count : int
  ; resource_count : int
  ; rendered : string
  }

let world_digest_to_json (d : world_digest) =
  `Assoc
    [ "digest_revision", `Int d.digest_revision
    ; "digest_sha256", `String d.digest_sha256
    ; "fact_count", `Int d.fact_count
    ; "canonical_count", `Int d.canonical_count
    ; "wiki_count", `Int d.wiki_count
    ; "artifact_count", `Int d.artifact_count
    ; "resource_count", `Int d.resource_count
    ; "rendered", `String d.rendered
    ]
;;

type change_event_kind =
  | Fact_upserted
  | Fact_lifecycle_changed
  | Edge_added
  | Index_upserted
  | Digest_committed

let change_event_kind_to_string = function
  | Fact_upserted -> "fact_upserted"
  | Fact_lifecycle_changed -> "fact_lifecycle_changed"
  | Edge_added -> "edge_added"
  | Index_upserted -> "index_upserted"
  | Digest_committed -> "digest_committed"
;;

let change_event_kind_of_string = function
  | "fact_upserted" -> Some Fact_upserted
  | "fact_lifecycle_changed" -> Some Fact_lifecycle_changed
  | "edge_added" -> Some Edge_added
  | "index_upserted" -> Some Index_upserted
  | "digest_committed" -> Some Digest_committed
  | _ -> None
;;

type change_event =
  { seq : int
  ; kind : change_event_kind
  ; target_id : string
  ; summary : string
  ; actor : string
  ; recorded_at : float
  }

let change_event_to_json (ev : change_event) =
  `Assoc
    [ "seq", `Int ev.seq
    ; "kind", `String (change_event_kind_to_string ev.kind)
    ; "target_id", `String ev.target_id
    ; "summary", `String ev.summary
    ; "actor", `String ev.actor
    ; "recorded_at", `Float ev.recorded_at
    ]
;;

type search_hit =
  { entry_type : string
  ; target_id : string
  ; title : string
  ; body : string
  ; score : float
  }

let search_hit_to_json (h : search_hit) =
  `Assoc
    [ "entry_type", `String h.entry_type
    ; "target_id", `String h.target_id
    ; "title", `String h.title
    ; "body", `String h.body
    ; "score", `Float h.score
    ]
;;
