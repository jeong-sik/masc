(** Artifact — phantom-tagged multimodal artifact GADT.

    Cycle 24 / Tier B8.

    {1 What this module is}

    A first-class multimodal artifact carrying:
    - an opaque {!Shared_types.Artifact_id.t} (UUID v7),
    - a phantom-tagged {!kind} (Code/Image/Audio/Doc),
    - a {!Payload.t} (lazy / blob_ref / streaming),
    - free-form JSON metadata,
    - a {!Provenance_stub.t} record.

    The phantom-tag pattern excludes mismatched
    [Code-kind handler over Image-kind artifact] at compile time.
    Existential capture via {!any_kind} and {!any} permits
    homogeneous lists when callers must defer kind dispatch to
    runtime.

    {1 Tag mirror pattern (per B3 / B5)}

    The [\`a kind] GADT cannot be derived directly by [ppx_tla] —
    each constructor specialises ['a] to a distinct phantom
    witness. Tier I8/I9 cover only the 0-param GADT case and
    phantom-only ['a] indices that are caller tags, neither of
    which applies here. Instead, we maintain a regular variant
    {!kind_tag} as a structural mirror with [\[@tla.symbol\]]
    overrides and derive [tla] from it. The hand-written
    {!kind_to_tag} is the SSOT lookup, and OCaml's exhaustiveness
    check catches drift if {!kind_tag} grows but {!kind_to_tag}
    does not.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Kind phantom witnesses}

    Empty-variant declarations (no inhabitants). External call
    sites see them as abstract. Internal use is purely type-level
    — no value of these types is ever constructed. *)

type code
type image
type audio
type doc

(** {1 Kind GADT} *)

type _ kind =
  | Code : code kind
  | Image : image kind
  | Audio : audio kind
  | Doc : doc kind

(** Existential capture so callers can store mixed-kind values
    in a homogeneous list. *)
type any_kind = Any_kind : 'a kind -> any_kind

(** {1 Kind tag (structural mirror, ppx-derivable)}

    The deriver emits [to_tla_symbol], [all_symbols], and
    [all_states] over this type; the GADT projects to the tag via
    {!kind_to_tag}. *)

type kind_tag =
  | Tag_code
  | Tag_image
  | Tag_audio
  | Tag_doc

val all_kind_tags : kind_tag list
(** All four constructors in declaration order. *)

val kind_tag_to_string : kind_tag -> string
(** Lowercase symbol name — [Tag_code → "code"] etc. Mirrors the
    [\[@tla.symbol\]] override layer. *)

val kind_to_tag : 'a kind -> kind_tag
(** Hand-written 1:1 lookup. Compile-time exhaustiveness keeps
    this aligned with {!kind_tag}. *)

val any_kind_to_tag : any_kind -> kind_tag

val kind_to_string : 'a kind -> string

val any_kind_to_string : any_kind -> string

(** {1 Artifact record} *)

type 'a t = {
  id : Shared_types.Artifact_id.t;
  kind : 'a kind;
  payload : Payload.t;
  metadata : Yojson.Safe.t;
  provenance : Provenance_stub.t;
}

(** Existential wrapper. Callers that need to operate over a
    list of artifacts of mixed kinds use this to pack each
    {!t} value. *)
type any = Any : 'a t -> any

val any_id : any -> Shared_types.Artifact_id.t

val any_kind_of : any -> any_kind

val to_json : 'a t -> Yojson.Safe.t
(** Encodes [id], [kind] (as the {!kind_tag} symbol), [payload],
    [metadata], [provenance]. The kind discriminator round-trips
    through {!kind_tag_to_string}. *)

val any_to_json : any -> Yojson.Safe.t
