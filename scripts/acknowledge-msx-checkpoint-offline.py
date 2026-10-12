#!/usr/bin/env python3
"""Offline acknowledgement of one unknown TUI checkpoint intent; never replay effects."""
import argparse
import base64
import datetime
import hashlib
import json
import os
import stat
import uuid

STOPPED_ACK = "all checkpoint writers and TUI clients are stopped and cannot restart"
UNKNOWN_ACK = "acknowledge unknown outcome without replay"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate intent field")
        result[key] = value
    return result


def open_directory(path):
    """Pin every path component without following symlinks."""
    if not os.path.isabs(path) or os.path.realpath(path) != path:
        raise ValueError("workspace paths must be existing canonical absolute paths")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.split("/")[1:]:
            if part:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_intent(directory_fd, filename):
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("intent must be a regular, unaliased file")
        return source.read(), (info.st_dev, info.st_ino)


def acknowledge(args):
    if str(uuid.UUID(args.operation_id)) != args.operation_id:
        raise ValueError("operation ID must be canonical UUID")
    base_fd = open_directory(args.base_path)
    os.close(base_fd)
    root_fd = open_directory(args.masc_root)
    try:
        tui_fd = os.open("tui", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
    finally:
        os.close(root_fd)
    try:
        pending_fd = os.open("checkpoint-pending", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=tui_fd)
        try:
            filename = args.operation_id + ".json"
            raw, identity = read_intent(pending_fd, filename)
            binding = json.loads(raw, object_pairs_hook=unique_object)
            expected = dict(version=1, operation_id=args.operation_id,
                            restore=args.action == "restore", slot=args.slot,
                            base_path=args.base_path, masc_root=args.masc_root)
            if binding != expected or type(binding.get("version")) is not int or type(binding.get("restore")) is not bool:
                raise ValueError("intent does not exactly match supplied workspace, request, action and slot")
            digest = hashlib.sha256(raw).hexdigest()
            diagnosis = dict(binding=binding, intent_sha256=digest, outcome="unknown",
                             receipt="unchanged; no effect completion or worker termination inferred")
            if not args.apply:
                print(json.dumps(diagnosis, indent=2))
                return
            if args.writers_stopped_ack != STOPPED_ACK or args.outcome_ack != UNKNOWN_ACK:
                raise ValueError("apply requires both explicit offline and unknown-outcome acknowledgements")
            if args.intent_sha256 != digest:
                raise ValueError("intent changed since diagnosis or digest was not supplied")
            try:
                os.mkdir("checkpoint-acknowledged", mode=0o700, dir_fd=tui_fd)
                os.fsync(tui_fd)
            except FileExistsError:
                pass
            archive_fd = os.open("checkpoint-acknowledged", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=tui_fd)
            try:
                record = dict(diagnosis, original_intent_base64=base64.b64encode(raw).decode("ascii"),
                              acknowledged_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                              operator_uid=os.getuid(), writers_stopped_ack=STOPPED_ACK,
                              outcome_ack=UNKNOWN_ACK)
                fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=archive_fd)
                with os.fdopen(fd, "w") as archive:
                    json.dump(record, archive, indent=2)
                    archive.write("\n")
                    archive.flush()
                    os.fsync(archive.fileno())
                os.fsync(archive_fd)
                current, current_identity = read_intent(pending_fd, filename)
                if current != raw or current_identity != identity:
                    raise ValueError("intent changed; backup retained and live gate not removed")
                os.unlink(filename, dir_fd=pending_fd)
                os.fsync(pending_fd)
            finally:
                os.close(archive_fd)
            print(json.dumps(dict(diagnosis, local_gate="acknowledged offline", next_step=
                "restart with verified workspace, read current machine, then explicitly rearm; never replay this operation"), indent=2))
        finally:
            os.close(pending_fd)
    finally:
        os.close(tui_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base-path", "masc-root", "operation-id", "slot"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--action", required=True, choices=("save", "restore"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--intent-sha256")
    parser.add_argument("--writers-stopped-ack")
    parser.add_argument("--outcome-ack")
    args = parser.parse_args()
    try:
        acknowledge(args)
    except (OSError, ValueError) as error:
        parser.exit(1, "checkpoint acknowledgement refused: " + str(error) + "\n")


if __name__ == "__main__":
    main()
