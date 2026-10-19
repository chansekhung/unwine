# Decant

Free Steam Play for Windows games on Apple Silicon Macs. Install a Windows game in your normal
Mac Steam, and it runs through Decant's free engine, like Proton on a Steam Deck.

<img src="Resources/AppIcon.png" width="96" alt="Decant icon">

## What Decant does

- Downloads a free Wine 11 engine (Gcenx's Sikarugir build) with DXMT, DXVK and the KosmicKrisp
  Vulkan driver.
- Downloads the open Steam bridge parts from [NotProton](https://github.com/NotProtonNot/NotProton)
  and Valve's Windows Steam files, and builds a compatibility tool Mac Steam can use. It never needs
  CrossOver.
- Imports Apple's D3DMetal (Game Porting Toolkit 4) from your own download from Apple, for DirectX 12.
- Reads each game's files to pick the graphics layer: D3DMetal for DirectX 12, DXMT for DirectX 10/11,
  DXVK for DirectX 9.
- Per-game settings: graphics layer, msync, AVX, Metal HUD, MetalFX upscaling, GPTK 4 Metal 4 mode,
  frame cap.
- Updates itself: the engine (when Decant can bridge it), Steam Play signature files, and the app.

## What it needs

- An Apple Silicon Mac with macOS 15 or newer, Rosetta, and Mac Steam.
- Steam Play switched on in Mac Steam, as described by the
  [NotProton project](https://github.com/NotProtonNot/NotProton). Decant never changes Steam.app.

## Honest limits

- Games with kernel anti-cheat (Easy Anti-Cheat, BattlEye, Vanguard and others) do not run online on
  any Mac Wine tool, CrossOver included.
- Some games run in CrossOver and not here: CodeWeavers has a paid team that fixes single games.
- GPTK 4 is an Apple beta. Rosetta 2 is fully supported through macOS 27 only.

## Build

Needs only the Xcode Command Line Tools.

```bash
bash scripts/build.sh      # builds dist/Decant.app
bash scripts/make-dmg.sh   # packs dist/Decant.dmg
```

`tools/steamplay` holds the Wine patch tools (from NotProton, GPL-3.0) and the generator for
`Sources/Decant/SteamPlay/NtdllRecipes.swift`.

## Licence

GPL-3.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for the parts Decant uses and their licences.
