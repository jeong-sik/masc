(** What a sandbox image is built from, and the tag that names that build.

    A recipe is a directory under [sandbox-images/]: its [Dockerfile], and an
    optional [inputs] file listing, one per line, the repository files its
    [COPY] lines need. Only those files go into the build context.

    A tag is [masc-sandbox-<name>:<UTC build minute>-<input hash>]. The hash
    covers the Dockerfile and every listed input, so a changed recipe gets a
    new tag. The minute is there because the same recipe still installs
    whatever its package mirrors serve that day, so two builds of one recipe
    are two images. A tag names one build: the build command refuses a tag
    that is already in the image store rather than moving it to new content.
    RFC keeper-sandbox-images-have-versions (#38699) §2.2. *)

type input =
  { path : string  (** Relative to the source checkout, as listed in [inputs]. *)
  ; contents : string
  }

type recipe =
  { name : string  (** The directory name under [sandbox-images/]. *)
  ; dockerfile : string
  ; inputs : input list  (** In the order [inputs] lists them. *)
  }

val base_embedded : recipe
(** The [base] recipe as this binary carries it, with no inputs. It is the
    same bytes as [sandbox-images/base/Dockerfile] at build time. *)

type load_error =
  | Invalid_name of string
      (** Not a directory name this layout uses: empty, or a character other
          than [a-z], [0-9] and [-], or a leading [-]. *)
  | Recipe_missing of { path : string }
  | Source_file_outside_source of { path : string }
      (** A recipe Dockerfile or its [inputs] manifest resolves outside the
          selected checkout. *)
  | Input_path_rejected of { listed_in : string; path : string }
      (** Absolute, empty, with a [..] segment, or [Dockerfile] itself: it
          would reach outside the checkout, or land on the recipe in the
          build context. *)
  | Input_outside_source of { listed_in : string; path : string }
      (** The path resolves, through a symbolic link somewhere on it, to a
          file outside the checkout. Docker does not follow such a link out of
          its context, so neither does this. *)
  | Input_missing of { listed_in : string; path : string }
  | Unreadable of { path : string; detail : string }
  | Context_unwritable of { path : string; detail : string }

val load_error_to_string : load_error -> string

val load : source:string -> name:string -> (recipe, load_error) result
(** Read [<source>/sandbox-images/<name>/Dockerfile] and the files its
    [inputs] lists, relative to [source]. A recipe with no [inputs] file has
    no inputs. Every file is resolved inside the checkout before it is read;
    the resolved regular file is opened with ownership-boundary and inode
    checks, so replacing a link during the read cannot substitute another
    file. *)

val tag_hash_prefix_length : int
(** How many hex digits of {!inputs_sha256} the tag carries. The full hash is
    in the [masc.sandbox.inputs_sha256] label. *)

val inputs_sha256 : recipe -> string
(** Lowercase hex SHA-256 over the Dockerfile and each input's path and
    contents, every part framed by its length so no two different recipes can
    produce the same byte stream. *)

val repository : recipe -> string
(** [masc-sandbox-<name>]. *)

val tag : built_at:float -> recipe -> string
(** [built_at] is Unix time; only its UTC minute appears in the tag. *)

val version : built_at:float -> recipe -> string
(** The part of {!tag} after the colon. *)

val labels : version:string -> built_at:float -> recipe -> (string * string) list
(** The OCI [version] and [created] annotations, plus
    [masc.sandbox.recipe] and [masc.sandbox.inputs_sha256]. [version] is the
    tag's own version part: {!version} for a computed tag, the tag as given
    when the caller named one. *)

val write_context : dir:string -> recipe -> (string, load_error) result
(** Write the recipe's Dockerfile and inputs under [dir], each input at its
    listed path, and answer the Dockerfile's path. [dir] must exist and is the
    caller's to remove. *)
