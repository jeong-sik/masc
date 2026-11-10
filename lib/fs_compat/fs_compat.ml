(** Filesystem Compatibility Layer - Eio-native I/O with fallback

    Provides a unified filesystem API for gradual migration from
    blocking Unix I/O to Eio.Path operations.

    Usage:
    1. At server startup: [Fs_compat.set_fs (Eio.Stdenv.fs env)]
    2. In code: [Fs_compat.load_file path] instead of [open_in ...]

    When fs is not set (non-Eio contexts), falls back to blocking Unix I/O.
    This allows incremental migration without changing all call sites at once.

    @since 2026-02 - Keeper Emergent Identity v2.0
*)

include Fs_compat_base_io
include Fs_compat_capability_write
include Fs_compat_owned_file
include Fs_compat_owned_inventory
include Fs_compat_owned_reader
include Fs_compat_path_ops
include Fs_compat_jsonl_read
include Fs_compat_durable_append
include Fs_compat_private_jsonl_transaction
include Fs_compat_private_jsonl_write
include Fs_compat_private_jsonl_guard
include Fs_compat_private_jsonl_read
include Fs_compat_private_file_update

