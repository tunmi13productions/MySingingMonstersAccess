# My Singing Monsters Access

My Singing Monsters Access is a mod that makes the PC (Steam) version of My Singing Monsters playable with a screen reader such as NVDA or JAWS. Menus, buttons, dialogs, your island's objects and placing things on the grid are all reachable from the keyboard and spoken aloud.

> [!WARNING]
> **This is early, experimental software. Read this before installing.**
>
> - **It is an unofficial fan mod.** It is not made, endorsed or supported by Big Blue Bubble. Do not contact them for help with it.
> - **My Singing Monsters is an online game tied to your account.** Modding it may break the game's terms of service. Using any mod could, in the worst case, get your account flagged or banned. **You use this entirely at your own risk.**
> - **Expect bugs.** Some screens are not labelled yet, some announcements are wrong, and the mod can press the wrong button. In testing it has pressed "Yes" when "No" was chosen. That one is fixed, but there may be others like it, so **be careful on any screen that spends diamonds or real money.**
> - **The game can crash.** If it does, restart it. Your progress is saved on the game's servers, not by the mod.
> - **Game updates can break the mod.** After every game update, run `install.bat` again. If the mod then misbehaves, uninstall it until a fixed version is out.
> - It is provided as is, with no warranty of any kind.
>
> If any of that is not OK with you, do not install it.

## What you need

- **Windows** (10 or 11) and **My Singing Monsters from Steam**.
- **A screen reader.** NVDA is recommended and the one it is tested with. JAWS, System Access and Windows Narrator should also work. If none is running, Windows' built-in voice (SAPI) is used.
- **An internet connection while installing**, so the installer can download the Jeode mod loader if you don't have it.

You do **not** need any programming tools. Everything is already built.

## Installing (the easy way)

1. Go to the [Releases page](../../releases/latest) and download the zip file named `msm-a11y-<version>.zip` (under "Assets").
2. **Extract the whole zip** to a folder, for example your Desktop. (Right-click the zip, choose "Extract All", then "Extract".) Don't run anything from inside the zip.
3. **Close My Singing Monsters** if it is running.
4. Open the extracted folder and run **`install.bat`** (double-click it, or select it and press Enter).
5. A window opens and talks you through it. It will:
   - find your game folder (if it can't, it tells you how to find it and asks you to paste it),
   - offer to download and install **Jeode**, the mod loader this mod runs on (answer `y`),
   - turn off Jeode's "Do you wish to load these native mods?" question, so you don't have to answer it every time the game starts (it's the `suppress_native_warnings` setting in the game's `jeode\config.json`; the mod's native part is what reads your keys and talks to your screen reader),
   - copy the mod into the game's `mods` folder,
   - build the mod's menu hooks from your own copy of the game.
6. When it says **INSTALLED**, press any key to close the window.
7. Start My Singing Monsters from Steam as usual. While it loads you should hear "My Singing Monsters accessibility mod loaded via Jeode".

The installer is safe to run more than once. Running it again is how you **repair the mod after a game update**.

### Updating

Run **`update.bat`** from the same folder you installed from. It checks GitHub for the newest version and, if there is one:

- downloads it and copies it over that folder, so that folder's `install.bat` installs the new version from then on,
- installs it into the game straight away.

If you already have the newest version, it says so and changes nothing. (Downloading the new zip and running its `install.bat` also works.)

What changed in each version is in the [changelog](CHANGELOG.md), which is also in the zip.

You don't have to remember to check. Each time the game starts, the mod asks GitHub whether there's a newer version. If there is, a few seconds after your island loads you hear the food-ready sound and "My Singing Monsters Access 0.1.14 is out. To update, run update.bat in the folder you installed the mod from." It only sends GitHub the same request `update.bat` does, and if there's no internet it stays quiet. To turn it off, open `mods\msm-a11y\settings.ini` in the game folder (create it if it isn't there) and add these two lines:

```
[update]
check=0
```

### If Windows or your antivirus complains

- **"Windows protected your PC" (SmartScreen):** choose "More info", then "Run anyway". The scripts are plain text you can open in Notepad and read.
- **Antivirus removes Jeode** (Windows Defender, Avast and AVG are known to do this wrongly): add your My Singing Monsters folder as an exclusion in the antivirus, then run `install.bat` again. This is a known false alarm with Jeode, see [Jeode's page](https://github.com/Paficent/jeode).

## Installing by hand

Only needed if `install.bat` doesn't work for you.

1. **Find your game folder.** In Steam, right-click My Singing Monsters, choose Manage, then Browse local files. It's the folder that contains `MySingingMonsters.exe`, usually `C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters`.
2. **Install Jeode.** From [Jeode's latest release](https://github.com/Paficent/jeode/releases/latest), either run `jeode-installer.exe`, or download `winhttp.dll` and `libjeode.dll` and place them like this:
   ```
   My Singing Monsters\
       MySingingMonsters.exe
       winhttp.dll
       jeode\
           libjeode.dll
   ```
3. **Copy the mod.** From the extracted zip, copy the folder `mod\msm-a11y` into the game's `mods` folder (create `mods` if it isn't there), so you end up with `My Singing Monsters\mods\msm-a11y\a11y.dll`.
4. **Build the menu hooks.** Open PowerShell in the extracted zip's `installer` folder and run (with your own game path):
   ```
   powershell -ExecutionPolicy Bypass -File .\Build-MenuOverrides.ps1 -GamePath "C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters" -OutDir "C:\Program Files (x86)\Steam\steamapps\common\My Singing Monsters\mods\msm-a11y\data\menus"
   ```
   Without this step the mod still talks, but most screens can't be navigated.

## Guides

- [tutorial.md](tutorial.md): the game's tutorial, step by step, with the keys to press at each step.
- [getting-started.md](getting-started.md): what to do after the tutorial, from your daily routine to breeding, beds and minigames.
- [breeding-guide.md](breeding-guide.md): what to breed next once the game stops telling you, island by island, with breeding times.
- [clubbox-guide.md](clubbox-guide.md): the Clubbox event, from the Hype game and its rewards to the CUSTOMIXER.
- [tips.md](tips.md): every loading-screen tip in the game, sorted by topic, with how to do each one with the mod.

## Keys

The single-letter keys (A, W, X, M, O, I, C, T) do nothing while a text box is open, such as renaming a monster, so you can type freely. Their Control+Shift fallbacks work everywhere. If you'd rather use only the Control+Shift keys, press **Control+Shift+L** to turn the single letters off (press it again to turn them back on). The choice is remembered, including across updates.

| Key | What it does |
| --- | --- |
| Tab / Shift+Tab | Next / previous item on the current screen. Period and Comma do the same, which helps because Shift+Tab also opens the Steam overlay. |
| Enter | Press the current item |
| Escape or Backspace | Go back: close the screen, cancel, answer No, or deselect. The game's own Escape is tried first. |
| Home and End | Jump to the first or last item of the current list or screen. |
| 1 to 9, and 0; Shift+1 to Shift+0 | On a list of 20 items or fewer (such as a monster's buttons or a Yes/No question), 1 is the first item and 0 the tenth, and Shift+1 to Shift+0 are items 11 to 20. Press once to hear it, and press the same number again quickly to press it. They do nothing in a text box, so you can type numbers, and they keep working when Control+Shift+L has turned the single letters off. |
| Control+Shift+S | Stereo width for the monsters' singing: cycles through the game's own, gentle, normal (the default), wide and widest. The game hears everything from the camera high above the island, so on its own nearly every monster sounds centred; with the mod, a monster on the left of the view sings in your left ear. Best with headphones. The choice is remembered. |
| Control+Shift+Left and Right Arrow | Stereo width in small steps (0 to 5), for fine-tuning. |
| Control+Shift+N | Number keys: cycle between "press once to hear, twice to act" (the default), "one press acts" and off. The choice is remembered. |
| Left bracket and Right bracket | On the island: switch between groups (Buttons, Buildings, Monsters, Decorations, Trees and rocks). While placing an object: jump between nearby landmarks. |
| Arrow keys | While placing an object: move the placing cursor one tile and hear the spot (free or blocked, what is nearby, Likes close by). Nothing moves in the game until you press Enter. |
| Enter and Escape | While placing an object: Enter places it where the cursor is, Escape cancels. Tab says the spot again. |
| Comma and Period | Previous and next item, like Shift+Tab and Tab. While placing an object, after a bracket: step through the free spots next to that object. In a text box they type as normal. |
| Shift+Comma and Shift+Period | On a slider: lower or raise it (the CUSTOMIXER volumes, the Time Warper, and while moving something, a monster's volume or a decoration's size). Shift+Home and Shift+End go to the lowest and highest value, and Enter on a slider resets it. |
| A (fallback: Control+Shift+A) | Status: coins, diamonds, food, level and so on. On the loading screen, how far loading has got. In the Clubbox, the act, your Hype, tickets and time left. |
| W (fallback: Control+Shift+W) | What now: things that are ready and your current goals. |
| X (fallback: Control+Shift+X) | XP: how much you have towards the next level and how much is left. |
| F (fallback: Control+Shift+F) | Advice for your island: how many trees and rocks are right next to your monsters and buildings, which one is easiest to clear first (by its name in the Trees and rocks list), and whether coins are waiting. Tab moves onto that tree or rock, so Enter selects it. |
| M (fallback: Control+Shift+M) | Places: Market, Book of Monsters, Map, Goals, Friends, Mail, Options. |
| O (fallback: Control+Shift+O) | A list of everything on your island. |
| I (fallback: Control+Shift+I) | With a monster selected: what it looks like, and its elements. Descriptions are written from the game's own pictures and cover the natural monsters (Plant Island and the other early islands) and the Dipsters so far; more will be added. |
| C (fallback: Control+Shift+C) | Put the camera back on the whole island (the game's default view). |
| T (fallback: Control+Shift+T) | Repeat the current tutorial step. |
| Control+Shift+Enter | Continue the tutorial. |
| Control+Shift+D | Write a diagnostic snapshot of the current screen to the log (for bug reports). |

## Reporting a problem

1. If a screen reads badly, press **Control+Shift+D** on that screen first. That snapshot is what makes it possible to label a screen.
2. If the game crashed or froze, close it (or let it close) first.
3. Run **`debug.bat`** from the folder you installed from. It puts a zip named `msm-access-debug-<date>.zip` on your Desktop and opens the Desktop with it selected. The zip holds the mod's log, Jeode's log, recent crash reports and a short summary of versions. Nothing is sent anywhere.
4. [Open an issue](../../issues) and attach the zip. Say what you did, what you expected, and what happened instead.

The log includes text read from the game, such as your in-game name, friends' names and your friend code. If you'd rather not post that publicly, send the zip privately instead.

## Uninstalling

Run **`uninstall.bat`** from the folder you installed from. It removes the mod and asks whether to remove Jeode as well (say no if you use other Jeode mods). To do it by hand, delete `My Singing Monsters\mods\msm-a11y`, and for Jeode also `winhttp.dll` and the `jeode` folder.

## How it works

- [Jeode](https://github.com/Paficent/jeode) loads the mod into the game. The mod is a Lua script (`init.lua`) plus a small native DLL (`a11y.dll`) for keyboard input and speech.
- Speech goes through [Prism](https://github.com/ethindp/prism), which talks to whichever screen reader is running.
- The game's screens are defined in menu files. At install time the installer copies each of your game's menu files into the mod with one invisible hook added. That's how the mod sees every screen, including ones the game opens internally. Because these are built from your own game files, the mod doesn't redistribute any of the game's files.

## Building from source

Only needed for development. Players should use the release zip.

Requirements: Visual Studio 2022 (or Build Tools) with "Desktop development with C++", plus Git. CMake and Ninja come with Visual Studio.

```
scripts\Build-Prism.bat      (once: builds a 32-bit prism.dll into native\prism)
scripts\Build-Jeode.bat      (builds a11y.dll into jeode\msm-a11y)
powershell -File scripts\Build-MenuOverrides.ps1 -GamePath "<game folder>" -Deploy
powershell -File scripts\Make-Release.ps1 -Version 0.1.0   (optional: the player zip)
```

Pushing a tag such as `v0.1.0` runs the GitHub Actions workflow, which builds everything and attaches the zip to a new release marked Latest.

## Credits

- [Jeode](https://github.com/Paficent/jeode) by Paficent (Boost Software License 1.0), the mod loader.
- [Prism](https://github.com/ethindp/prism) by Ethin Probst (MPL 2.0), screen reader output.
- [MinHook](https://github.com/TsudaKageyu/minhook) (BSD 2-Clause) and [Lua 5.1](https://www.lua.org/) (MIT).

My Singing Monsters is a trademark of Big Blue Bubble Inc. This project is not affiliated with them.
