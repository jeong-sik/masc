(** The workspace precondition a request carries in its headers (#43356).

    Fail-closed: a request whose expected workspace is not the one this
    server serves never reaches its handler, so a refused write changes
    nothing.

    A client that addresses one workspace sends both headers, each holding the
    absolute, canonical path it expects -- the [paths.effective_base_path] and
    [paths.effective_masc_root] that [/health] reports. The server compares
    them as strings with the paths it serves, resolved for that request the
    way [/health] resolves them. A path spelled another way (a trailing slash,
    a symlink) is a different workspace. A request without either header is
    not checked. *)

val expected_base_path_header : string
(** ["x-masc-expected-base-path"]. *)

val expected_masc_root_header : string
(** ["x-masc-expected-masc-root"]. *)

(** The canonical paths of one workspace. *)
type workspace =
  { base_path : string
  ; masc_root : string
  }

type refusal =
  | Invalid_precondition of string
      (** One header without the other, a header given more than once, an
          empty value, or a relative path. The string says which. *)
  | Workspace_mismatch  (** The server serves another workspace. *)
  | Server_booting
      (** The server has no workspace state yet, or has one but is not
          ready. *)

type decision =
  | No_precondition  (** Neither header: the request goes on unchecked. *)
  | Precondition_met
  | Refused of refusal

val parse :
  expected_base_path:string list ->
  expected_masc_root:string list ->
  (workspace option, refusal) result
(** Every value of each header, in order. [Ok None] when neither header is
    given; [Error (Invalid_precondition _)] for a malformed pair, before
    anything about the server is read. *)

val decide : workspace -> served:workspace option -> ready:bool -> decision
(** The expected workspace against the one served, [None] while the server
    has no workspace state. A mismatch is refused before readiness is looked
    at. *)

val refusal_code : refusal -> string
(** The [code] a refusal carries in its [Server_refusal] body:
    ["invalid_workspace_precondition"], ["workspace_precondition_failed"] or
    ["server_booting"]. Clients branch on it. *)

val refusal_message : refusal -> string
(** The sentence a person reads. It names no server path. *)
