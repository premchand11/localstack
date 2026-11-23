#!/usr/bin/env python3
"""Print config.yml as JSON. Supports the small subset used by this repo."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SECTIONS = (
    "buckets",
    "queues",
    "topics",
    "tables",
    "secrets",
    "event_buses",
    "event_rules",
    "lambdas",
    "kinesis_streams",
)

NAME_RE = {
    "buckets": re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"),
    "queues": re.compile(r"^[A-Za-z0-9_-]{1,80}$"),
    "topics": re.compile(r"^[A-Za-z0-9_-]{1,256}$"),
    "tables": re.compile(r"^[A-Za-z0-9_.-]{3,255}$"),
    "secrets": re.compile(r"^[A-Za-z0-9/_+=.@-]{1,512}$"),
    "event_buses": re.compile(r"^[A-Za-z0-9._-]{1,256}$"),
    "event_rules": re.compile(r"^[A-Za-z0-9._-]{1,64}$"),
    "lambdas": re.compile(r"^[A-Za-z0-9_-]{1,64}$"),
    "kinesis_streams": re.compile(r"^[A-Za-z0-9_.-]{1,128}$"),
}

ROOT = Path(__file__).resolve().parents[1]


def parse(text: str) -> dict:
    lines = []
    for raw in text.replace("\r\n", "\n").split("\n"):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        content = raw.strip()
        if " #" in content:
            content = content.split(" #", 1)[0].rstrip()
        lines.append((indent, content))

    region = "ap-south-1"
    data = {name: [] for name in SECTIONS}
    section = None
    current: dict | None = None

    def flush() -> None:
        nonlocal current
        if current is None:
            return
        if "name" not in current:
            raise SystemExit(f"missing name in {section} entry: {current}")
        data[section].append(current)
        current = None

    for indent, content in lines:
        if content.startswith("region:"):
            flush()
            section = None
            region = content.split(":", 1)[1].strip().strip("'\"")
            continue
        if content.endswith(":") and content[:-1] in SECTIONS:
            flush()
            section = content[:-1]
            continue
        if section and content.startswith("- "):
            flush()
            body = content[2:].strip()
            current = {}
            if body.startswith("name:"):
                current["name"] = body.split(":", 1)[1].strip().strip("'\"")
            elif ":" not in body:
                current["name"] = body.strip("'\"")
            else:
                key, value = body.split(":", 1)
                current[key.strip()] = value.strip().strip("'\"")
            continue
        if section and current is not None and indent > 0 and ":" in content:
            key, value = content.split(":", 1)
            current[key.strip()] = value.strip().strip("'\"")
            continue
        raise SystemExit(f"cannot parse config line: {content}")

    flush()

    for section_name, items in data.items():
        names = [item["name"] for item in items]
        if len(names) != len(set(names)):
            raise SystemExit(f"duplicate name in {section_name}")
        pattern = NAME_RE[section_name]
        for item in items:
            if not pattern.fullmatch(item["name"]):
                raise SystemExit(f"invalid {section_name} name: {item['name']}")

    for item in data["tables"]:
        item.setdefault("hash_key", "id")
        item.setdefault("hash_key_type", "S")
        if item["hash_key_type"] not in {"S", "N", "B"}:
            raise SystemExit(f"table {item['name']} hash_key_type must be S, N, or B")

    queue_names = {item["name"] for item in data["queues"]}
    bus_names = {item["name"] for item in data["event_buses"]} | {"default"}

    for item in data["event_rules"]:
        item.setdefault("bus", "default")
        if item["bus"] not in bus_names:
            raise SystemExit(
                f"event_rule {item['name']} references unknown bus {item['bus']}. "
                "Add it under event_buses or use bus: default"
            )
        if "pattern" not in item:
            raise SystemExit(f"event_rule {item['name']} needs pattern")
        target = item.get("target_queue")
        if not target:
            raise SystemExit(f"event_rule {item['name']} needs target_queue")
        if target not in queue_names:
            raise SystemExit(
                f"event_rule {item['name']} target_queue {target} is not listed under queues"
            )

    for item in data["lambdas"]:
        item.setdefault("runtime", "nodejs18.x")
        item.setdefault("handler", "handler.handler")
        item.setdefault("memory", "256")
        item.setdefault("timeout", "30")
        source = item.get("source")
        if not source:
            raise SystemExit(f"lambda {item['name']} needs source")
        if not (ROOT / source).is_dir():
            raise SystemExit(f"lambda {item['name']} source does not exist: {source}")
        queue = item.get("queue")
        if queue and queue not in queue_names:
            raise SystemExit(f"lambda {item['name']} queue {queue} is not listed under queues")

    for item in data["kinesis_streams"]:
        shards = item.get("shards", "1")
        try:
            count = int(shards)
        except ValueError as exc:
            raise SystemExit(f"kinesis stream {item['name']} shards must be an integer") from exc
        if count < 1:
            raise SystemExit(f"kinesis stream {item['name']} shards must be >= 1")
        item["shards"] = str(count)

    return {"region": region, **data}


def main() -> None:
    print(json.dumps(parse((ROOT / "config.yml").read_text(encoding="utf-8"))))


if __name__ == "__main__":
    main()
