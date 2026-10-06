#!/usr/bin/env python3
"""
search_mp4.py - Recursively search a directory for .mp4 files and log results to a .txt file.
"""

import os
import sys
from datetime import datetime
from pathlib import Path


def search_mp4_files(root_dir: str, output_file: str = "mp4_results.txt") -> int:
    """
    Recursively search `root_dir` for .mp4 files and write results to `output_file`.

    Returns the number of .mp4 files found.
    """
    root = Path(root_dir).expanduser().resolve()

    if not root.exists():
        print(f"[ERROR] Path does not exist: {root}")
        return 0
    if not root.is_dir():
        print(f"[ERROR] Path is not a directory: {root}")
        return 0

    matches = []

    for dirpath, _, filenames in os.walk(root):
        for fname in filenames:
            if fname.lower().endswith(".mp4"):
                full_path = Path(dirpath) / fname
                try:
                    size_mb = full_path.stat().st_size / (1024 * 1024)
                except OSError:
                    size_mb = -1
                matches.append((full_path, size_mb))

    # Write results to file
    with open(output_file, "w", encoding="utf-8") as f:
        f.write(f"MP4 Search Report\n")
        f.write(f"Generated: {datetime.now().isoformat(timespec='seconds')}\n")
        f.write(f"Root Directory: {root}\n")
        f.write(f"Total .mp4 files found: {len(matches)}\n")
        f.write("=" * 80 + "\n\n")

        for path, size_mb in matches:
            if size_mb >= 0:
                f.write(f"{path}\t({size_mb:.2f} MB)\n")
            else:
                f.write(f"{path}\n")

    print(f"[OK] Found {len(matches)} .mp4 file(s). Results written to: {output_file}")
    return len(matches)


if __name__ == "__main__":
    # Usage: python search_mp4.py <directory> [output_file]
    if len(sys.argv) < 2:
        print("Usage: python search_mp4.py <directory> [output_file]")
        sys.exit(1)

    target_dir = sys.argv[1]
    out_file = sys.argv[2] if len(sys.argv) > 2 else "mp4_results.txt"

    search_mp4_files(target_dir, out_file)