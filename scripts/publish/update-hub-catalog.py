#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def load(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or int(data.get("schemaVersion", 0)) < 2:
        raise SystemExit("catalog must use schemaVersion >= 2")
    return data


def save(path: Path, data: dict) -> None:
    data["catalogVersion"] = int(data.get("catalogVersion", 0)) + 1
    data["updatedAt"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--catalog", type=Path, required=True)
    p.add_argument("--remote-catalog-url")
    sub = p.add_subparsers(dest="kind", required=True)

    mod = sub.add_parser("mod")
    mod.add_argument("--profile-id", required=True)
    mod.add_argument("--channel", choices=("stable", "beta"), required=True)
    mod.add_argument("--version", required=True)
    mod.add_argument("--url", required=True)
    mod.add_argument("--sha256", required=True)
    mod.add_argument("--bytes", type=int, required=True)
    mod.add_argument("--min-hub-version", default="0.1.0")
    mod.add_argument("--release-notes", default="")

    hub = sub.add_parser("hub")
    hub.add_argument("--channel", choices=("stable", "beta"), required=True)
    hub.add_argument("--version", required=True)
    hub.add_argument("--build", type=int, required=True)
    hub.add_argument("--url", required=True)
    hub.add_argument("--sha256", required=True)
    hub.add_argument("--bytes", type=int, required=True)
    hub.add_argument("--release-notes", default="")

    launcher = sub.add_parser("launcher")
    launcher.add_argument("--channel", choices=("stable", "beta"), required=True)
    launcher.add_argument("--version", required=True)
    launcher.add_argument("--url", required=True)
    launcher.add_argument("--bridge-schema", type=int, default=2)

    args = p.parse_args()
    data = load(args.catalog)

    if args.remote_catalog_url:
        data["remoteCatalogURL"] = args.remote_catalog_url

    if args.kind == "mod":
        mods = data.setdefault("mods", [])
        target = next((m for m in mods if m.get("profileId") == args.profile_id), None)
        if target is None:
            raise SystemExit(f"profile not found in catalog: {args.profile_id}")
        channels = target.setdefault("channels", {})
        channels[args.channel] = {
            "version": args.version,
            "packageURL": args.url,
            "sha256": args.sha256.lower(),
            "packageBytes": args.bytes,
            "minHubVersion": args.min_hub_version,
            "releaseNotes": args.release_notes,
        }
    elif args.kind == "hub":
        hub_entry = data.setdefault("hub", {"name": "Generals Hub"})
        channels = hub_entry.setdefault("channels", {})
        channels[args.channel] = {
            "version": args.version,
            "build": args.build,
            "packageURL": args.url,
            "sha256": args.sha256.lower(),
            "packageBytes": args.bytes,
            "releaseNotes": args.release_notes,
        }
    else:
        launcher_entry = data.setdefault("launcherWeb", {})
        launcher_entry[args.channel] = {
            "version": args.version,
            "indexURL": args.url,
            "bridgeSchema": args.bridge_schema,
        }

    save(args.catalog, data)
    print(args.catalog)


if __name__ == "__main__":
    main()
