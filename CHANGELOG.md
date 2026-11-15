# Changelog

All notable changes to the randomizer. Versions are `Major.Minor.Patch`: a new setting or feature raises the
minor version, a fix raises the patch version. The same seed and settings string make a different mod in a
different version.

## 0.5.1 - 2026-11-15

### Added
- **Automatic updates for a git clone.** When the randomizer opens, it checks GitHub for a newer version
  (`git fetch`, 15 seconds at most). If there is one, it pulls it with `git pull --ff-only`. If
  `requirements.txt` changed, it installs the new packages. Then it starts again on the new version, and the
  window's log lists the new commits. It never merges or overwrites anything: with changed tracked files,
  commits of your own, or no internet, it skips the update and the log says why. A ZIP download (no `.git`
  folder) is never touched. Turn it off with `auto_update = false` in the new `[app]` section of
  `user_settings.toml`, or with `OOTR_NO_UPDATE=1`. New file `rando/updater.py`. Tested with local test clones
  (pull and restart, up to date, changed files, own commits, unreachable remote, turned off) and in the
  window from a test clone, but not yet against GitHub itself.

### Fixed
- **Skip Kaepora Gaebora missed his Lost Woods talk after Saria's Song** (seed 3LETP69LQZ): going back into the
  Lost Woods after learning the song, Kaepora still stopped you. That talk (`Dm_LostWood_0010`) now counts as
  already seen too. It's talk only (no item or quest step) and starts the same way as his Lost Woods bridge
  talk, which the setting already skips. Not yet tested in-game.
- **An ocarina at a starting check couldn't be played** (Skip Child Zelda, seed 3LETP69LQZ). The Ocarina of Time
  at HC Malon Egg was in the menu from the start, but it couldn't be played, and Link held no ocarina in Saria's
  song scene. The save only marked it as owned. The game's own ocarina scenes also record which ocarina Link
  holds, so a starting ocarina is now given by the same action, right after Navi wakes Link (no item window).
  Make a new save. Confirmed in-game: the ocarina is in the menu, plays, and shows in Saria's scene.

## 0.5.0 - 2026-11-13

### Added
- **Your settings are saved in `user_settings.toml`**, next to `ootr_remake.pyw`, instead of `.ootr_remake.json`
  in your user folder. The window loads it when it opens and saves it on every change (before, only when you
  pressed Generate Mod), with the game and output folders. Delete it to reset everything. It's a readable
  TOML file that lists every setting with its allowed values and default, so it can be edited by hand while the
  window is closed. An invalid or unknown value is ignored, the default is used, and the log says so. An
  existing `.ootr_remake.json` is read once and left alone. `user_settings.toml` is in `.gitignore`.
- **Seed presets: Beginner, Standard and Expert** (the Seed preset drop-down next to the settings string). A
  preset sets every gameplay setting; Excluded Locations and Create Spoiler Log are kept. Presets use only
  options confirmed in-game. The drop-down shows Custom once you change something, and the preset's name
  whenever your settings match one. The README has a table of what each preset sets. Not yet tried in the
  window by hand: an automated test applied each preset through the window's own code and checked the
  controls, the drop-down and the saved file.
- **Read the game from a .nup file.** The game field (ROM Options) takes your game's `.nup` package as well as the
  extracted romfs folder: **Browse .nup** picks the file, **Browse folder** the romfs. The randomizer reads every
  file it needs straight from the package (the newest base or update inside it), checks each one against the
  SHA-256 stored in the package, and never changes the `.nup`. The game version check uses the package's own
  `exefs/main`, so no exefs folder is needed. Choosing the game folder that holds `romfs` and `exefs` also works
  now. The separate exefs folder field is gone: with a romfs folder, the exefs is found next to it
  (`<game>/romfs` and `<game>/exefs`), and the line under the game field turns green when the version is supported. A path from the folder dialog
  is cleaned up first (quotes, `file://` form, trailing separator), and choosing a folder inside the romfs (such
  as `romfs/Banc`) or the game folder finds the romfs and its exefs; when the exefs is missing, the message names
  the folder it looked in. The `.nup` reader is a55uka/nup (MIT), as Clawshot ships it.
- **The item tracker reads a .nup too** (`Tools/OOTNS2-Tracker`): its setup window has **Browse .nup...** next
  to **Browse folder...**, and the icons are extracted straight from the package. `extract_item_icons.py
  --romfs` also takes a `.nup`. The tracker has its own copy of the reader (`nup/`), so it still runs on its
  own.
- **Items Shuffled Per Shop** replaces Shopsanity (experimental; from OotrR). Every shop takes part: Kokiri,
  Goron and Zora, the Market's bazaar, potion shop and Bombchu shop, and Kakariko's bazaar and potion shop. Choose
  1 to 4 shelves per shop, or 1 to 4 at random. Each shuffled shelf is bought once, at the **Shop Prices**
  setting's price: 10 rupees, random from 10 to 99, or random from 10 to 200 (rounded to 5; above 99 needs the
  Adult's Wallet in the logic). One
  shelf of every purchase you need (shields, tunics, Blue Fire, bugs, fish, fairies) stays on sale. A shuffled
  shelf is now a new actor at that spot instead of an edited shelf type, which is what lets the bazaars and
  potion shops take part.
- **Business Scrubs** (experimental; from OotrR): the four scrubs that sell one thing once (the Lost Woods stick
  and nut upgrades, the Hyrule Field and Death Mountain Crater Pieces of Heart) sell random items. The price is
  its own setting, **Business Scrub Prices**: 10 rupees, the game's price (40 / 100), random from 10 to 99 or
  random from 10 to 200 (above 99 needs the Adult's Wallet in the logic). Each scrub's sale line names the item
  it really sells ("Ohhh, Silver Scale! Shimmery glimmery! It's 10 rupees."), in English in every language, like
  the hints. Settings strings from before keep their scrub price.
- **Character Gifts and Minigames** replaces Shuffle NPC & Minigame Rewards (needs further testing; from OotrR):
  every gift is now patched at the exact events OotrR lists instead of by matching the vanilla item. New checks:
  the Deku Theater's Skull Mask and Mask of Truth rewards (Deku Stick and Nut upgrades). Settings strings that
  have the old setting keep their value.
- **Shuffle Quest Rewards** (on by default, as before): Zelda's Letter, the Light Arrows and Biggoron's reward,
  which OotrR keeps apart from the gifts.
- **Gossip Stone hints** (new Hints tab, off by default). Hint Distribution: No Hints, Balanced,
  Strong or Useless (Strong and Useless experimental), using Clawshot's hint system (which follows OoT Randomizer's): areas on the Way of the
  Hero, areas that are a waste of time, where some major items are, and what some locations hold. A hint that
  names a location only goes on a stone you can read without that location's item, and unreadable stones get
  the joke lines. All 40 stones are written in every language (in English, with the names highlighted), and
  the hints are listed in the spoiler log.
- **Gossip Stones: Mask of Truth Required / No Mask of Truth** (Hints tab). Required is the original game:
  stones speak only to child Link wearing the Mask of Truth, and hints never name something you need to get
  the mask. No Mask of Truth lets every stone speak to anyone, at any age.
- **Skip Opening Movie** (Quality of Life): a new game starts in Link's house without the
  prologue movie; the game still waits for Kokiri Forest to load. From Clawshot.
- **Skip Saria's Wake-Up Scene** (Quality of Life): Saria doesn't wait at the door, walk Link
  out or greet Navi; the door is open and the pause map works. From Clawshot.
- **Skip the Great Deku Tree's Talk** (Quality of Life): his speech doesn't play and his mouth
  is open. With Mido still blocking, this happens when Mido steps aside. From Clawshot.
- **Chests Without Cutscene** (Quality of Life): big chests open without the camera move and Link's
  opening animation; Link still holds the item up. From OotrR. Small chests keep their own short opening:
  with the quick version they could not be opened at all (0.5.0 test seed 3).
- **Skip Story Scenes** (Quality of Life, experimental, needs additional testing, on by default): the story scenes that come with quest
  progress don't play, and their item is given straight away. Temple of Time: the door opening, Ganondorf,
  pulling the Master Sword and Rauru's talk in the Chamber of Sages (his Light Medallion check). Adult Temple of
  Time: Sheik's first talk, the sages' talks, Zelda's reveal and the Light Arrows. After a boss: each sage's
  awakening and medallion, and the Deku Tree, Darunia and Ruto handing over the Spiritual Stones. Leaving
  Kokiri Forest: Saria's goodbye on the bridge (the Fairy Ocarina is given at once). These scenes are played by
  the quest flows (`DoorOfTime`, `AllSage`, `Goto_HyruleCastle`, `Dm_SY_BancChange_EscapeDungeon`), so the skip is
  made there: each scene counts as seen (its `HavePlayedEvent` flag, which the quests read) and its item (the
  randomized one) is handed over with the call the scene itself used. The game's event table
  (`GameAnalyzedEventInfo`) lists, for each event, the other flows it calls; an event that calls one it doesn't
  list stops. Each changed event's row now lists `GetPouchContent` (without it, test seed 7 stayed on a white
  screen in the Chamber of Sages after the Master Sword, and in test seed 8 the Master Sword couldn't be pulled and
  Saria's bridge event gave no ocarina). Most of these scenes start on a faded screen and fade it in themselves,
  often from white (the Chamber of Sages is entered with a white fade); a skipped scene now fades in with its
  own colour, and an item scene fades in before its window (test seed 9: the Light Medallion was given behind a
  white screen, so no window showed). Rauru's talk is a talking scene, which the skip button doesn't skip. Song
  lessons, boss intros and the ending still play. Tested in-game so far: Rauru's Light Medallion and Saria's
  Fairy Ocarina (the tooltip says so). Known to still play: leaving the Temple of Time as adult and Ganon's
  Castle's first-visit scene.

### Fixed
- **Skip Epona Race** (experimental) didn't work: Epona never came to Epona's Song (test seed 10). Owning a horse
  isn't a save flag: the end of Ingo's race registers the ranch's Epona as your horse
  (`EventCopyAndRegisterOwnedHorse`), and the song only calls a registered horse. The old version also rewrote
  `Get_Epona_IsCompleted_Exp`, which is the ranch Epona's presence condition, so owning the song made her vanish.
  Now, as adult, playing Epona's Song once inside the Lon Lon Ranch fence (where the song normally calls the
  ranch horses over) does what the race's end does: Epona becomes your horse, Ingo's Epona quest is complete,
  and she comes to you. After that the song calls her anywhere you can ride. Not while riding a rented horse or
  during a race. Test seed 11 (this version's first build): an Epona appeared on Link whenever the ocarina came
  out, at any age, outside the ranch. Taking out the ocarina starts the song's flow, and Epona was named there
  as an actor the event creates when she's missing (`EventMemberCreateMethod` 0). She now uses 3, like the
  game's own flows that name Epona where she may be absent: used if she's in the scene, never created. Not yet
  tested in-game.
- **Tokensanity tooltip**: says that rupees and other refills dropped by Gold Skulltulas fall to the ground (the
  game's own pickup), while shields and real items float.
- **Small chests could not be opened** (0.5.0 test seeds 3 and 4). The map / compass / boss key fix for small
  chests sent the small chest's item step into the big chest's flow file, skipping the small chest's own item
  display. It now adds the big chest's question ("is this the dungeon's map, compass or boss key?") and its
  steps inside the small chest's own flow; small keys and every other item go through the small chest's steps
  as before. Chests Without Cutscene changes big chests only.
- **A bought shop shelf could be bought again** (Items Shuffled Per Shop, test seed 4), even after reloading:
  OotrR's `NoRespawn` setting only acts when a pickup is collected. A shuffled shelf is now hidden once you own
  its item (its `IsGet` save flag), so shelves only sell items that exist once in the seed (songs, equipment,
  key items) or keep their normal goods. Shelves that only appear later in the story (the Kokiri shop's full
  stock) aren't used.
- **Junk dropped by a Gold Skulltula** (Tokensanity, test seeds 4 to 6). A token-based rupee stayed on the
  ground after it was collected and its Skulltula came back; the game's own rupee (as OotrR drops it) fell
  instead of floating; and a token-based copy of its chest form (`TBox_Rupee_Green`, the ammo bundles, ...)
  floated but still wasn't removed when collected (test seed 6). Consumables (rupees, ammo, hearts, magic, the
  Business Scrub Seed) now drop as the game's own pickup, which falls to the ground but is collected and stays
  gone; shields float like the other items. Only the bigger Bombchu bundles have neither and stay off
  Skulltulas. The fill keeps enough other spots free for them, and if a seed runs short it moves an item that
  unlocks nothing (a Piece of Heart, ...) onto a Skulltula to make room; with more such junk than other spots, the
  last Skulltulas keep their own token instead.
- **Door of Time: Open left the door shut** (test seeds 4 and 5): the save flag it set isn't what the door
  follows. It now uses Clawshot's Open mode (the door's logic module and the Master Sword pedestal no longer
  wait for the Door of Time quest past step Ready) and starts that quest at Ready on a new save; it started at
  NotReady, which only moves on later in the story, so the door stayed shut for a player who went straight to
  the Temple of Time. Test seed 6: the door is open, so its *experimental* tag is removed.
- **Songs showed a green rupee in chests** (Songs Anywhere, 0.5.0 test seed 3). Only songs lying in the world
  had the harp model; in a chest, from a character, a scrub or a shelf, and on a Gold Skulltula, the song's own
  item actor still used its placeholder rupee model. The song items themselves now use Sheik's harp model, so a
  song looks like a harp wherever it is found.
- **Gold Skulltula drops** ([issue #2](https://github.com/AbyssDragonModding/OOTNS2-Rando/issues/2)). With
  Tokensanity, a Skulltula on a vine dropped its item where Link couldn't collect it, a dropped rupee fell
  instead of floating, and the Skulltula counted as killed (and never came back) even when its drop was
  lost. Every Gold Skulltula drop is now built on the token's own pickup, as OotrR does: it floats where the
  Skulltula died like a token, is collected by touching it, and the token's logic marks the Skulltula as
  killed only when the drop is collected. Pieces of Heart and Ruto's Letter can be Skulltula drops again.
  Confirmed in-game: drops float and are collected by touch, and a Skulltula whose drop you
  didn't collect comes back when the area reloads.
- **Own Dungeon boss keys, maps and compasses only go in chests.** A boss key could land on the boss's own
  Heart Container, behind the door it opens, so the seed couldn't be finished. On a Gold Skulltula or a
  freestanding spot they only went into the pouch without counting for the dungeon (only a chest's opening
  credits them). Small keys are unchanged. Found in a 0.5.0 test seed's spoiler.
- **The Gerudo Membership Card is no longer shuffled** (reported by Kareem from the Clawshot randomizer,
  confirmed in the game files). The guards, the wasteland gate, the Training Ground and horseback archery
  check the Spirit quest step that only the captain's scene after the carpenter rescue sets. The card itself
  only stops the guards from jailing you in the sneak areas. With Shuffle NPC & Minigame Rewards on, a card
  found elsewhere left the guards hostile while the logic expected the fortress to be open. The captain now
  always gives the card. The adult trade items were already never shuffled (they share the Cucco's slot and
  would hide it); the tooltip and the Not Supported tab now say so.
- **Boss keys, maps and compasses in small chests didn't count** (reported by Kareem from the Clawshot
  randomizer, confirmed in the game files). Only the big chest's opening credits the dungeon; the small
  chest's opening just put the item in the pouch. With Own Dungeon, a map, compass or boss key could land in
  a small chest, and the boss door stayed shut (the seed couldn't be finished) or the pause map stayed blank.
  Small Chests Only (removed below) did the same to the Boss Key chests. The small chest now gives its item
  through the big chest's item step, which credits the dungeon whatever the chest holds. Applied with Maps &
  Compasses: Own Dungeon or Boss Keys: Own Dungeon. Not yet tested in-game.

### Removed
- **Small Chests Only.** Replaced by Chests without cutscenes: Only for large chests, skips their camera and opening animation. Small chests are still vanilla.

### Changed
- **The randomizer window is now defined in XML** (`rando/ui/main.xml`), Raven's (the randomizers GUI Framework) layout format, instead of
  being built widget by widget in Python. The settings cards are still made from `rando/settings.py`, so
  adding a setting doesn't need an XML change. It looks and works the same.
- **Reorganized the settings tabs.** Main Rules and Other are replaced by tabs grouped by what they change:
  - **World**: Logic, Open Areas (Kokiri Forest, Door of Time, Zora's Fountain, Death Mountain) and Story
    Skips (Skip Child Zelda, Skip Epona Race).
  - **Items**: Quest Items (songs, stones/medallions, ocarinas, Kokiri Sword, Weird Egg), Shuffled Locations
    (freestanding items and rupees, Heart Containers, NPCs, Great Fairies, Skulltula House, Tokensanity,
    Shopsanity) and Item Pool (with Refills Need Their Item).
  - **Quality of Life**: Cutscenes (with Skip Kaepora Gaebora), Gameplay (with Saria's Song With Just an
    Ocarina and Small Chests Only) and Minigames & NPCs.
  - **Create Spoiler Log** moved to the ROM Options tab, next to the seed.
  No setting changed what it does, and settings strings from earlier versions still import.
- **Labels from test seed 12**: Skip Epona Race is now *(experimental, not working)*: Epona still doesn't come
  to Epona's Song, and its tooltip says so and says to leave it off. Big Poe Buyer Needs Only 1 Big Poe stays
  *(experimental)* (no Big Poe sold yet; the tooltip says it's not confirmed). Skip Story Scenes is
  *(experimental, needs additional testing)*.
- **Tooltips of confirmed settings** describe what they do in the game: Door of Time Open (walk in and pull
  the Master Sword without the stones, an ocarina or the Song of Time), Zora's Fountain Open (King Zora stays
  aside, Ruto's reward is still given, the quest log entry stays empty), Shuffle Songs Anywhere (no longer
  "untested"; songs show as a harp on the ground, in chests, on Gold Skulltulas and on shelves), Shuffle Kokiri
  Sword (off keeps the sword scene, also with Chests Without Cutscene), Items Shuffled Per Shop (a bought shelf
  stays gone after reloading) and Chests Without Cutscene (a story chest keeps its scene).

### Checked
- **Test seed 12:** no Epona appears when the ocarina comes out any more, but Skip Epona Race still doesn't
  work (Epona never came to the song).
- **Tested in-game (0.5.0 test seed):** Gold Skulltula drops (Tokensanity), Gossip Stones with No Mask
  of Truth and Balanced hints, Skip Opening Movie, Skip Saria's Wake-Up Scene, Skip the Great Deku Tree's
  Talk (with Kokiri Forest Closed), Chests Without Cutscene and Kokiri Forest: Closed all work, so their
  *experimental* tags are removed.
- **Tested in-game (test seeds 3 and 4):** Zora's Fountain: Open (King Zora stays moved through every load,
  Ruto's reward is given), Business Scrubs (the line names the item), Hint Distribution (Strong) and Songs
  Anywhere (the harp on the ground, in big chests, on Gold Skulltulas and on shelves) work, so their tags are
  removed. Test seed 5: Shuffle Kokiri Sword (also not shuffled; the sword chest keeps its story scene),
  Items Shuffled Per Shop (a bought shelf is gone for good) and Chests Without Cutscene (big chests quick,
  small chests normal) work, so their tags are removed. Test seed 6: Door of Time: Open works (tag removed);
  Gold Skulltula drops float, but collected junk stayed (consumables now fall as the game's own pickup).
  Test seed 7: Saria's bridge scene still played (now skipped too) and the Master Sword left a white screen in
  the Chamber of Sages. Test seed 8 (a version that skipped the Chamber of Sages): the Master Sword couldn't be
  pulled and Saria's skipped goodbye gave no ocarina. All three were the event table above. Test seed 9:
  Saria's goodbye is skipped and the Fairy Ocarina window shows; the first Master Sword pull skips to the
  Light Medallion, but its window didn't show (the fade colour above). Test seed 10: the Light Medallion window
  shows (Rauru's skip works); Gold Skulltula drops work again (rupees fall, items float); Skip Epona Race
  didn't (fixed above); the Big Poe buyer wasn't reached yet.
- **Your game files are never changed.** The generator only reads the romfs and writes every patched file
  as a copy in the mod folder. I generated a seed with 18 settings on (262 mod files: 190 patched copies
  of game files, 72 new files). Afterwards all 186,587 romfs files had the same size and modified time,
  and none were added or removed. The generator itself now refuses an output folder inside the romfs, as
  the randomizer window already did.

## 0.4.5 - 2026-11-12

### Fixed
- **Shuffle Songs: Anywhere**: a song lying in the world (freestanding, rupee or boss Heart Container spot,
  or dropped by a Gold Skulltula) looked like a green rupee, because songs have no model of their own in the
  remake. Song pickups now show Sheik's harp and keep the song's name. Like every shuffled world item since
  0.4.4, they're collected by walking into them. Not yet tested in-game.

## 0.4.4 - 2026-11-12

### Fixed
- **Skip Child Zelda**: about 1 in 15 setting combinations couldn't be generated ("no item the save can
  grant for HC Malon Egg / HC Zeldas Letter / Song from Impa"). The three checks a new save already owns
  need items the save can simply be given, and with Shopsanity, a Scarce/Minimal pool or Weird Egg shuffle
  the leftover items sometimes had none. The generator now moves a suitable item there from another check
  and puts junk in its place. Found by a 6,810-seed fill simulation.
- **Zora's Fountain: Open**: King Zora was moved aside at first, but after leaving Jabu-Jabu's Belly he sat
  in front of the door again, a softlock. The first arrival in Zora's Domain set the Zora quest back to its
  "first visit" step, and he only showed it after the area reloaded. That arrival now keeps the quest where
  Open starts it. Not yet tested in-game.
- **Tokensanity**: an item dropped by a Gold Skulltula on a vine or wall needed A to pick up, which you can't
  press while climbing, so it could only be collected with the Boomerang or Hookshot.
- **Shuffle Freestanding Items / Freestanding Rupees**: shuffled items lying in the world also needed A
  (for example the rupee spots at Zora's River).

  Shuffled items in the world are now collected by walking into them, like rupees. Pieces of Heart and
  Ruto's Letter still need A, because they use their own pickup logic. For that reason the randomizer no
  longer puts them on Gold Skulltulas. Not yet tested in-game.

- **Door of Time: Closed** logic: going to adult now also expects an ocarina and Zelda met (Impa's send-off
  is a step of the Door of Time quest). The two moat checks (Song from Ocarina of Time, HF Ocarina of Time)
  expect the same. Before, both were only implied by other rules.

### Changed
- **Labels from the 0.4.3 test run (seed W68ETAG92L):** these passed in-game and are no longer tagged:
  Skip Child Zelda, Shuffle Spiritual Stones/Medallions, Shuffle Weird Egg, Shuffle Ocarinas, Shuffle
  Freestanding Rupees, Shuffle Great Fairy Rewards, Shuffle Skulltula House Rewards, Maps & Compasses' Start
  With, Skip Kaepora Gaebora and Small Chests Only. Zora's Fountain's Open stays (needs further testing):
  King Zora is back in front of the door after leaving Jabu-Jabu's Belly. Still (experimental) because
  untested or only tested off: Door of Time's Open (the tag moved from the whole setting to that option),
  Skip Epona Race, Shuffle Kokiri Sword, Shopsanity, Big Poe
  Buyer Needs Only 1 Big Poe, Skip Area Intro Cutscenes, Excluded Locations and the other options already
  marked.
- **Tooltips** of the confirmed settings now describe what happens in-game rather than how it's done,
  and no longer say "untested". This covers Logic Rules, Guarantee Reachable Locations, Kokiri Forest,
  Open Death Mountain, Skip Child Zelda, Saria's Song, Shuffle Songs, Stones/Medallions, Freestanding Items,
  Weird Egg, Ocarinas, Freestanding Rupees, Boss Heart Containers, NPC & Minigame Rewards, Great Fairies,
  Skulltula House, Tokensanity, Start With maps and compasses, Balanced pool, Skippable Cutscenes, Bag
  Bombs Open Dodongo's Cavern, Refills, Anju, Kaepora, Bombs Without Bracelet and Small Chests.
- **Door of Time: Closed**: when the Spiritual Stones are shuffled, all three are now placed where child Link
  can reach them, so you hold them before going to adult as in the original. The game itself still only
  checks the three child dungeons. The medallions are unchanged.

### Added
- **One-click setup** for people who don't code:
  - `Setup (Windows).bat` installs Python 3.14 for your user if needed (winget, or the python.org
    installer), installs `requirements.txt` and makes `.py`/`.pyw` files open with Python.
  - `setup_linux.sh` does the same on Linux. It uses your package manager, or uv as a fallback; asks
    before using sudo; installs the packages into a private `.venv`; and adds a menu entry plus a `.pyw`
    association.
  - `Start Randomizer (Windows).bat` and `run_linux.sh` open the randomizer and install any missing
    packages first.
  - `Install Requirements.bat` is replaced by the setup script.
- **README**: a step-by-step Setup guide (game files, download, setup, start, updating, troubleshooting).

### Checked
- **Skip Child Zelda** confirmed in-game (0.4.4): a new save gets the three start checks (Zelda's Letter,
  Malon's Egg, Impa's song), Malon and Talon are at Lon Lon Ranch, and Hyrule Field has day and night.
- **Door of Time: Closed** accepts either ocarina: the altar only checks the quest step, not which ocarina
  you hold, so no patch is needed. In a simulation of 540 seeds across forest, reward, song, ocarina and
  Skip Child Zelda combinations, the three child dungeons, an ocarina and the Song of Time were always
  reachable as child.

## 0.4.3 - 2026-11-11

### Fixed
- **Shuffle Freestanding Rupees**: an item dropped by a Deku Scrub in the Deku Tree landed inside its flower,
  behind an invisible wall, so it couldn't be picked up. The three Deku Tree scrub drops are no longer rupee
  checks (109 instead of 112). Seeds made with 0.4.2 or older can have an important item stuck there, so
  make a new seed.

- **LLR Talons Chickens**: buying milk from Talon and refilling a bottle on later wins also handed out the
  check's item, so it could be collected again and again. Only his first-win prize is the check now.

### Added
- **DMT Biggoron** (Shuffle NPC & Minigame Rewards): the Biggoron's Sword at the end of the adult trade
  sequence is a check. The trade items themselves stay vanilla.
- **Big Poe Buyer Needs Only 1 Big Poe** (Other > Quality of Life, experimental, off by default).
- **Skip Kaepora Gaebora** (Other > Quality of Life, experimental, off by default): his first talks outside
  Kokiri Forest, in Hyrule Field and at Zora's River count as already seen.

### Changed
- **Shuffle NPC & Minigame Rewards** is no longer experimental: all 28 of its checks were randomized in a
  0.4.2 test seed, alongside earlier in-game checks.
- Partly confirmed settings are now labelled **(needs further testing)** in the randomizer instead of
  (experimental): Zora's Fountain's Open, Skip Child Zelda, Shuffle Spiritual Stones/Medallions, Shuffle
  Ocarinas, Shuffle Freestanding Rupees, Shuffle Skulltula House Rewards and Small Chests Only.
- Checked against the full list of minigames and NPC rewards: every one with an item reward is a check,
  except the Treasure Chest Game (its prize chest needs a minigame-only preview model for each prize) and
  Medigoron's Giant's Knife (bought, like a shop).

### Test results (0.4.2 seed)
- Small Chests Only: every big chest in the Deku Tree was small and opened with the short animation. The
  Kokiri Sword chest stays big when the sword isn't shuffled (its chest plays the sword scene).
- Shuffle Spiritual Stones/Medallions: Anywhere: beating the Deku Tree gave its random item.
- Shuffle Skulltula House Rewards: all five rewards random in the spoiler.

## 0.4.2 - 2026-11-11

### Fixed
- **Small Chests Only**: in 0.4.1 the swapped chests couldn't be opened. The 0.4.1 change (sending the big
  chests' scripts to the small chest's opening) is undone. Instead, chests whose script only adds a Navi line
  or a camera move lose that script and open like normal small chests. The eleven chests whose script runs
  a story event (Nabooru, the Serenade of Water, Ruto in Jabu-Jabu, Dampé's race, Ganon's Castle's Golden
  Gauntlets, the Ice Arrow quest, the vanilla Kokiri Sword) stay big chests.

### Changed
- Every setting or option that isn't confirmed in-game is now marked experimental: Kokiri Forest's Closed
  Deku, Zora's Fountain's Open, No Logic, Required Only, Skip Epona Race, Shuffle Kokiri Sword, Shuffle NPC &
  Minigame Rewards, Shuffle Great Fairy Rewards, Shuffle Skulltula House Rewards, every Maps & Compasses
  option other than Vanilla, the Scarce and Minimal item pools, and Excluded Locations.

### Test results (0.4.1 seed)
- Skip Child Zelda with a Closed forest: Mido now blocks the way without a sword and shield (the 0.4.1 fix).

## 0.4.1 - 2026-11-11

### Fixed
- **Skip Child Zelda** with a Closed forest: Mido was gone but his invisible wall still blocked the Deku
  Tree, even with a sword and shield. The Kokiri schedules read the Hyrule Castle quest, which the setting
  completes, so Mido had moved to where he stands after you've met Zelda. The Kokiri now stay on their
  before-the-castle schedules, and Mido guards the path until you show him a sword and shield.
- **Small Chests Only**: the swapped chests still played the long big-chest sequence. About 30 big chests
  run their own script (a Navi line or story flags) that jumps to the big-chest sequence; those jumps now go
  to the small chest's sequence. Every big chest in the game is now swapped, not only the randomized ones.

### Test results (0.4.0 seed)
- Working: Open Death Mountain (On), Tokensanity (Overworld Only).
- Partly working: Skip Child Zelda (starting items and day/night confirmed; the Mido bug is fixed above),
  Shuffle Spiritual Stones/Medallions: Anywhere (a medallion at a freestanding spot works; dungeon rewards
  not tested yet), Small Chests Only (fixed above).

## 0.4.0 - 2026-11-11

### Added
- **Item tracker** (`Tools/OOTNS2-Tracker`): a clickable tracker for items, songs, stones, medallions and
  counters, with save/load. It takes its icons from your own extracted romfs; no game files are included.
- **Small Chests Only** (Other > Quality of Life, experimental, off by default): big chests and Boss Key
  chests use the small chest, so opening one skips the long big-chest animation.
- **Market Big Poe Bottle**: the bottle the Big Poe buyer gives at 1000 points is now an NPC & Minigame
  check (Shuffle NPC & Minigame Rewards).

### Fixed
- **Zora's Fountain: Open**: King Zora still blocked the Fountain. The setting now also starts the Zora
  quest where showing him Ruto's Letter leaves it, which is what moves him.
- **Shuffle Skulltula House Rewards**: the 10 and 30 token rewards were still the Adult's and Giant's
  Wallet. All five rewards are now random. The two wallets go into chests as progressive wallets: the first
  one gives the Adult's Wallet, the second the Giant's Wallet.

### Test results (0.3.1 seed)
- Working: Open Death Mountain (Off), Shuffle Songs (Song Locations), Shuffle Weird Egg (Off), Shuffle
  Freestanding Rupees (Off), Shuffle Boss Heart Containers, Tokensanity (Dungeons Only), Bag Bombs Open
  Dodongo's Cavern.
- Partly working: Zora's Fountain (Open), Shuffle NPC & Minigame Rewards and Shuffle Skulltula House
  Rewards, all fixed above; Shuffle Ocarinas (the Ocarina of Time check is still untested).
- Known issue, not fixable: while holding Zelda's Letter you can't use the Cucco, because the remake keeps
  the child trade items in one slot.

## 0.3.2 - 2026-11-11

### Added
- **Skip Child Zelda** (Main Rules > Open, experimental, off by default): a new save already owns whatever
  Zelda, Malon and Impa would have given you (the items at HC Zeldas Letter, HC Malon Egg and Song from
  Impa). The Hyrule Castle quest counts as complete, so Talon and Malon are at Lon Lon Ranch and Hyrule
  Field has its normal day/night cycle from the start. Those three checks only hold items the save can
  grant directly (songs and single key items).
- **Shuffle Spiritual Stones/Medallions: Anywhere** (experimental): finishing a dungeon gives a random item,
  and the stones and medallions can be anywhere. The setting (formerly "Shuffle Dungeon Rewards") is now
  marked experimental.

### Changed
- The logic now follows finished dungeons instead of held stones and medallions, because that's what the
  remake checks. The Door of Time needs the three child dungeons, and the bridge and Light Arrows need the
  Shadow and Spirit Temples. This also fixes Dungeon Reward Locations seeds, where the logic could expect the
  bridge after the wrong two dungeons.

### Confirmed
- Shuffle Ocarinas: Saria is there for her opening greeting outside Link's house again (the 0.3.1 fix).

## 0.3.1 - 2026-11-11

### Fixed
- **Shuffle Ocarinas**: Saria's greeting outside Link's house at the start played without Saria there.
  Her bridge goodbye is now switched off at the bridge trigger itself, instead of by marking it as already
  seen, which made Saria act as if she had left the forest from the start. After the Deku Tree she waits
  by the bridge, but the goodbye (and its Fairy Ocarina) still doesn't play.

## 0.3.0 - 2026-11-11

### Added
- **Open Death Mountain** (Main Rules > Open, off by default): the Kakariko gate to Death Mountain starts
  open for child Link, so Zelda's Letter isn't needed to get past the soldier. The logic follows the
  setting. This also opens the Happy Mask Shop from the start.
- `CHANGELOG.md`, and a **Test results** section in the README listing which settings are confirmed working.

### Removed
- **Load Saves at Dungeon Entrance**. It never moved the restart point in testing.

### Changed
- **Tokensanity** and **Bag Bombs Open Dodongo's Cavern** are no longer marked experimental; both were
  confirmed working in-game.

## 0.2.1 - 2026-11-11

### Fixed
- **Bombchus** picked up without a Bomb Bag showed "Five Bombchus" but gave none, because the remake keeps
  Bombchus in the Bomb Bag. With **Refills Need Their Item** on, Bombchus are now placed in chests that
  give a Blue Rupee until you have a Bomb Bag (like arrows, bombs and seeds).
- **Open forest**: Mido still blocked the path to the Deku Tree until you had a sword and shield. The
  "Meet the Deku Tree" quest now starts past his step, so he has already moved aside.
- **Shuffle Kokiri Sword**: the original sword chest still played the sword cutscene and handed Link a
  sword that disappeared after saving and quitting. A randomized sword chest now opens like a normal chest.

### Changed
- Test checklist: a new **Partial** result (orange) next to Pass and Fail, counted in both sets of totals.
  Result cells are centred, and the Category column is wider.
- The checklist is now only written as `checklist.xlsx`. Testers export it to CSV from Google Sheets for
  bug reports.

## 0.2.0 - 2026-11-10

### Added
- **Game version check**: the randomizer hashes the game's `exefs/main` (SHA-256) and only runs on known
  versions (currently game version 1.1.1). The ROM Options tab has an **exefs folder** row (empty = the
  `exefs` folder next to the romfs), a status line that turns green for a supported version, and the
  current hash under the romfs box.

## 0.1.0 - 2026-11-10

First public release.

- README for testers: installing Python, `Install Requirements.bat`, starting the randomizer by
  double-clicking `ootr_remake.pyw`, installing seeds and using the test checklist.
- Test checklist (`checklist.xlsx` / `checklist.csv`) with the seed's settings and every check grouped
  by region, Pass/Fail dropdowns and running totals.
- **Open Folder** button that opens the output folder.
- Crash messages and `error_log.txt` when started without a console.
- **Skip Area Intro Cutscenes** marked experimental and off by default (the intros still play).
