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

## 1.0.6 · not released yet

- **Fix for a crash at start in DirectX 10 and 11 games.** DXMT (the layer that draws these games with Metal) used its device before it set it up. Then a game could close at start, Age of Mythology too. Unwine now fixes this in its own copy of DXMT. DXMT itself fixed it on 30 Sep 2026, so newer DXMT builds do not need the copy.
- **Find in GeForce NOW.** Some games have kernel anti-cheat (it runs in the core of Windows), for example Ricochet in new Call of Duty games. No Wine tool on a Mac can load it, so online play does not work. Their page now says so and has a button for cloud play. The button opens GeForce NOW (NVIDIA's cloud gaming service) at the game when its list has the game. Unwine sends only that game's name to NVIDIA, and only when you click. Valorant and other Riot Vanguard games have no known cloud option, so their page says that.

## 1.0.5 · 2026-10-21

- **Faster x87 math works now.** In 1.0.4 it stopped every 32-bit game at start, Age of Mythology too. Wine gave x87sidecar a file that this engine does not have. Now x87sidecar gets the right file, in added games and in Steam games. In a test, x87 math ran about 28 times faster. It is still experimental. Some games crash with it, and Steam can show "Stop" after you quit the game. Unwine now says so beside the switch.
- **Unwine now reads a 32-bit game's code** and counts its x87 math. The Faster x87 math switch says what it found. Most games use SSE math (a newer, faster way), not x87. For those games, the switch helps little and can make the game slower.

## 1.0.4 · 2026-10-21

- **Automatic battery mode.** On battery, in Low Power Mode or when your Mac is hot, games start with a frame cap of 60 fps. In Low Power Mode or heat, the cap is 40 fps (30 fps on a 60 Hz screen). 120 fps mode waits until you plug in. Plugged in, nothing changes.
  - Each game page has the switch **Save battery when unplugged**. A line under it says what the game gets now. Your own frame cap always stays.
  - It also works for games that you start in Steam. Keep Unwine open. Its window can be closed.
- **Best battery** is better. It turns on MetalFX for DLSS only when the game has DLSS. It turns ray tracing off for D3DMetal games. It uses less tessellation (fine surface detail) for DirectX 11 games on DXMT.
  - Best battery no longer turns on MetalFX sharpening, because sharpening uses more power. Did you use Best battery before? Click it again to get the new settings.
  - On macOS 15, the Best speed and Best battery cards no longer show Metal 4. Metal 4 needs macOS 26.
- **Ray tracing** has its own choice for D3DMetal games: Apple's default, Off or On.
- **Smoother frame caps** for DirectX 8 and 9 games and the DXVK layer. The list of caps now fits your screen, for example 30, 40, 60 and 120 fps on a 120 Hz screen.
- **New games** in Settings: choose Best speed or Best battery, a frame cap and battery mode for every game that you did not change.
- **Find a game fast.** Search (⌘F), sort and filter your library. Right-click a game to add it to your **Favourites** or to hide it.
  - Each game shows when you last played it and for how long, for example "Played 3 days ago · 12 h".
  - Labels on covers show what to know before you open a game: **Blocked**, **Online mode**, **Not using Unwine**, **File missing** or **Running**. **Starting** shows while a game starts in Windows Steam.
- **Add a game by dragging it** onto the Unwine window. You can also use Open With > Unwine in Finder.
- **Added games start much faster the first time.** Unwine copies a ready Windows bottle in about a second. (A bottle is the small Windows system that Unwine makes for each game.)
- **Launch options and mods** is a new part of each game page.
  - Type launch options, such as -windowed, and extra settings, such as DXVK_HUD=fps.
  - Tick **DLL overrides** for mod loaders, such as dinput8. Wine then loads the mod's DLL first.
  - Pick a **game language**, such as Japanese or Traditional Chinese, so old games show their text correctly.
  - **Run a program in this bottle** runs an installer, a patch or a mod tool with the game's settings.
  - **Wine tools** opens Wine settings, the registry editor, the task manager or the uninstaller.
  - **Show bottle (C: drive)** opens the game's Windows drive in Finder. Many games keep their saves there.
- After an installer ends, its page offers **Pick the installed program**. The game then starts from the same bottle.
- **Steam games show when they start and when they run.** If a game closes before it shows a window, Unwine tells you. You can quit a running Steam game from its page or its right-click menu.
- Right-click a game that you added to quit it while it runs.
- **Restart Steam** shows each step. It waits until Steam Play is ready.
- **Display** is a new part of each game page: **Sharp picture (Retina)**, **Game takes the whole screen**, **Command key acts as Ctrl**, an **HDR** choice, and a window or full screen for old DirectDraw games.
  - **HDR** has three choices: Automatic, On and Off. On the DXMT layer, Automatic lets a game with HDR use it. **On** is a test for the DXVK layer: DXVK then tells the game that the screen has HDR. A game without HDR of its own keeps its normal picture.
- **Faster x87 math (experimental)** for old 32-bit games. (x87 is how old PCs calculate with decimal numbers. Rosetta runs it slowly.) The switch is off at the start.
  - The first time you turn it on, Unwine downloads x87sidecar (181 KB, free, from github.com/athei/x87sidecar) and checks it.
  - macOS asks for your password once after each login. Allow it. If you do not, the game does not start.
  - x87sidecar now stays off for wineboot (the Windows program that makes a game's bottle) and for the programs that wineboot starts.
  - A few games can glitch. Then turn the switch off for that game.
  - It is always off in Online mode, so nothing attaches to Windows Steam or to a game with Valve Anti-Cheat (VAC).
- **Last session** on each game page (macOS 27): frames each second, GPU time for each frame and shader time, with one tip.
- **DirectX 12 through DXMT** is a new test switch for DirectX 12 games without GPTK. The game can fail to start. Online mode does not use it.
- **Storage** in Settings shows what uses space and can clean it up. Unwine also deletes each download after it installs.
- **Clear shader cache** is on each game page. Use it when a game stops starting. The next start is slower one time.
- **Logs open inside Unwine.** You can copy details for a bug report or report a problem on GitHub.
  - Logs are quieter now. When a game does not start, turn on **Detailed logs** on its page and play again.
  - When a game does not start, its message has a **Show logs** button. It opens the logs of that game. Help > Show Logs opens Unwine's logs.
- **Safer engine updates.** If a new engine does not take one of Unwine's fixes, Unwine keeps your engine and asks you. Settings can also go back to your previous engine.
- **Updates wait while you are on battery**, on a phone hotspot or in Low Data Mode. A download that stops continues from where it stopped.
- **Added games look like themselves.** They show their own icon. You can choose a cover. They get Highball advice too.
- **Online mode:** after your game closes, Unwine asks if you want to quit Windows Steam. macOS can now slow down Windows Steam's hidden windows to save battery.
  - Windows Steam restarts one time after this update, because its log settings changed.
  - Windows Steam asks to restart less often. The settings of old DirectDraw games and the frame cap of D3DMetal games now apply without a restart.
- Messages have a button for the next step. Problems show in red.
- New menu items: Settings… (⌘,), Add Game… (⌘O), Find… (⌘F), and Report a Problem in the Help menu.
- You can use the library with the keyboard and VoiceOver. Reduce Motion stops the waiting animations.
- Setup has **Use without Steam for now** when Steam is not on your Mac.
  - Then Settings says that Steam is not installed and has a **Get Steam** button. **Restart Steam** stays off until you install Steam.
- A game page shows the controllers that are connected.

## 1.0.3 · 2026-10-21

Unwine 1.0.3 was not published by itself. Its changes come to you in 1.0.4.

- **A game and its launcher share one Windows bottle.** (A bottle is the small Windows system that Unwine makes for each game.) Add two programs from one game folder, such as a launcher and its game. Settings that you make in the launcher now go to the game.
  - Did you add a launcher and its game before this version? Unwine puts them into one bottle when it opens. The bottle that it does not need goes to the Trash.
  - If both bottles have saves in them, Unwine does not join them.
- A launcher now starts with the settings of its game. The game that the launcher opens then gets the correct settings.
- **Right-click a game** in your library to play it or to open its settings. For a game that you added, you can also rename it or remove it there.
- **No more crash when a game shares a picture between two DirectX parts.** Romance of the Three Kingdoms XIV is one of these games. Before, it closed or showed only a black screen with music. Now it opens and you can play.
  - The videos in these games stay black, but you hear the sound. Push Esc to skip a video.
- **Chinese, Japanese and Korean text shows correctly** in dialogs and launchers. Before, some of this text showed as empty boxes. Unwine now uses the Mac's own fonts for these languages.
- **Fresh bottle** no longer deletes a game that you installed inside its bottle. Unwine keeps the bottle and tells you why.
- **On macOS 15 to 25, games that use Vulkan get a driver that loads.** (Vulkan is the graphics system that DXVK uses.) Before, Unwine gave them a driver that needs macOS 26. Now it uses MoltenVK on these versions. MoltenVK cannot do all that DXVK needs, so some games can still fail.
- Unwine uses less of the Mac's power in the background. When its window is hidden, it looks at Steam less often.

## 1.0.2 · 2026-10-21

- **Add game.** You can now add a Windows program that is not in Steam. Pick its .exe file or its folder. Each program gets its own Windows bottle and its own settings.
  - When you pick a folder, Unwine shows the programs in it. The most likely program is first. Unwine gives the game the name of its folder.
- **Fewer stutters in DirectX 8 and 9 games.** Unwine now makes more shaders in the background. (A shader is a small program that draws a part of the picture.) The graphics driver also gets the correct amount of memory.
  - The switch "Build shaders in the background" on the game page controls this. It is on at the start. When it is on, a new effect can show a moment late the first time. When it is off, the game stops for a moment for each new effect.
- **Far fewer freezes in 32-bit DXMT games**, such as Age of Mythology. (DXMT is one of Unwine's graphics layers. It changes DirectX into Metal, the graphics system of the Mac.) Now only the game's .exe can turn off DEP, a memory guard, as on Windows. A game whose .exe turns off DEP still runs that way.
- **No more empty buttons in launchers.** Windows fonts such as Palatino Linotype now use the Mac's Palatino.
- **120 fps mode** for DXMT games that ask for 60 Hz on a faster screen. It is off at the start. The note under the switch tells you when it helps. If the motion is not smooth, turn it off.
- **Games come to the front when they open.** This also works when Stage Manager is on. Your keyboard then goes to the game.
- **macOS Game Mode** now turns on for the game, not for Unwine. Game Mode gives the game more of the Mac's power.
- Unwine uses less of the Mac's power while you play.
- The game page now finds a Windows bottle that cannot run 32-bit programs. It offers to make a new bottle.
- When you add GPTK, Unwine shows the progress. A second click does nothing.
- **Online mode:**
  - **High Resolution Mode** is a new switch in Settings. It is off at the start. When it is on, text is sharp, and a game that you set to the full size of your screen shows at the correct size.
  - The switch "Games fill the whole screen" puts full-screen games over the Dock and the menu bar.
  - "Close now" stops Windows Steam immediately.
  - In Settings, "Quit Windows Steam" now asks "Quit the game too?" when a game is still open. Before, the button did nothing that you could see.
  - Unwine shows the progress while Windows Steam opens.
  - Unwine asks you before it restarts Windows Steam for a new setting.
  - Low latency and frame caps no longer restart Windows Steam.
  - A new switch turns on macOS Game Mode for games in Windows Steam.

## 1.0.1 · 2026-10-20

Decant is now Unwine. It is the same free app, with a new name and a new blue look. Decant 1.0.0 updates itself to Unwine. Your engine, GPTK and settings move with it, and you do not download them again.

- **Advisor.** Each game gets two sets of suggested settings: one for speed and one for battery life. Unwine makes them from what it finds in the game's files. A set changes nothing until you click it.
- **Automatic** graphics layer now follows the advice. If the Highball database lists the game, Unwine uses the layer from the list. (Highball is a list of games that people tested on a Mac.) If not, Unwine uses the layer that fits the game's files. A layer that you select yourself always stays.
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
