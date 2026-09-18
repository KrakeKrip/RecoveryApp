#!/usr/bin/env python3
"""Create a deleted-file exFAT fixture from a raw/GPT disk image.

This is deliberately a fixture generator, not a general-purpose undelete tool.
It clears the in-use bit on exact root-directory entry sets and clears the
corresponding allocation-bitmap bits. The source image is never modified.
"""

from __future__ import annotations

import argparse
import math
import shutil
import struct
from pathlib import Path


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def u64(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<Q", data, offset)[0]


def cluster_offset(
    partition_offset: int,
    cluster_heap_offset: int,
    bytes_per_sector: int,
    sectors_per_cluster: int,
    cluster: int,
) -> int:
    return partition_offset + (
        cluster_heap_offset + (cluster - 2) * sectors_per_cluster
    ) * bytes_per_sector


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--partition-sector", type=int, default=2048)
    parser.add_argument("--delete", action="append", required=True)
    args = parser.parse_args()

    if args.source.resolve() == args.destination.resolve():
        raise SystemExit("source and destination must differ")
    if args.destination.exists():
        raise SystemExit(f"destination already exists: {args.destination}")

    shutil.copyfile(args.source, args.destination)
    partition_offset = args.partition_sector * 512

    with args.destination.open("r+b") as image:
        image.seek(partition_offset)
        boot = bytearray(image.read(512))
        if boot[3:11] != b"EXFAT   ":
            raise SystemExit("not an exFAT volume at the requested offset")

        bytes_per_sector = 1 << boot[108]
        sectors_per_cluster = 1 << boot[109]
        cluster_size = bytes_per_sector * sectors_per_cluster
        fat_offset = u32(boot, 80)
        cluster_heap_offset = u32(boot, 88)
        root_cluster = u32(boot, 96)

        root_offset = cluster_offset(
            partition_offset,
            cluster_heap_offset,
            bytes_per_sector,
            sectors_per_cluster,
            root_cluster,
        )
        image.seek(root_offset)
        root = bytearray(image.read(cluster_size))

        bitmap_cluster = None
        bitmap_length = None
        entries: list[tuple[str, int, int, int, bool]] = []
        position = 0
        while position + 32 <= len(root):
            entry_type = root[position]
            if entry_type == 0x00:
                break
            if entry_type == 0x81:
                bitmap_cluster = u32(root, position + 20)
                bitmap_length = u64(root, position + 24)
                position += 32
                continue
            if entry_type != 0x85:
                position += 32
                continue

            secondary_count = root[position + 1]
            set_end = position + (secondary_count + 1) * 32
            stream_offset = position + 32
            stream = root[stream_offset : stream_offset + 32]
            if stream[0] != 0xC0:
                position = set_end
                continue

            name_length = stream[3]
            first_cluster = u32(stream, 20)
            data_length = u64(stream, 24)
            contiguous = bool(stream[1] & 0x02)
            name_bytes = bytearray()
            cursor = stream_offset + 32
            while cursor < set_end and len(name_bytes) < name_length * 2:
                if root[cursor] == 0xC1:
                    name_bytes.extend(root[cursor + 2 : cursor + 32])
                cursor += 32
            name = bytes(name_bytes[: name_length * 2]).decode("utf-16le")
            entries.append((name, position, first_cluster, data_length, contiguous))
            position = set_end

        if bitmap_cluster is None or bitmap_length is None:
            raise SystemExit("allocation bitmap not found")

        bitmap_offset = cluster_offset(
            partition_offset,
            cluster_heap_offset,
            bytes_per_sector,
            sectors_per_cluster,
            bitmap_cluster,
        )
        image.seek(bitmap_offset)
        bitmap = bytearray(image.read(bitmap_length))

        by_name = {entry[0]: entry for entry in entries}
        missing = [name for name in args.delete if name not in by_name]
        if missing:
            raise SystemExit(f"entries not found: {', '.join(missing)}")

        for name in args.delete:
            _, entry_offset, first_cluster, data_length, contiguous = by_name[name]
            secondary_count = root[entry_offset + 1]
            for index in range(secondary_count + 1):
                root[entry_offset + index * 32] &= 0x7F

            cluster_count = math.ceil(data_length / cluster_size)
            clusters: list[int] = []
            if contiguous:
                clusters = list(range(first_cluster, first_cluster + cluster_count))
            else:
                cluster = first_cluster
                for _ in range(cluster_count):
                    clusters.append(cluster)
                    fat_entry = partition_offset + fat_offset * bytes_per_sector + cluster * 4
                    image.seek(fat_entry)
                    cluster = struct.unpack("<I", image.read(4))[0] & 0x0FFFFFFF

            for cluster in clusters:
                bit = cluster - 2
                bitmap[bit // 8] &= ~(1 << (bit % 8))

        image.seek(root_offset)
        image.write(root)
        image.seek(bitmap_offset)
        image.write(bitmap)

    print(f"created {args.destination}")
    for name in args.delete:
        print(f"deleted fixture entry: {name}")


if __name__ == "__main__":
    main()
