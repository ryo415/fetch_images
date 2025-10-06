"""Client implementations for different creator platforms."""
from __future__ import annotations

import os
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import unquote, urlparse

import requests


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"}


class UnsupportedURLError(ValueError):
    """Raised when the provided URL cannot be handled by any client."""

    def __init__(self, url: str) -> None:
        super().__init__(f"Unsupported URL: {url}")
        self.url = url


@dataclass
class DownloadResult:
    """Result of a download operation."""

    planned: List[str] = field(default_factory=list)
    downloaded: List[Path] = field(default_factory=list)
    skipped: List[Path] = field(default_factory=list)


class BaseClient:
    """Base class shared by concrete client implementations."""

    platform_name: str = ""
    url_pattern: re.Pattern[str]

    def __init__(self, *, session_id: Optional[str] = None) -> None:
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": "fetch-images/1.0 (+https://github.com/openai/autonomous-agents)",
            }
        )
        self.session_id = session_id

    # --- API hooks -------------------------------------------------
    def supports_url(self, url: str) -> bool:
        return bool(self.url_pattern.search(url))

    def download_images(
        self,
        url: str,
        output_dir: Path,
        *,
        overwrite: bool = False,
        dry_run: bool = False,
    ) -> DownloadResult:
        post_id, api_payload = self._fetch_post_payload(url)
        image_urls = self._extract_image_urls(api_payload)
        result = DownloadResult(planned=list(image_urls))

        if dry_run:
            return result

        post_dir = output_dir / self._make_post_directory_name(post_id, api_payload)
        post_dir.mkdir(parents=True, exist_ok=True)

        for index, image_url in enumerate(image_urls, start=1):
            filename = self._build_filename(image_url, index)
            target_path = post_dir / filename
            if target_path.exists() and not overwrite:
                result.skipped.append(target_path)
                continue

            response = self.session.get(image_url, stream=True, timeout=60)
            response.raise_for_status()
            with target_path.open("wb") as fh:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        fh.write(chunk)
            result.downloaded.append(target_path)
        return result

    # --- Abstract methods -----------------------------------------
    def _fetch_post_payload(self, url: str) -> tuple[str, Dict]:  # pragma: no cover - abstract
        raise NotImplementedError

    def _extract_image_urls(self, payload: Dict) -> List[str]:  # pragma: no cover - abstract
        raise NotImplementedError

    def _make_post_directory_name(self, post_id: str, payload: Dict) -> str:
        raise NotImplementedError

    # --- Utilities -------------------------------------------------
    def _apply_cookies(self, cookies: Dict[str, str]) -> None:
        self.session.cookies.update(cookies)

    def _build_filename(self, image_url: str, index: int) -> str:
        parsed = urlparse(image_url)
        name = Path(unquote(parsed.path)).name
        if not name:
            name = f"image_{index}"
        name = _sanitize_filename(name)
        return f"{index:03d}_{name}"


class FantiaClient(BaseClient):
    platform_name = "fantia"
    url_pattern = re.compile(r"https?://(?:www\.)?fantia\.jp/(?:fanclubs/\d+/)?posts/(?P<id>\d+)")

    API_URL_TEMPLATE = "https://fantia.jp/api/v1/posts/{post_id}"

    def _fetch_post_payload(self, url: str) -> tuple[str, Dict]:
        match = self.url_pattern.search(url)
        if not match:
            raise UnsupportedURLError(url)
        post_id = match.group("id")
        api_url = self.API_URL_TEMPLATE.format(post_id=post_id)
        headers = {
            "Accept": "application/json",
            "Referer": url,
        }
        if self.session_id:
            self._apply_cookies({"_session_id": self.session_id})
        response = self.session.get(api_url, headers=headers, timeout=30)
        response.raise_for_status()
        data = response.json()
        post = data.get("post") or data
        return post_id, post

    def _extract_image_urls(self, payload: Dict) -> List[str]:
        urls = set()
        for key in ("thumb", "cover_image_url", "cover_image"):
            value = payload.get(key)
            if isinstance(value, str) and _looks_like_image_url(value):
                urls.add(value)
        for content in payload.get("post_contents", []) or []:
            urls.update(_collect_image_urls(content))
        for attachment in payload.get("post_attachments", []) or []:
            urls.update(_collect_image_urls(attachment))
        if not urls and isinstance(payload, dict):
            urls.update(_collect_image_urls(payload))
        return list(dict.fromkeys(urls))

    def _make_post_directory_name(self, post_id: str, payload: Dict) -> str:
        title = payload.get("title") or "post"
        fanclub = payload.get("fanclub", {}) or {}
        creator = (
            fanclub.get("fanclub_name")
            or fanclub.get("name")
            or fanclub.get("creator_name")
            or str(fanclub.get("id", "fantia"))
        )
        creator_slug = _slugify(creator)
        title_slug = _slugify(title)
        return f"fantia_{creator_slug}_{post_id}_{title_slug}".strip("_")


class FanboxClient(BaseClient):
    platform_name = "fanbox"
    url_pattern = re.compile(r"https?://(?P<creator>[a-zA-Z0-9_-]+)\.fanbox\.cc/posts/(?P<id>\d+)")
    API_URL = "https://api.fanbox.cc/post.info"

    def _fetch_post_payload(self, url: str) -> tuple[str, Dict]:
        match = self.url_pattern.search(url)
        if not match:
            raise UnsupportedURLError(url)
        post_id = match.group("id")
        creator = match.group("creator")
        headers = {
            "Accept": "application/json, text/plain, */*",
            "Referer": url,
            "Origin": f"https://{creator}.fanbox.cc",
        }
        if self.session_id:
            self._apply_cookies({"FANBOXSESSID": self.session_id})
        params = {"postId": post_id}
        response = self.session.get(self.API_URL, headers=headers, params=params, timeout=30)
        response.raise_for_status()
        data = response.json()
        return post_id, data

    def _extract_image_urls(self, payload: Dict) -> List[str]:
        urls = set()
        body = payload.get("body", {}) or {}
        if isinstance(body, dict):
            urls.update(_collect_image_urls(body))
        if "coverImageUrl" in payload:
            cover = payload.get("coverImageUrl")
            if isinstance(cover, str) and _looks_like_image_url(cover):
                urls.add(cover)
        if "imageMap" in payload:
            urls.update(_collect_image_urls(payload["imageMap"]))
        if not urls:
            urls.update(_collect_image_urls(payload))
        return list(dict.fromkeys(urls))

    def _make_post_directory_name(self, post_id: str, payload: Dict) -> str:
        creator = payload.get("creatorId") or payload.get("user", {}).get("userId") or "fanbox"
        title = payload.get("title") or payload.get("body", {}).get("title") or "post"
        creator_slug = _slugify(creator)
        title_slug = _slugify(title)
        return f"fanbox_{creator_slug}_{post_id}_{title_slug}".strip("_")


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------


def _collect_image_urls(data: object) -> set[str]:
    urls: set[str] = set()
    if isinstance(data, dict):
        for value in data.values():
            urls.update(_collect_image_urls(value))
    elif isinstance(data, list):
        for item in data:
            urls.update(_collect_image_urls(item))
    elif isinstance(data, str) and _looks_like_image_url(data):
        urls.add(data)
    return urls


def _looks_like_image_url(url: str) -> bool:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        return False
    ext = Path(unquote(parsed.path)).suffix.lower()
    return ext in IMAGE_EXTENSIONS


def _slugify(value: str) -> str:
    value = unicodedata.normalize("NFKD", value)
    value = value.strip()
    value = re.sub(r"\s+", "-", value)
    value = re.sub(r"[^a-zA-Z0-9._-]", "", value)
    return value or "post"


def _sanitize_filename(filename: str) -> str:
    filename = filename.replace(os.sep, "_")
    filename = filename.replace("\0", "")
    return filename


__all__ = [
    "FanboxClient",
    "FantiaClient",
    "UnsupportedURLError",
    "DownloadResult",
]
