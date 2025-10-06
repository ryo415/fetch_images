"""Command line interface for downloading images from creator platforms."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Iterable, List

from .clients import FanboxClient, FantiaClient, UnsupportedURLError


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download images from Fantia and Pixiv Fanbox posts.",
    )
    parser.add_argument(
        "urls",
        nargs="+",
        help="One or more Fantia/Fanbox post URLs to download images from.",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("downloads"),
        help="Directory where images will be stored (default: ./downloads).",
    )
    parser.add_argument(
        "--fantia-session",
        default=os.getenv("FANTIA_SESSION"),
        help="Session ID for Fantia (defaults to FANTIA_SESSION env variable).",
    )
    parser.add_argument(
        "--fanbox-session",
        default=os.getenv("FANBOX_SESSION"),
        help="FANBOXSESSID cookie value (defaults to FANBOX_SESSION env variable).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite files if they already exist.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List the files that would be downloaded without saving them.",
    )
    return parser


def _create_clients(args: argparse.Namespace) -> List:
    fantia_client = FantiaClient(session_id=args.fantia_session)
    fanbox_client = FanboxClient(session_id=args.fanbox_session)
    return [fantia_client, fanbox_client]


def _handle_download(url: str, clients: Iterable, output_dir: Path, *, overwrite: bool, dry_run: bool) -> int:
    for client in clients:
        if client.supports_url(url):
            result = client.download_images(url, output_dir, overwrite=overwrite, dry_run=dry_run)
            if result.downloaded:
                print(f"Downloaded {len(result.downloaded)} file(s) from {url}")
            elif result.skipped and not dry_run:
                print(f"Skipped {len(result.skipped)} existing file(s) for {url}")
            elif dry_run:
                print(f"Dry run: would download {len(result.planned)} file(s) from {url}")
            else:
                print(f"No downloadable images found for {url}")
            return 0
    raise UnsupportedURLError(url)


def main(argv: List[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    output_dir: Path = args.output.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    clients = _create_clients(args)
    exit_code = 0
    for url in args.urls:
        try:
            _handle_download(url, clients, output_dir, overwrite=args.overwrite, dry_run=args.dry_run)
        except UnsupportedURLError as exc:
            parser.error(str(exc))
        except Exception as exc:  # pragma: no cover - defensive
            print(f"Error while processing {url}: {exc}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
