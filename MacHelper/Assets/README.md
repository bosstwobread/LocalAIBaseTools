# MacHelper app icon

`AppIcon.png` is the editable source artwork. `AppIcon.icns` contains the native
macOS icon sizes and is copied into MacHelper.app before code signing.

Regenerate the native icon with:

```sh
python3 scripts/build-app-icon.py
```

The app build runs that command automatically. Keep the source PNG's alpha so
the rounded tile has transparent outer corners.

Created using the built-in imagegen tool on November 15, 2026.

Generation prompt:

> Design a polished macOS app icon for MacHelper, a friendly local AI tool hub. One bold ivory modular hub symbol, formed from softly rounded interlocking blocks, centered on a rich cobalt blue squircle tile with subtle depth and gentle studio highlights. The symbol should feel like tools connecting together, with a small cyan central inset. Minimal, confident silhouette, readable at 32 pixels. Front view, square canvas, generous safe margins. Transparent outside the rounded tile. No text, no letters, no extra badges, no mockup, no border around the canvas, no recognizable existing brand logos.
