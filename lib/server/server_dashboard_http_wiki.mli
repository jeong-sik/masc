(** Contract 1 — Wiki HTTP API ([/api/v1/wiki*]).

    Thin server projection over {!Tool_wiki}, {!Wiki_page}, {!Wiki_page_name},
    {!Wiki_graph}, {!Wiki_link}, {!Wiki_lint}, {!Wiki_log}, {!Wiki_rank},
    {!Wiki_sources}, and {!Wiki_journal}. Zero duplicate domain logic and zero
    hardcoded paths. *)

type sort_order =
  | Sort_title
  | Sort_updated
  | Sort_rank

val sort_order_of_string : string -> sort_order option

type duplicate_title_candidate =
  { page_a : string
  ; title_a : string
  ; page_b : string
  ; title_b : string
  ; reason : string
  }

val detect_duplicate_titles :
  (string * string) list -> duplicate_title_candidate list
(** Pure duplicate and near-duplicate title detector over [(slug, title)] pairs.
    Detects exact case/whitespace-normalized title duplicates and high token
    Jaccard overlap via {!Wiki_rank.terms}. *)

val list_json :
  ?now:float ->
  ?tag:string ->
  ?source:Wiki_page.wiki_source ->
  ?sort:sort_order ->
  base_path:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/wiki]. *)

val log_json :
  ?now:float ->
  ?limit:int ->
  ?before_idx:int ->
  ?page:string ->
  base_path:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/wiki/log]. *)

val search_json :
  ?now:float ->
  ?limit:int ->
  base_path:string ->
  query:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/wiki/search?q=...]. *)

val lint_json :
  ?now:float ->
  ?page:string ->
  base_path:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/wiki/lint]. *)

val get_page_json :
  ?now:float ->
  base_path:string ->
  slug:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Projection for [GET /api/v1/wiki/:slug]. *)

val put_page_json :
  ?now:float ->
  config:Workspace.config ->
  actor:string ->
  slug:string ->
  body_str:string ->
  unit ->
  (Yojson.Safe.t, Httpun.Status.t * Yojson.Safe.t) result
(** Atomic CAS write for [PUT /api/v1/wiki/:slug]. Uses the shared wiki
    durable lock, {!Fs_compat.save_file_atomic}, {!Wiki_journal.append_log},
    {!Wiki_journal.write_index}, {!Audit_log.log_action}, and SSE
    invalidation. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Register all [/api/v1/wiki*] routes. *)
