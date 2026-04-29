(** Server_dashboard_http_link_preview — dashboard
    link-preview HTTP route + extractor helpers.

    External surface (5 entries):
    - {b parser helpers} ({!normalize_request_url},
      {!infer_image_url},
      {!extract_html_preview_fields}) consumed directly by
      [test/test_dashboard_link_preview.ml].
    - {b HTTP route entry} ({!dashboard_link_previews_http_json})
      consumed by
      {!Server_routes_http_routes_dashboard}.
    - {b extractor record} ({!preview_extract}) returned
      by {!extract_html_preview_fields}; the test reaches
      every field unqualified.

    Internal helpers stay private at this boundary
    ([is_http_scheme], [image_extensions],
    [head_fragment_re], [first_head_fragment],
    [meta_content], [title_tag], [resolve_relative_url],
    [cache_payload] type + [cache_*] helpers,
    [list_header_ci], [is_success_status] /
    [is_redirect_status], [https_connector_result],
    [fetch_response], [render_*] / fetch / pipeline
    plumbing). *)

(** {1 Extractor record} *)

type preview_extract = {
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  canonical_url : string option;
  favicon_url : string option;
}
(** Record returned by {!extract_html_preview_fields}.
    Each field is [None] when the source markup did not
    yield the corresponding value. *)

(** {1 URL helpers} *)

val normalize_request_url : string -> (string, string) result
(** Trims, parses, and normalizes a request URL.  Returns
    [Error reason] when the input is empty, missing a host,
    uses a scheme other than http/https, or carries
    userinfo.  On success returns [Ok canonical] with the
    fragment stripped. *)

val infer_image_url : string -> bool
(** Returns [true] when the URL's path ends with one of the
    accepted image extensions
    ([.png] / [.jpg] / [.jpeg] / [.gif] / [.webp] / [.svg]
    / [.avif] / [.bmp]). *)

(** {1 HTML extractor} *)

val extract_html_preview_fields :
  url:string -> string -> preview_extract
(** Parses the [<head>...] of [body] and assembles the
    {!preview_extract} record.  Resolves any relative
    [og:image] / [twitter:image] / [link rel=icon] URLs
    against [url]; falls back through the OpenGraph →
    Twitter → standard meta / [<title>] / [<link>] chain. *)

(** {1 HTTP route entry} *)

val dashboard_link_previews_http_json :
  state:Mcp_server.server_state ->
  args:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Implements the dashboard's link-preview HTTP route.
    Pulls the runtime clock + net handles off [state] (with
    {!Eio_context} fallback), validates the request URL
    via {!normalize_request_url}, fetches the document,
    and returns the JSON envelope on success.  Errors
    surface as [Error message] strings consumed by the
    surrounding HTTP wrapper. *)
