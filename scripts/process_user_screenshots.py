#!/usr/bin/env python3
"""Kullanıcı simülatör ekran görüntülerini mağaza boyutlarına dönüştürür."""

from __future__ import annotations

import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = Path("/Users/metinkayan/.cursor/projects/Users-metinkayan-directdrop/assets")

OUT = {
    "iphone": ROOT / "fastlane/screenshots/tr",
    "ipad": ROOT / "fastlane/screenshots/tr",
    "android": ROOT / "store/screenshots/play-store",
    "macos": ROOT / "store/screenshots/mac-app-store",
    "ios_backup": ROOT / "store/screenshots/app-store",
}

# Kaynak → (platform, hedef dosya adı, genişlik, yükseklik)
JOBS: list[tuple[str, str, str, int, int]] = [
    # iPhone 11 Pro Max → App Store 6.5" (1284×2778)
    (
        "Simulator_Screenshot_-_iPhone_11_Pro_Max_-_2026-06-22_at_21.48.59-bd1001db-c8ad-46f4-b377-7fb7a781358b.png",
        "iphone",
        "01_iphone_65_home.png",
        1284,
        2778,
    ),
    (
        "Simulator_Screenshot_-_iPhone_11_Pro_Max_-_2026-06-22_at_21.49.33-330c7826-9441-4eb1-ba17-bd93b2713439.png",
        "iphone",
        "02_iphone_65_transfer.png",
        1284,
        2778,
    ),
    (
        "Simulator_Screenshot_-_iPhone_11_Pro_Max_-_2026-06-22_at_21.49.46-01308428-c8cb-4f86-8b73-2664c19a5d45.png",
        "iphone",
        "03_iphone_65_receive.png",
        1284,
        2778,
    ),
    # iPad Pro 11" → App Store (1668×2388)
    (
        "Simulator_Screenshot_-_iPad_Pro_11-inch__M5__-_2026-06-22_at_21.48.45-68445434-f165-43e9-918b-aa2ae38a1258.png",
        "ipad",
        "01_IPAD_PRO_3GEN_11_home.png",
        1668,
        2388,
    ),
    (
        "Simulator_Screenshot_-_iPad_Pro_11-inch__M5__-_2026-06-22_at_21.49.30-aed65b71-a43e-43a9-9b14-1c303feb9347.png",
        "ipad",
        "02_IPAD_PRO_3GEN_11_transfer.png",
        1668,
        2388,
    ),
    (
        "Simulator_Screenshot_-_iPad_Pro_11-inch__M5__-_2026-06-22_at_21.49.49-c0254903-94bd-43ab-8531-81a1023245f4.png",
        "ipad",
        "03_IPAD_PRO_3GEN_11_send.png",
        1668,
        2388,
    ),
    # Android → Play Store telefon (1080×1920)
    (
        "Screenshot_1782153623-2e5bbc74-485f-4132-8777-49e7ce0b3778.png",
        "android",
        "01_home.png",
        1080,
        1920,
    ),
    (
        "Screenshot_1782153726-efe50b78-6271-4aaf-beda-760bdb24f7e9.png",
        "android",
        "02_connection_request.png",
        1080,
        1920,
    ),
    (
        "Screenshot_1782153671-9e7fa3c0-3cc3-42ea-9094-ba0e58524c82.png",
        "android",
        "03_transfer.png",
        1080,
        1920,
    ),
    (
        "Screenshot_1782153759-1312187a-82fc-40d8-a046-762517d817e2.png",
        "android",
        "04_receive.png",
        1080,
        1920,
    ),
    # macOS → Mac App Store (1280×800)
    (
        "Ekran_Resmi_2026-06-22_21.44.12-5fb2d8ab-ab82-4114-a9d6-e7359419049c.png",
        "macos",
        "01_home.png",
        1280,
        800,
    ),
    (
        "Ekran_Resmi_2026-06-22_21.41.50-0d59ed1c-5224-4dfc-8e24-4a8dbb949e79.png",
        "macos",
        "02_transfer.png",
        1280,
        800,
    ),
]


def fit_and_pad(src: Image.Image, width: int, height: int, bg=(248, 249, 252)) -> Image.Image:
    canvas = Image.new("RGB", (width, height), bg)
    ratio = min(width / src.width, height / src.height)
    new_size = (max(1, int(src.width * ratio)), max(1, int(src.height * ratio)))
    resized = src.convert("RGB").resize(new_size, Image.Resampling.LANCZOS)
    x = (width - new_size[0]) // 2
    y = (height - new_size[1]) // 2
    canvas.paste(resized, (x, y))
    return canvas


def main() -> None:
    for out_dir in OUT.values():
        out_dir.mkdir(parents=True, exist_ok=True)

    # Eski mockup görselleri temizle
    for pattern in ("*.png",):
        for folder in (OUT["iphone"], OUT["ios_backup"]):
            for old in folder.glob(pattern):
                old.unlink(missing_ok=True)
    shutil.rmtree(ROOT / "fastlane/screenshots/tr-TR", ignore_errors=True)

    for src_name, platform, dst_name, w, h in JOBS:
        src = ASSETS / src_name
        if not src.exists():
            raise FileNotFoundError(f"Kaynak bulunamadı: {src}")
        img = Image.open(src)
        out = fit_and_pad(img, w, h)
        dest = OUT[platform] / dst_name
        out.save(dest, format="PNG", optimize=True)
        print(f"{platform:7} {dst_name:40} ← {src_name[:50]}… → {w}×{h}")

        if platform == "iphone":
            shutil.copy2(dest, OUT["ios_backup"] / dst_name)

    print("\nTamamlandı.")


if __name__ == "__main__":
    main()
