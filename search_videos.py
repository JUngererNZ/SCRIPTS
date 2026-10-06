#!/usr/bin/env python3
"""
search_videos.py - Fast, parallel recursive search for video files.
Outputs results to a .txt file with sizes, sorted by size (largest first).
"""

import os
import sys
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

DEFAULT_EXTENSIONS = {".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v"}


def find_videos(root: Path, extensions: set, skip_hidden: bool = True):
    """Walk directory tree and yield matching video file paths."""
    for dirpath, dirnames, filenames in os.walk(root):
        if skip_hidden:
            # prune hidden dirs in-place for speed
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fname in filenames:
            if skip_hidden and fname.startswith("."):
                continue
            if Path(fname).suffix.lower() in extensions:
                yield Path(dirpath) / fname


def file_size_mb(path: Path) -> float:
    try:
        return path.stat().st_size / (1024 * 1024)
    except OSError:
        return -1.0


def main():
    parser = argparse.ArgumentParser(description="Recursively search for video files.")
    parser.add_argument("directory", help="Root directory to search")
    parser.add_argument("-o", "--output", default="video_search_results.txt",
                        help="Output .txt file (default: video_search_results.txt)")
    parser.add_argument("-e", "--ext", nargs="*", default=None,
                        help="Extensions to search for (e.g. .mp4 .mkv). Default: common video formats.")
    parser.add_argument("--min-mb", type=float, default=0.0,
                        help="Minimum file size in MB (default: 0)")
    parser.add_argument("--include-hidden", action="store_true",
                        help="Include hidden files and directories")
    parser.add_argument("--workers", type=int, default=16,
                        help="Threads used for stat() calls (default: 16)")
    args = parser.parse_args()

    root = Path(args.directory).expanduser().resolve()
    if not root.exists() or not root.is_dir():
        print(f"[ERROR] Invalid directory: {root}")
        sys.exit(1)

    extensions = {e.lower() if e.startswith(".") else f".{e.lower()}"
                  for e in (args.ext or DEFAULT_EXTENSIONS)}

    print(f"[*] Searching: {root}")
    print(f"[*] Extensions: {sorted(extensions)}")
    print(f"[*] Min size: {args.min_mb} MB")

    # Phase 1: locate candidate files
    candidates = list(find_videos(root, extensions, skip_hidden=not args.include_hidden))
    print(f"[*] Candidates found: {len(candidates)}")

    # Phase 2: parallel stat() for sizes
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(file_size_mb, p): p for p in candidates}
        for fut in as_completed(futures):
            p = futures[fut]
            size = fut.result()
            if size >= args.min_mb:
                results.append((p, size))

    # Sort by size desc
    results.sort(key=lambda x: x[1], reverse=True)

    # Phase 3: write report
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("Video File Search Report\n")
        f.write(f"Generated : {datetime.now().isoformat(timespec='seconds')}\n")
        f.write(f"Root      : {root}\n")
        f.write(f"Extension : {sorted(extensions)}\n")
        f.write(f"Min size  : {args.min_mb} MB\n")
        f.write(f"Matches   : {len(results)}\n")
        f.write("=" * 100 + "\n\n")
        f.write(f"{'SIZE (MB)':>12}  PATH\n")
        f.write("-" * 100 + "\n")
        for path, size in results:
            f.write(f"{size:>12.2f}  {path}\n")

    total_gb = sum(s for _, s in results) / 1024
    print(f"[OK] {len(results)} file(s) matched. Total size: {total_gb:.2f} GB")
    print(f"[OK] Report written to: {args.output}")


if __name__ == "__main__":
    main()