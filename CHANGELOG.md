# What's new in Unwine

What each Unwine version changed for you, in plain words. The newest version is at the top.
Unwine shows this list in its app menu and in Settings. After an update, it opens the list one time.

<!--
How to keep this list. The build reads it, so follow these rules.

1. The newest heading is the app's version. The number of headings is its build number.
   To start the next version, run: scripts/release.sh new 1.0.4
   That adds the heading "1.0.4 · not released yet" at the top.
2. Each time you change something that a player can see, add one "- " line under that heading.
   The build stops when the newest version has no lines.
3. Write simple English (ASD-STE100). Use plain words and active voice. Write one idea in each
   sentence and keep sentences short. If you must use a technical word, say what it means
   immediately after it.
4. Start a line with a **bold name** when the change has a name in the app.
   Put two spaces before "- " to make a sub-line. Text under a heading, before its lines, is
   a short note for the whole version.
5. To make the release, run: scripts/release.sh
   It writes today's date in the heading, builds the app and the DMG, and tells you the
   commands to tag and publish.
-->

## 1.0.3 · not released yet

- **A game and its launcher share one Windows bottle.** (A bottle is the small Windows system that Unwine makes for each game.) Add two programs from one game folder, such as a launcher and its game. Settings that you make in the launcher now go to the game.
  - Did you add a launcher and its game before this version? Unwine puts them into one bottle when it opens. The bottle that it does not need goes to the Trash.
  - If both bottles have saves in them, Unwine does not join them.
- A launcher now starts with the settings of its game. The game that the launcher opens then gets the correct settings.
- **Right-click a game** in your library to play it or to open its settings. For a game that you added, you can also rename it or remove it there.
- **No more crash when a game shares a picture between two DirectX parts.** Romance of the Three Kingdoms XIV is one of these games. Before, it closed or showed only a black screen with music. Now it opens and you can play.
  - The videos in these games stay black, but you hear the sound. Push Esc to skip a video.
- **Chinese, Japanese and Korean text shows correctly** in dialogs and launchers. Before, some of this text showed as empty boxes. Unwine now uses the Mac's own fonts for these languages.

## 1.0.2 · 2026-10-21

- **Add game.** You can now add a Windows program that is not in Steam. Pick its .exe file or its folder. Each program gets its own Windows bottle and its own settings.
  - When you pick a folder, Unwine shows the programs in it. The most likely program is first. Unwine gives the game the name of its folder.
- **Fewer stutters in DirectX 8 and 9 games.** Unwine now makes more shaders in the background. (A shader is a small program that draws a part of the picture.) The graphics driver also gets the correct amount of memory.
- **No more freezes in 32-bit DXMT games**, such as Age of Mythology. (DXMT is one of Unwine's graphics layers. It changes DirectX into Metal, the graphics system of the Mac.) Now only the game's .exe can turn off DEP, a memory guard, as on Windows.
- **No more empty buttons in launchers.** Windows fonts such as Palatino Linotype now use the Mac's Palatino.
- **120 fps mode** for DXMT games that ask for 60 Hz on a faster screen. It is off at the start. The note under the switch tells you when it helps. If the motion is not smooth, turn it off.
- **Games come to the front when they open.** This also works when Stage Manager is on. Your keyboard then goes to the game.
- **macOS Game Mode** now turns on for the game, not for Unwine. Game Mode gives the game more of the Mac's power.
- Unwine uses less of the Mac's power while you play.
- The game page now finds a Windows bottle that cannot run 32-bit programs. It offers to make a new bottle.
- When you add GPTK, Unwine shows the progress. A second click does nothing.
- **Online mode:**
  - High Resolution Mode makes text sharp. The first start is no longer too large.
  - The switch "Games fill the whole screen" puts full-screen games over the Dock and the menu bar.
  - "Close now" stops Windows Steam immediately.
  - Unwine shows the progress while Windows Steam opens.
  - Unwine asks you before it restarts Windows Steam for a new setting.
  - Low latency and frame caps no longer restart Windows Steam.
  - A new switch turns on macOS Game Mode for games in Windows Steam.

## 1.0.1 · 2026-10-20

Decant is now Unwine. It is the same free app, with a new name and a new blue look. Decant 1.0.0 updates itself to Unwine. Your engine, GPTK and settings move with it, and you do not download them again.

- **Advisor.** Each game gets suggested settings for speed or for battery life. The suggestions come from the Highball database. The advisor only suggests. Your own settings always win.
- **Online mode (test version).** Unwine can run Windows Steam for games with Valve Anti-Cheat (VAC), such as Left 4 Dead 2 online. VAC finds cheats, and it needs Windows Steam. Mac Steam closes while Windows Steam runs. Unwine never changes the game files.
- **Low latency** switch for DXVK games. It can make the game react faster to your keys and mouse. It is off at the start. (DXVK is one of Unwine's graphics layers. It changes DirectX into Vulkan.)
- **MetalFX sharpening** for DXMT games. MetalFX is Apple's tool that makes the picture sharper.
- Frame caps now go into setting files. They no longer replace the launch options of a game.

## 1.0.0 · 2026-10-20

The first version. Its name was Decant.

- Play Windows games on an Apple Silicon Mac, through Steam Play in Mac Steam. (Steam Play is the part of Steam that runs Windows games on other systems.) Unwine is free.
- Unwine gets a free engine for you: Wine 11, with the graphics layers DXMT and DXVK. (Wine lets Windows programs run on a Mac.)
- DirectX 12 games can use Apple's D3DMetal. It comes in GPTK 4, Apple's Game Porting Toolkit. You download it from Apple with your own Apple ID.
- Unwine selects a graphics layer for each game. You can change the settings for each game.
- Unwine updates itself: the engine, the Steam Play files and the app.
- Unwine never changes Steam.app.
