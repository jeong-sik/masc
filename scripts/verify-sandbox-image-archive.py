"""Verify an exported sandbox archive and identify engine-specific image IDs."""
import argparse
import hashlib
import json
from pathlib import Path
import tarfile


def digest_stream(stream):
    return hashlib.file_digest(stream, "sha256").hexdigest()


def semantic_configuration(config):
    # Classic Docker emits these serialization-only defaults; containerd omits them.
    legacy_defaults = {"AttachStdin": False, "AttachStdout": False, "AttachStderr": False,
                       "OpenStdin": False, "StdinOnce": False, "Tty": False,
                       "Domainname": "", "Hostname": "", "Image": "",
                       # Absent and empty both select default user/workdir.
                       "User": "", "WorkingDir": "",
                       # Null means no entrypoint, volumes or build triggers.
                       "Entrypoint": None, "Volumes": None, "OnBuild": None}
    return {key: value for key, value in config.items()
            if not (key in legacy_defaults and type(value) is type(legacy_defaults[key])
                    and value == legacy_defaults[key])}


def configuration_fingerprint(config):
    raw = json.dumps(semantic_configuration(config), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def blob_path(digest):
    algorithm, separator, value = digest.partition(":")
    if algorithm != "sha256" or not separator or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise ValueError("Unsupported or malformed content digest")
    return "blobs/sha256/" + value


def verify_archive(path):
    with tarfile.open(path, "r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if len(names) != len(set(names)):
            raise ValueError("Archive has duplicate member names")
        by_name = {member.name: member for member in members}

        def read_json(name):
            member = by_name[name]
            if not member.isfile():
                raise ValueError("Archive JSON is not a regular file")
            with archive.extractfile(member) as stream:
                return json.load(stream)

        if read_json("oci-layout") != {"imageLayoutVersion": "1.0.0"}:
            raise ValueError("Unsupported OCI layout")
        index = read_json("index.json")
        if index.get("schemaVersion") != 2 or len(index["manifests"]) != 1:
            raise ValueError("Expected exactly one exported image manifest")
        descriptor = index["manifests"][0]
        if descriptor["mediaType"] != "application/vnd.oci.image.manifest.v1+json":
            raise ValueError("Expected OCI image manifest")
        manifest = read_json(blob_path(descriptor["digest"]))
        if manifest.get("schemaVersion") != 2 or manifest.get("mediaType") != descriptor["mediaType"]:
            raise ValueError("Manifest type differs from its index descriptor")
        config_descriptor = manifest["config"]
        if config_descriptor["mediaType"] != "application/vnd.oci.image.config.v1+json":
            raise ValueError("Expected OCI image configuration")
        config = read_json(blob_path(config_descriptor["digest"]))
        docker = read_json("manifest.json")
        if len(docker) != 1 or docker[0]["Config"] != blob_path(config_descriptor["digest"]):
            raise ValueError("Docker export and OCI manifest disagree on configuration")
        layers = manifest["layers"]
        if any(layer["mediaType"] != "application/vnd.oci.image.layer.v1.tar" for layer in layers):
            raise ValueError("Export must contain uncompressed OCI tar layers")
        if docker[0]["Layers"] != [blob_path(layer["digest"]) for layer in layers]:
            raise ValueError("Docker export and OCI manifest disagree on layers")
        if config["rootfs"]["type"] != "layers" or config["rootfs"]["diff_ids"] != [layer["digest"] for layer in layers]:
            raise ValueError("Configuration diff IDs disagree with uncompressed layers")
        for linked in [descriptor, config_descriptor, *layers]:
            member = by_name[blob_path(linked["digest"])]
            if not member.isfile() or type(linked["size"]) is not int or member.size != linked["size"]:
                raise ValueError("Linked blob size or file type mismatch")
        verified = []
        # Archive order avoids repeatedly seeking backwards through gzip layers.
        for member in members:
            if not member.name.startswith("blobs/sha256/"):
                continue
            if member.isdir():
                continue
            if not member.isfile():
                raise ValueError("Archive blob is not a regular file")
            with archive.extractfile(member) as stream:
                digest = "sha256:" + digest_stream(stream)
            if blob_path(digest) != member.name:
                raise ValueError("Archive blob content digest mismatch")
            verified.append({"digest": digest, "bytes": member.size})
        configuration_keys = sorted(semantic_configuration(config["config"]))
        return {"config_digest": config_descriptor["digest"],
                "manifest_digest": descriptor["digest"],
                "manifest_media_type": descriptor["mediaType"], "manifest_bytes": descriptor["size"],
                "layer_descriptors": layers, "rootfs_diff_ids": config["rootfs"]["diff_ids"],
                "configuration_keys": configuration_keys,
                "configuration_sha256": configuration_fingerprint(config["config"]),
                "architecture": config["architecture"], "os": config["os"],
                "source_commit": config["config"]["Labels"]["org.opencontainers.image.revision"],
                "image_tags": docker[0]["RepoTags"], "verified_blobs": verified}


def verify_inspect(inspect, archive, expected_tag):
    if len(inspect) != 1:
        raise ValueError("Expected one engine inspection")
    image = inspect[0]
    identities = {archive["config_digest"]: "config_digest", archive["manifest_digest"]: "manifest_digest"}
    if image["Id"] not in identities:
        raise ValueError("Engine image ID is not linked to the verified archive")
    if "Descriptor" in image:
        descriptor = image["Descriptor"]
        if (descriptor["digest"] != archive["manifest_digest"]
                or descriptor["mediaType"] != archive["manifest_media_type"]
                or descriptor["size"] != archive["manifest_bytes"]):
            raise ValueError("Engine descriptor differs from the verified archive manifest")
    if (image["RootFS"]["Type"] != "layers" or image["RootFS"]["Layers"] != archive["rootfs_diff_ids"]):
        raise ValueError("Engine root filesystem differs from verified archive")
    if configuration_fingerprint(image["Config"]) != archive["configuration_sha256"]:
        raise ValueError("Engine image configuration differs from archive")
    if image["Architecture"] != archive["architecture"] or image["Os"] != archive["os"]:
        raise ValueError("Engine image platform differs from archive")
    if image["Config"]["Labels"]["org.opencontainers.image.revision"] != archive["source_commit"]:
        raise ValueError("Engine image source label differs from archive")
    if expected_tag not in image["RepoTags"]:
        raise ValueError("Expected tag is absent from engine inspection")
    return {"id": image["Id"], "identity_kind": identities[image["Id"]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--image-tag", required=True)
    parser.add_argument("--destination-inspect", type=Path)
    parser.add_argument("--run-id")
    parser.add_argument("--run-attempt")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.artifact_dir
    result = verify_archive(root / "image.tar.gz")
    if result["source_commit"] != args.expected_commit or result["architecture"] != args.architecture or args.image_tag not in result["image_tags"]:
        raise ValueError("Archive does not match requested source, platform or tag")
    build = verify_inspect(json.loads((root / "image-inspect.json").read_text()), result, args.image_tag)
    result.update(schema="masc.sandbox-image-artifact.v1", image_tag=args.image_tag,
                  build_engine_id=build["id"], build_engine_identity_kind=build["identity_kind"],
                  run_id=args.run_id, run_attempt=args.run_attempt)
    if args.destination_inspect:
        result["destination"] = verify_inspect(json.loads(args.destination_inspect.read_text()), result, args.image_tag)
    result["files"] = {}
    for name in ["image.tar.gz", "image-inspect.json", "Dockerfile", "proof/receipt.json"]:
        with (root / name).open("rb") as stream:
            digest = digest_stream(stream)
        result["files"][name] = {"bytes": (root / name).stat().st_size, "sha256": digest}
    with args.output.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps({key: result[key] for key in ["config_digest", "manifest_digest", "build_engine_identity_kind"]}))


if __name__ == "__main__":
    main()
