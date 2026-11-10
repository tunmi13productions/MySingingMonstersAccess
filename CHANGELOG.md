# Changelog

What changed in each version of My Singing Monsters Access, newest first. Changes that are done but not yet in a release are listed under Unreleased.

## Unreleased

### Added

- F (fallback Control+Shift+F) gives advice for your island: how many trees and rocks are right next to your monsters and buildings, which one is easiest to clear first by its name in the list, for example "Small Rock 3", and whether coins are waiting. Tab moves onto it, so Enter selects it.
- Trees and rocks being removed, or ready to finish, get their own Clearing group in the island list, shown only while there are some.
- The Fuzer: the conjure screen says what it makes, and the three Glowbes are named Red, Green and Blue.
- A Clubbox guide, linked from the README.

### Improved

- REMOVE on a tree or rock says its price, for example "Remove, 1,250 coins".
- FEED on a selected monster says how much food it costs, for example "Feed, 1,250 food".
- After a tree or rock is cleared away, the mod says so and stops, instead of tapping whatever is behind it.
- When something is in front of a tree or rock you're tapping, the mod zooms in closer and tries again.
- After an egg cracks, you hear what hatched, for example "You discovered Potbelly!, Class: Natural", and Continue is in the Tab list. Before, only a NEW button showed and the screen couldn't be left.
- Screens you tap to continue are found even when they have a lot of text on them.
- The friend code box says what it's for, reads the code you type or paste, and its buttons say "Send friend request" and "Cancel" instead of Yes and No. Naming a monster says "Save" and "Cancel".
- Friend card buttons are short: "Light Bob's torch", "Send key to Bob", "Favourite Bob, on/off".
- Each friend card is in the Tab list once, instead of twice.
- The Close button on a building's INFO screen works.

## 0.1.13-alpha - 2026-11-09

### Added

- The Clubbox is accessible. Club manager Autotuna's lines are read (each tutorial page, and whoever else is talking), the act and island pickers say which act or island is selected with its Hype and rewards, and the Clubbox island's bar (EXIT, HELP, INFO, HYPE, CUSTOMIXER) is in the Tab list.
- The Hype game talks: Fewer tickets and More tickets say how many tickets you're spending and what the wheels can give, Spin spins, and when the wheels stop you hear the result, for example "Result: 120 times 3, 360 Hype!"
- Hype progress reads your Hype, how many rewards you've earned, the time left and the top prizes, and each of the 27 reward stops says what it gives and whether it's earned, next or locked.
- The CUSTOMIXER: each performer's volume slider ("Candelavra volume, slider, 40 percent"), the stage decor buttons with their style ("Stage decor, back stage, style 1 of 2", locked, or a new style to try), and the DJ's options page with its Motion FX switch.
- Sliders can be adjusted from the keyboard: Shift+Comma and Shift+Period step down and up, Shift+Home and Shift+End go to the lowest and highest value, and Enter on a slider resets it. This works on the CUSTOMIXER volumes, the Time Warper, monster volume and decoration size.
- A (fallback Control+Shift+A) in the Clubbox says the act, its island, your Hype toward the next reward, total Hype, your Clubbox Tickets and the time left.
- Visiting a friend's island: Tab lists their buildings and monsters instead of yours, and Enter on one taps it, just like a finger would, so you can look at their things without doing anything a visitor can't.
- Control+Shift+I describes the Dipsters (Do, Re, Mi, Fa, Sol, La and Ti).

### Improved

- The Clubbox and Sticker book buttons on your island's HUD were missing from Tab. They now say "Clubbox, 15d 23h left, 0 tickets" and "Sticker book, 2".
- Screens you tap anywhere to continue (opening a sticker pack, a new performer joining your act) had nothing to press. They now have a Continue button and say what happened, for example "Sticker pack, 2 packs left" or "DJ Epic has joined the Act in the Clubbox!"
- Event screens (a new Clubbox event, Dipster Digs) read their text instead of just "clubbox event screen".
- Offers that pop up from a counter, such as "Would you like to top up your Clubbox Tickets now?", are announced with their question and Tab moves into them.
- A popup that opens on top of another screen (a reward over the Hype game, a LISTEN UP! notice) lists only its own buttons, not the screen's behind it too.
- Visiting a friend no longer announces false "Spent ..." or "Level up!" messages.

## 0.1.12-alpha - 2026-11-08

### Added

- Rare and Epic eggs shimmer in the Nursery, and now the mod describes it too, for example "Nursery, egg hatching, 5 hours left, the egg sparkles with a soft shimmer: a Rare egg!" It doesn't say which monster, just like the shimmer.
- Colossingum battles talk: each move is spoken as it's played, then both monsters' health when it changes (for example "Chewy 10 of 10 health, Toe Jammer 4 of 10 health"), and "Your turn" when you can pick a move. A (fallback Control+Shift+A) in battle says both monsters' health. The results screen says Victory or Defeat and what you won, and TRAIN on a monster reads the power and stamina gain, any new move, the training time and the cost.
- The game's Breeding Guide (GUIDE on the Breeding Structure) was six silent pictures. The mod now reads each page's words and describes its picture as you press Next and Back.
- Once you pick the first monster to breed, the other list says what each pair can make, for example "can make T-Rox, Earth, Water and Cold", or warns "both Cold, usually gives one of the parents". Picking the second monster says it too.

### Improved

- A monster's INFO page reads the tab you're on: Bio reads the monster's description, Stats lists each stat with its value (as the game words them), and Likes lists its likes. Before, every tab showed the likes and Bio and Stats said nothing.
- The Market crashes much less often. The crash is a bug in the game itself (while switching to the Market, its own bar keeps reading memory it has already freed), and anything the mod did at that moment made it far more likely. Now the mod stays out of the way while the game switches places: for about 4 seconds after you open or leave the Market (or the Map, a battle, a Places entry), keys only say "Loading" once and do nothing, and the game's bar is paused while the Market is open. Crashes can still happen occasionally; if one does, just restart the game.
- UPGRADE and SPEED UP say what they cost, for example "Upgrade, 25,000 Coins" (with the sale price when there is one) or "Speed up, 7 Diamonds", including SPEED UP on the breeding screen.
- A tutorial step the game has no text for (it shows a code like BATT_TUT_01_02b_OTHER_DMG_EXPOSITION) now says "This tutorial step has no text in the game" instead of reading the code.
- On the Colossingum, the Monsters list no longer mentions feeding, likes or coins, which don't exist there. It says the level, and "training in the Conservatory" while a monster trains.
- OCCUPANTS (such as the Colossingum's Mess Hall) said "Nothing to navigate". It now says how many beds are occupied, or that no monsters are staying there. Jukebox tunes you haven't unlocked say "locked".
- Colossingum quests: the Team and Opponents tabs were missing, so you couldn't put a monster on your team and Start Battle said "Your current Team doesn't meet the requirements". The tabs are now there, team slots say "Team slot 1: empty. Enter to choose a monster" (or the monster in it), opponents say who they are, and StartBattle is "Start battle". SELECT MONSTER now shows only the monsters to choose from. In battle, your moves were missing; they now say their name and type, and whether they're locked or have an elemental advantage.
- INFO on a building (Wishing Torch, Bakery and so on) said "Likes: nothing", as if it were a monster. It now reads the building's name, its description and any time left, and a torch says whether it's lit.
- Wishing Torch buttons had two identical LIGHT buttons and an "UNHIGHLIGHTED" button. They now say "Light for a day, 2 Diamonds", "Light permanently, 100 Diamonds", "Highlight for friends: off" (or on) and "Buy another torch" with its price. Selecting a torch says whether it's lit and how long it has left, for example "Wishing Torch selected, lit, 23 hours 50 minutes left". The Objects list says "Wishing Torch, lit" or "not lit" too.

## 0.1.11-alpha - 2026-11-07

### Added

- A new guide, breeding-guide.md, says what to breed next once the game stops telling you: how breeding works, every combination on the first five islands, and what each breeding time means.
- X (fallback Control+Shift+X) says your XP towards the next level, for example "Level 11. 1,250 of 5,000 XP, 25 percent. 3,750 XP to level 12".
- The Time Machine's WARP screen only had a slider you couldn't move. It now says the current speed, for example "Speed 1.5 times, faster than normal", and has Faster, Slower and Normal speed buttons that change it in steps of 0.1, from half speed to double speed.
- Single-letter keys: A for status, W for what now, X for XP, M for Places, O for the island objects, I for what a monster looks like, C to reset the camera and T to repeat the tutorial step. They do nothing while you are typing in a text box. The Control+Shift keys still work as fallbacks, and Control+Shift+L turns the single letters off or on if you prefer the fallbacks only. The choice is remembered, including across updates.

### Improved

- The breeding lists say each monster's elements, for example "Fwog, Earth and Water, breed with Noggin", so you can plan combinations without seeing the sigils.
- Offers in the corner tray say their name instead of just "Offer", and opening an offer reads its title, description, price, contents and time left.
- The likes count says "known likes", for example "1 of 3 known likes met", because the Likes screen shows a fourth slot for the mystery like, which stays a secret.
- The loading screen was silent. It now says the loading status when it changes, for example "Downloading Game Data", and the game's tip, for example "Tip: The Clubbox can be hosted on Natural, Fire and Magical Islands." Control+Shift+A on the loading screen says how far along it is, for example "Downloading Game Data 45%".
- Spin the Wheel (SPIN on the Castle) said nothing about the prize until you pressed Collect. When the wheel stops it now says what you won, for example "You won 7,200 Coins. Tab to Collect.", and the Collect button says the prize too.

## 0.1.10-alpha - 2026-11-07

### Added

- Control+Shift+I with a monster selected says what it looks like, for example "A white, furry, yeti-like creature with big yellow eyes and a huge grin full of square teeth", and its elements. The descriptions are written from the game's own monster pictures, starting with the 31 natural monsters (Air, Plant, Earth, Water and Cold, and every mix of them). Rare and Epic versions use the common one's description for now.

### Improved

- Comma, Period, the arrow keys and the brackets no longer wait a quarter of a second between presses, and Comma, Period and the arrows repeat when held, like Tab.
- Comma and Period now move to the previous and next item everywhere, like Shift+Tab and Tab. Shift+Tab is also Steam's overlay key, so this avoids opening the overlay by accident. While placing they still step through free spots, and in a text box (renaming a monster) they type as normal.
- Market prices say their currency, for example "Rare Noggin, 75 Diamonds" instead of "Rare Noggin, 75", so you know before buying whether something costs Coins, Diamonds, Shards, Relics or anything else. Sale items say "on sale, 500 Diamonds, was 1,000 Diamonds".
- The Market's currency counters at the top only said "Currency" for anything other than Coins, Diamonds and Food. They now say which one, for example Keys, Relics, Shards, Starpower, Medals, Egg Wildcards or Minigame Tokens.
- The MEMORY button on the Castle says "free game ready" when the game marks a free Memory Game, or "no free game yet" when playing would cost Diamonds.
- The Likes tab says which likes are met: each one is "met" with how far away it is, "too far" with the distance, or "not on your island", then how many are met, for example "1 of 3 met". The Monsters list says it too, for example "happiness 50%, 1 of 3 likes met". How close counts as met is still a guess (5 tiles) until it is measured against happiness.

### Fixed

- Amounts of one said the plural, for example "1 Keys" or "Got 1 diamonds". They now say "1 Key" and "Got 1 diamond", for every currency and for things like sticker packs and tokens.
- Memory Game: Enter on a card said "Could not turn the card" and nothing turned. Cards are now tapped through the game's own touch input, the way the scratch ticket is played.
- Memory Game cards read as picture codes like "square q05 rare". They now say the monster, with its rarity, or the currency (Coins, Diamonds, Food, XP). The second card of a pair says "Match" or "No match", matched cards say "matched", and Enter on a card that is already face up says so instead of wasting a turn.

## 0.1.9-alpha - 2026-11-07

### Added

- Placing is much faster. The arrow keys now move a placing cursor instead of dragging the object, so each press is spoken straight away (free or blocked, what is nearby, Likes close by). Enter places the object where the cursor is and Escape cancels; Tab says the spot again. The brackets, Comma and Period jump the cursor too. The Confirm placement, Check spot and Cancel placement items are gone.
- Two guides: tutorial.md walks through the game's tutorial step by step, and getting-started.md covers what to do after it. Thank you to Keri, the first player to finish the tutorial with the mod, whose log made both possible.
- The Memory Game (MEMORY on the Castle) can be played: it says the level and mismatches left, each card is an item you can Tab to ("Card 3, face down"), and Enter turns it over and says what it shows.
- A monster's Likes tab (INFO, then Likes) only showed pictures. It now has an item that names each thing the monster likes, then "and a mystery like" for the one the game keeps hidden. Placing a monster next to something it likes makes it happier.
- While placing a monster, the spot it is on also says its Likes close by, for example "Likes nearby: Reflecting Pool, 2 tiles away". While placing a decoration, it says which monsters close by like it, for example "Liked by Fwub, Fwog, next to it". The Monsters list says each monster's happiness.
- Deselecting something says what it was, for example "Glob, Toe Jammer deselected", instead of only "Deselected".
- When a monster levels up, for example from feeding, you hear "Noggy1 leveled up to level 7".

### Improved

- The Colossal Conundrum (CONUNDRUM on the Coloss-Eye) only offered Close and Help. It now says how many puzzle pieces you have collected, which days are special pieces and which is the final piece, and when you can collect the next one. A "Puzzle" item you can Tab to says it again, and Collect and Catch Up appear when the game shows them.

### Fixed

- After "Placed", the game could stay in placing mode, so the mod kept saying "Blocked" (the object was sitting on its own spot). Placing now ends properly, the way the game's own checkmark does it.
- Left bracket and Right bracket said the landmark's name and then cut it off with the free spot. They now say both together, for example "Fwub, Fwog, 3 of 12. Free spot, 2 tiles below of Fwub, Fwog".
- After moving a monster with MOVE, you could be left on a screen with only SHOW GRID and no way out. That panel now closes after placing or cancelling, and Escape closes it if it is ever left behind.
- Hatching a monster said "You've hatched..." without saying what. It now names the monster, with its rarity if it isn't ordinary, for example "You've hatched Pummel. What would you like to do with it?". Collecting a bred egg ("You've bred...") does the same.
- Questions said "1 button: No" when they first appeared, because Yes is held back while you still have Enter down. They now list both answers.
- Pressing Enter on something that asks a question (for example Bread in the Bakery: "Would you like to bake Bread for 1,000 Coins?") could answer Yes by itself a moment later, because the game also treats Enter as Yes and took the same key press. The question now waits until you let go of Enter and choose an answer.

## 0.1.8-alpha - 2026-11-06

### Added

- The Monster Scratch Ticket (SCRATCH on the Nursery) can be played: Tab to a square and press Enter to scratch it, or choose "Scratch all squares". Uncovered squares say their prize, and once all six are uncovered you hear what you matched and can Tab to Collect. Escape explains that the ticket only closes through Collect.

### Improved

- Monsters that aren't ordinary say their rarity before the species, for example "Glob, Rare Toe Jammer", in the Monsters list, when selected, in the breeding lists and on scratch ticket prizes. Ordinary monsters stay as they were.
- A muted monster says "muted" after its food status in the Monsters list, for example "Noggy1, Noggin, level 6, fed 0 of 4, muted, 88 coins".

### Fixed

- Messages such as "You don't have enough Diamonds" read out colour codes like "<c=#45db99>" around the currency name. They now just say the currency, for coins, food, diamonds and everything else.

## 0.1.7-alpha - 2026-11-06

### Fixed

- Renaming a monster (the tutorial asks you to rename your Noggin) wasn't findable: the rename button is the name plate at the top of the monster's info screen, and it only read as the monster's name. It now says "Rename, now called Noggin". The name box says what it is and the current name, speaks each letter you type or delete, and Enter saves the name.
- On some computers, tapping things on the island did nothing at all, so for example the Nursery could not be tapped at the tutorial step "Place the Monster". The mod used to tap by moving the mouse and clicking; it now hands the tap straight to the game's own touch handling, the way a real click arrives, so display scaling, other windows and where your mouse is no longer matter. If a game update moves that code, the mod falls back to clicking.
- On some screen shapes (for example 1280 by 800), tapping the Nursery in the tutorial step "Place the Monster" did nothing: the mod clicked just above the egg. When a click selects nothing and opens nothing, the mod now tries the next spot on the object, starting with its centre, and stops as soon as something opens.
- Hatching an egg opens a screen that says "The egg is ready! Click it to crack it open!", and the egg itself was not something you could Tab to. In the tutorial that screen has no other way out, so you were stuck. The egg is now an item: press Enter on it and the mod taps it until it cracks open, then Tab to Continue.
- Tapping the Nursery (or anything that opens a screen when tapped) said "If nothing happened, the click missed" over the top of the screen that had just opened. It now lets that screen speak.

## 0.1.6-alpha - 2026-11-06

### Added

- Home and End jump to the first and last item of a list or screen, including the Places and island object lists.
- Control+Shift+C puts the camera back on the whole island, the same view the game uses after a new island's fanfare.

### Improved

- Fast Tab presses are no longer dropped (before, presses less than a quarter of a second apart were ignored), and holding Tab or Shift+Tab moves through the list repeatedly. Enter, Escape and the other keys keep a short gap between presses on purpose: they change things in the game (buying, closing screens, dragging an object), so a press counted twice could buy something twice, close the screen underneath, or drop an object in the wrong spot. Tab, Shift+Tab, Home and End only move your focus, so a doubled press is harmless.
- The countdown button at the bottom of the main screen (for example "1d 20h") is a limited-time shop offer. It now says "Offer", with the offer's name when the game provides one, and the time left.

### Fixed

- Tutorial steps about the egg hatching ("Wait for the egg to hatch", "Speed up the hatching of your Mammott egg") pointed at the Breeding Structure instead of the Nursery, because they mention the egg. They now point at the Nursery. "Click on the Egg to transfer it to the Nursery" still points at the Breeding Structure, where that egg is.
- Control+Shift+W said "Collect All is on the bar" even before the game unlocks Collect All. It now says whether Collect All is there, recharging, or not unlocked yet, and if not, how to collect from each monster instead.
- The Goals screen said "Nothing to navigate" (the game changed how goals are built in 5.7.4). Every goal now has a "Show me" item that says the goal, its progress and its reward, and Collect buttons say which goal and what you get, for example "Collect: Breed a Fwog and Potbelly together. Reward: 50 coins".

## 0.1.5-alpha - 2026-11-05

### Fixed

- On the main screen, Tab often went silent or skipped things (since 0.1.4-alpha). The new Encore button label hit an error that stopped the whole list. The Encore event screen's points line had the same error.

## 0.1.4-alpha - 2026-11-05

### Fixed

- The Map showed only Close and Help most of the time (since 0.1.3-alpha): the islands are back. The crash fix in 0.1.3-alpha expected every screen to refresh every frame, and the map doesn't.
- The "Welcome to" screen after getting a new island had no way to continue. It now has a Continue item, and Escape continues too.
- After placing a decoration you were stuck on a screen with only Show Grid. The game selects the new decoration and opens its Decoration Size panel; Tab now offers the decoration's own buttons (Info, Sell, Move, Buy more) plus Show Grid, and Escape deselects it and closes the panel.
- Since the game's 5.7.4 update, the mod couldn't tell where any object on the island was, so placing said "No objects to jump to" and never described where you were next to things. It finds that part of the game again, in a way that should survive small game updates.
- When an arrow key didn't move the object being placed, every later arrow press missed too. Now it says "Did not move", and the next press re-centres on the object first.

### Improved

- Map: picking an island reads its details (cost, requirements, what you have collected) and puts focus on GO, so Enter travels there.
- Encore: the event screen reads the event's name, theme, how points are earned (for example "Every 15 minutes of Incubation time earns 1 point"), your points and the time left. The Encore button on the main screen says your points and time left too.
- "How it works" screens (Encore, sticker album) read their numbered steps.
- Map: the arrow buttons are called Previous island and Next island, GO says which island it goes to, and the alert buttons at the top have proper names instead of "SeasonalAlert".

## 0.1.3-alpha - 2026-11-05

### Fixed

- Pressing Tab right after opening the Market (or anything else that switches screens) no longer freezes and crashes the game.
- The "You received:" screen after collecting rewards now reads what you got, for example "You received: 5 Minigame Tokens, 2 Common Sticker Packs", instead of only "You received:".
- Screens that say "Click to continue" (rewards, card packs) now have a Continue item you can Tab to. Before, there was nothing to press and no way out. Escape and Backspace also continue on those screens.
- The tutorial step at the Nursery now hatches the egg when you press Enter on it, instead of a click that could miss.
- Tutorial steps about buying something (such as "Buy a Noggin egg") now point at the Market, not the Breeding Structure.
- Clicking on an island object no longer sounds like it surely worked: it says "If nothing happened, the click missed."

### Improved

- Breeding: the two monster lists are announced as "Monster 1 list" and "Monster 2 list" when you Tab into them, and Left bracket and Right bracket jump between them.
- Breeding: the monster you picked says "selected", and monsters in the other list say who they would breed with, for example "Glob, Toe Jammer, breed with Noggy1".
- Breeding: after each pick you hear what is chosen and what to do next, for example "Breeding Noggy1 with Glob. Now press Breed."

## 0.1.2-alpha - 2026-11-05

### Fixed

- Two crashes: one when a screen closed right after pressing Enter (Market, Visit, buying from a confirmation), and one while the game was loading the first tutorial step.

### Added

- `debug.bat`: zips the mod's log, Jeode's log, recent crash reports and a short summary onto your Desktop, ready to attach to a bug report. Nothing is sent anywhere.

## 0.1.1-alpha - 2026-11-05

### Added

- `update.bat`: checks GitHub for the newest version, downloads it over the folder you run it from, and installs it.

### Changed

- Every release is now marked Latest, so the "latest release" link always gets the newest build.
- The README no longer tells you to start your screen reader, and spells out Left bracket and Right bracket in the keys table.

## 0.1.0-alpha - 2026-11-05

First public release.

- Speech through Prism, which works with NVDA, JAWS, System Access, Narrator, or Windows' own voice when no screen reader is running.
- Tab, Shift+Tab and Enter work on menus, dialogs, the bottom bar, the top counters and the island's objects; Escape and Backspace go back.
- Island objects grouped into Buttons, Buildings, Monsters, Decorations, and Trees and rocks, with Left bracket and Right bracket to switch groups.
- Placing objects from the keyboard: arrow keys, nearby free spots with Comma and Period, and landmarks with the brackets.
- Status (Control+Shift+A), What now (Control+Shift+W), Places (Control+Shift+M), the island object list (Control+Shift+O) and the tutorial keys (Control+Shift+T and Control+Shift+Enter).
- Labels for the Friends screen, the Inbox, the profile editor, the Book of Monsters and its filters, and the Options screen.
- Pressing No on a Yes/No question no longer presses Yes.
- The Options screen's Screen Size and Language lists show only their own choices and no longer stack on top of each other.
- `install.bat` finds the game, installs the Jeode mod loader if needed, copies the mod and builds its menu hooks from your own game files; `uninstall.bat` removes it.
