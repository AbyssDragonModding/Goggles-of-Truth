# Changelog

What changed in each version of the randomizer. A new setting or feature raises the middle number (0.**7**.0), a
fix raises the last number (0.7.**5**).

**Placement version:** since 0.7.4, every seed records a placement version in its `settings.txt`. Versions with
the same placement version put items in the same places, so you can rebuild an older seed with a newer version and
keep your saves. When a version changes where items go, it gets a new placement version.

## 0.8.0 - 2026-11-26

New placement version (0.8.0). Seeds made with 0.7.x can't be rebuilt with this version. They still play fine
with the version that made them, and your saves are safe. Make a new seed to get the new features.

### New
- **Progressive items.** Upgrades now come in order, whichever copy you find first: the first Progressive Hookshot
  is the Hookshot and the second the Longshot. The same goes for the Ocarinas (Fairy Ocarina, then Ocarina of Time),
  strength (Goron Bracelet, Silver Gauntlets, Golden Gauntlets), the scales (Silver, then Golden), the wallets
  (Adult's, then Giant's), the bomb bags (Bomb Bag, Bigger, Biggest), and the bigger Deku Seed bags and quivers.
  The spoiler log, the hints and the Business Scrubs call them "Progressive ..." because what you get depends on
  what you already have. They are found in small chests and given by characters, minigames and Business Scrubs,
  never lying on the ground, on a Gold Skulltula, on a shop shelf or in a big or invisible chest.
- **Progressive Items can be turned off** (Items tab, on by default). Off, the Hookshot, scales, strength upgrades
  and bomb bags are items of their own and can be in any check, as in 0.7. A stronger one is put where you need the
  weaker one first when the logic allows it, so you may still find a stronger one first. The Ocarinas, wallets,
  Deku Seed bags and quivers stay progressive.
- **Starting Age**: Child, Adult or Random. As an adult, a new game starts straight in the Temple of Time's main
  hall, facing the Master Sword room, with the Master Sword equipped and your start items handed over right away;
  young Link never shows. Rauru's item is already yours, and the Door of Time is open. Put the sword back to become
  a child. Random picks one for the seed, and the spoiler log says which. Not tested in-game yet.
- **Barren Dungeons**: 1 to 5 dungeons, or a random number, hold nothing but rupees (plus their own keys when keys
  stay in their dungeons). The Medallion or Stone you'd get for beating a barren dungeon, its boss's Heart
  Container, and Sheik's song in a barren Ice Cavern are put somewhere else in the seed. The altar in the Temple of
  Time tells you which dungeons are barren on its second page. Not tested in-game yet.
- **Starting Inventory**: a new tab where you pick items a new game starts with: equipment, items, upgrades, songs
  and hearts. Items with tiers count up (add the Hookshot twice for the Longshot). The logic knows you have them,
  and the seed won't hide a second copy (a Blue Rupee takes its place). Not tested in-game yet.
- **Item Restrictions** on the Exclusions tab: keep a chosen item away from a chosen location, and the seed puts
  it somewhere else. Pick a location in the list, pick an item, then click Forbid. A Progressive item covers every
  tier (Progressive Bomb Bag means any bomb bag).
- **Skip NPC Dialogs**: characters skip their long story talks and go straight to their short line, for example
  Saria after the Deku Tree. Talks that give an item or move a quest on still play. A setting of its own while it's
  being tested; it will become part of Skip Cutscenes. Not tested in-game yet.
- **The medallions menu opens whenever a boss, sage or character hands you a Spiritual Stone or Medallion**, as it
  does after the Deku Tree, and once when a new game starts with one. With Shuffle Spiritual Stones/Medallions on
  Anywhere, a Stone or Medallion found in a chest, a shop or on the ground doesn't open it. Its message now reads
  "Added to Key Items" (it used to always say Kokiri Emerald; the item window before it names the item). If only
  the start opens it, it names the Stones and Medallions you start with.
- **Updates from inside the window:** when the randomizer opens, it checks for a newer release. If there is one, it
  asks first, then downloads the version for your system, installs it and opens again. Your settings, presets and
  seeds are kept. Turn the check off, or check any time, in the new Updates card on the General Settings tab.
- **Crash reports:** if the randomizer window ever crashes, it saves a report in a `crash_logs` folder next to the
  program and tells you where. Attach it to your bug report.
- **Window themes:** pick how the randomizer window looks at the top of the window, next to Open Folder: its own
  Goggles of Truth theme (frosted glass over the night sky), light or dark, glass, high contrast, or the look of
  Windows, macOS or GNOME. It changes right away and is remembered.
- **Test seeds from a plan file**, first released early in 0.7.8, now with the parts that needed 0.8.0: a test
  start can give items already owned, and a plan can set Starting Inventory and Item Restrictions. Building the
  window yourself in debug mode adds a Test Seeds tab for them.

### Changed
- **Buttons are pill shaped**, with a bit more room on their sides.
- **Searchable drop-downs:** the long lists (seed presets, exclusions, Item Restrictions, Starting Inventory and
  themes) let you type to find an entry. When there's no room below, the list opens upward.
- **Stable badges:** Starting Age (Child, Adult and Random), Barren Dungeons, Starting Inventory, Item Restrictions
  and Progressive Items are marked Stable, and so is "Poe shop requires only 1 Big Poe" (it has worked since 0.7.6;
  only its badge was wrong). Skip Cutscenes and Skip NPC Dialogs are still In Testing.
- **Seed presets use the new settings:** Beginner, Standard and Race now need only one Big Poe for the Poe shop,
  and Expert starts at a random age. All four keep progressive items on.
- **The ROM Options tab is now called General Settings.**
- **Skip Area Intro Cutscenes is now part of Skip Cutscenes.** Turning on Skip Cutscenes also skips the area intros.
  Old settings still work: if you had the area intros skipped, Skip Cutscenes is turned on for you.
- **The Skulltula House wallets** can now also be given by characters, minigames and scrubs, not only chests.
- **Boss Keys is back in the main Dungeon Items card** on the Dungeon Items tab, above the Key Ring Dungeons.
- **The Not Supported tab is gone.**

### Fixed
- **Items lying underwater couldn't be picked up:** an invisible block sat above them that Link could stand on
  (a player found it over an Ocarina in the Kokiri Forest pond next to Mido). Items lying anywhere in the world now
  behave like the rupees they replace: nothing solid around them, and they're a little easier to grab. Not tested
  in-game yet.
- **Refills Need Their Item gave a Blue Rupee even when you had the item** (arrows with the Bow, for example). Those
  refills now only go in small chests, which give the refill once you own its item. Not tested in-game yet.
- **A seed could hide your only Bomb Bag behind a rock that needs bombs.** The logic thought young Link could break
  the rocks over the Lost Woods and Hyrule Field scrub grottos with the Megaton Hammer, which only adult Link can
  use. Seeds no longer count on that.
- **Your first Bomb Bag is never behind a bombable rock or wall** (or anything else that needs bombs or the Megaton
  Hammer to get at), even if the logic could reach that spot another way. A new base rule, always on. With
  Progressive Items off, this covers every bomb bag, since a bigger one can be the first you find.
- **Young Link can't use the Silver or Golden Gauntlets.** The logic counted them as the Goron Bracelet for young
  Link (bomb flowers, Dodongo's Cavern, and bag bombs when they need lifting), so a seed could expect him to lift
  something he can't. Places only young Link can reach now need the Goron Bracelet itself.
- **You can put the Master Sword back as soon as you've been an adult**, not only after the Forest Temple, so a
  seed never needs the Forest Temple before you can be a child again. Sheik now waits by the door of the sword room
  instead of behind the pedestal. The Forest Temple and the Prelude of Light play as before. Not tested in-game yet.
- **The Hyrule Field scrub's Piece of Heart** now waits until you can reach that area as an adult (to learn his
  password) and as a child with bombs. Not tested in-game yet.

## 0.7.8 - 2026-11-25

Bug fixes, and 0.8.0's test seeds released early. Items stay in the same places, so you can rebuild any 0.7.6 or
0.7.7 seed with **Rebuild Seed** to get these fixes and keep your saves.

### New
- **Test seeds from a plan file** (for test seeds, on the command line), brought over early from 0.8.0. One small
  file says which items go where and how a new game starts: in which area and spot (or at exact coordinates), as a
  child or an adult, at what time of day, with quests already at a chosen step, and with cutscenes counted as seen
  or not seen, so you can start right before the thing you want to test. Making the plan again keeps the seed and
  its saves. `test_plans/TEMPLATE.test.toml` explains everything, and a second command lists every area, spot,
  quest, cutscene, location and item name you can use.
- The parts of it that rely on 0.8.0's changes were left out and come with 0.8.0: starting with items already
  owned (a plan that asks for them says so; place the items at nearby checks instead), and the hint for placing
  progressive items. Starting an event on arrival is not tested yet.

### Fixed
- **Two Malons and two Talons at Hyrule Castle.** If you got the Goron Ruby before meeting Zelda, Malon and Talon's
  later visit showed up next to their first one. Now Malon stays at her first visit until you've met Zelda, and
  moves on after your next dungeon.
- **Items sinking into or floating above shop shelves.** Every shop shelf a randomized item can go on now has its
  shelf height worked out from the shelves around it, so items rest on the shelf in every shop (the Bombchu Shop
  keeps its old placement). This fixes items sinking behind the price board on the Bazaars' arrow shelves and the
  Zora Shop's arrow spots, and items floating in the Potion Shops' pot spots. The Silver and Golden Scales and the
  Bomb Bags, which sank into any shelf, now rest on it too.
- **The Weird Egg never hatched** when you found it after the point where Malon's egg would hatch (with Shuffle
  Weird Egg on). Every Weird Egg the randomizer gives you is now the hatched Cucco straight away, ready to wake
  Talon. The spoiler log and hints still call it the Weird Egg. Not tested in-game yet.

## 0.7.7 - 2026-11-24

Bug fixes only. Items stay in the same places, so you can rebuild any 0.7.6 seed with **Rebuild Seed** to get these
fixes and keep your saves.

### Fixed
- **Buying an Ocarina from a Business Scrub crashed the game** (Shuffle Ocarinas with Business Scrubs, reported in
  [issue #5](https://github.com/AbyssDragonModding/Goggles-of-Truth/issues/5)). Link now holds up the Ocarina the
  same way as when it comes out of a chest. This also covers Ocarinas given by characters and minigames.
- **An Ocarina from a Business Scrub, a character or a chest couldn't be used**: no tutorial, and no Ocarina button on
  screen. You now get the real Ocarina with its tutorial, as when Saria gives it to you. Tested with chests and scrubs;
  characters not tested in-game yet.

## 0.7.6 - 2026-11-24

New placement version (0.7.6). Seeds made with 0.7.5 or earlier can't be rebuilt with this version. They still
play fine with the version that made them, and your saves are safe.

### Changed
- **Rebuild Seed explains itself** when a seed comes from a different placement version: it tells you why it can't
  rebuild it, and that the seed and its saves are safe and can still be played.
- **Maps & Compasses "Remove" and "Start With" are now stable.**
- **Skip Epona Race is now stable.** Its description now says you get Epona just by having Epona's Song. There's
  no race, and you don't need to visit Malon as a child first.
- **Dampé's gravedigging tour always has its prize in the same spot:** the dig spot in front of the Hylian Shield
  grave. Have Dampé dig there, pay the extra rupees he asks for, and the prize comes out. Before, it was a rare
  random dig, so you could dig every spot and never find it. The other spots give rupees.

### Fixed
- **Maps & Compasses "Remove":** map and compass chests now hold a Blue Rupee, as the setting says. Before, they
  held random items, which is what "Start With" does.
- **Big Poe buyer (1 Big Poe):** selling him one Big Poe now gives you his reward and the reward is now randomized. (1000 points unchanged)
- **Dungeon reward scenes show the real item** (with Skip Cutscenes off). When a sage, Rauru or Zelda hands you
  something, you now see the randomized item instead of the usual medallion or Light Arrows. The Spiritual Stone
  scenes do the same, and the Deku Tree's scene now shows the normal item window instead of the Kokiri Emerald.
- **Key rings, boss keys, medallions and Spiritual Stones spin** on the ground like other items.
- **Key rings and boss keys are held up like a key.** Before, Link held them up in an odd pose.
- **Dampé's gravedigging tour** digs up the item you'll get, instead of always showing a Piece of Heart.
- **Dampé's gravedigging tour gives its own item.** A duplicate "Dampé Race Reward" check was replacing it with
  another item. The race's real prize is the chest at the end of the race, which is still a check.
- **Shop shelves:** items on the Red Potion's shelf no longer sink into it.
- **Making a new seed while the game is running** is now refused, with a message to close the game first. Before,
  the game kept your older seeds switched on, so it loaded several seeds at once.

### For testers
- Test seeds can place items that aren't normally in the item pool (for example a Big Poe in a bottle).
- An item placed on a character's gift in a test seed now shows its own model and name there, as it does in a
  normal seed.

## 0.7.5 - 2026-11-24

Bug fixes only. Items stay in the same places, so you can rebuild any 0.7.3 or 0.7.4 seed with **Rebuild Seed**
(ROM Options > Seeds and saves) to get these fixes and keep your saves.

### Fixed: every seed
- **Items on the ground sit at the right height.** Some items floated in the air or sank into the ground (such as
  the Gauntlets floating, or an item half inside a stump in the Lost Woods). Items are also never lowered so far
  that you can't pick them up.
- **The Gauntlets and the Goron Bracelet show up** when they're lying on the ground. Before, they were invisible.
- **Every new save comes with the basic Deku Seed bag and quiver**, so finding the Slingshot or Bow early gives you
  ammo for it.

### Fixed: Shop Shuffle
- **Items sit on their shelves** instead of sinking into them or floating above them.
- **Big items are shown at half size** so they fit on the shelf.
- **A bought shelf's price sign disappears** along with the item.

### Fixed: Shuffle Ocarinas
- **The ocarinas show up when you find them in a chest.** Before, they were invisible.

### Fixed: Songs Anywhere
- **Songs found in chests show a spinning harp** in Link's hands.
- **Songs on shop shelves show the harp facing you**, at a size that's easy to see (needs Shop Shuffle too).

## 0.7.4 - 2026-11-23

### Added
- **Rebuild Seed** (ROM Options > Seeds and saves): rebuild one of your seeds with this version's fixes. Every item,
  price and hint stays where it was, and your saves keep working.
- **Launch Game** button (top right): starts Longshot or your emulator. You can set which program it opens on the
  ROM Options tab. It won't open a second copy if the game is already running.
- **For testers:** test seeds can put a chosen item at a chosen location.

### Changed
- **Bug-fix versions no longer change your seeds.** The same seed number and settings now put items in the same
  places until a version actually changes where items go (see "Placement version" at the top).
- **Your saves are safer.** Rebuilding a seed keeps its saves, and the randomizer never deletes an older copy of
  your saves: it moves it to the `save_backups` folder instead.
- **Making a seed into a folder that's already there** replaces the old mod files, so nothing from the old build is
  left behind. Your saves in that folder stay.
- **Skip Story Scenes is now called Skip Cutscenes.** It now also skips the Royal Family's Tomb scenes in the
  Kakariko Graveyard, including the Sun's Song lesson. You get the item right away. Not tested in-game yet.

### Fixed
- **Longshot is found on Linux again.** Not tested on a Linux machine yet.
- **Bag Bombs Open Dodongo's Cavern:** a bag bomb now breaks the boulder like a normal bombable rock, with no
  cutscene. Before, it could softlock the game.

## 0.7.3 - 2026-11-22

### Added
- **Lost Woods Skull Kid ocarina game** gives all three rewards after one song.
- **Key rings and boss keys outside their dungeon** (Dungeon Items tab, experimental), based on OotrR:
  - **Small Keys: Any Dungeon / Overworld / Anywhere:** each dungeon's small keys become one key ring, which gives
    all of that dungeon's keys at once.
  - **Key Ring Dungeons:** choose which dungeons get key rings: all, the ones you pick, or random ones.
  - **Boss Keys: Any Dungeon / Anywhere:** each temple's boss key can be found anywhere and opens that temple's
    boss door. Ganon's Castle's boss key stays in its chest.
  - **Removed:** you start with every small key or boss key.
  - A dungeon's key ring and boss key are never placed inside that same dungeon.
  - Not tested in-game yet.
- **Save your own presets:** type a name and click **Save Preset**. **Delete Preset** removes one.
- **Race preset:** a fast, fair seed for racing.
- **THIRD_PARTY.md:** credits and licenses for the code this project uses from other projects.

### Changed
- **Generate Mod always makes a new seed.** If the seed number in the box was already used, it picks a new one.
  (This worked in the Python version but was lost in the move to Zig.)
- **Beginner, Standard and Expert presets** were updated to better match their difficulty.
- **The Not Supported tab** no longer lists hints, keysanity and scrubsanity, since they're all supported now.
- **The file cache is always on.** It makes seeds faster and doesn't change them.
- **Making seeds uses about 75% of your CPU**, so it's faster on computers with more cores and your computer stays
  responsive.
- **New downloads for Windows and Linux on ARM** (command-line only for now).

### Fixed
- **A Gold Skulltula's drop could give you nothing** (for example a bigger bag or wallet).

## 0.7.2 - 2026-11-22

**Seeds are made 3–6× faster:** about 2 seconds instead of 10.

### Changed
- **Making a seed uses several CPU cores at once.** The seeds themselves are exactly the same.

### Added
- **File cache** (ROM Options > Output): saves parts of earlier seeds so later seeds are made faster. It never
  changes a seed, and it can be deleted at any time.

## 0.7.1 - 2026-11-21

### Fixed
- **The randomizer could crash while making a seed** in some cases (for example with the Expert preset's hints).
  Mods made with 0.7.0 were not affected.

## 0.7.0 - 2026-11-21

The randomizer has been rewritten in Zig.

### The Zig rewrite
- **One small program, nothing to install.** No more Python or setup scripts: unzip it and run it, on Windows,
  Linux or macOS.
- **Seeds are made 2–3× faster.**
- **A seed number gives a different seed** than it did in the Python version.
- **Settings strings still work** between the Python and Zig versions.
- **Updating:** download the new version and copy your `user_settings.toml` into its folder.

### Deprecated
- **The Python version** (0.6.1 and earlier) won't get any more updates. It's kept under the `python-legacy` tag.
- **The Python item tracker** won't get any more updates either. A new one will come later.

### Added
- **The Temple of Time altar tells you what the Rainbow Bridge needs**, and how much of it you have (for example
  "Medallions: 2/4").
- **Character gifts and minigames show and name the real item.** Gifts like Darunia's bracelet or Biggoron's sword
  show the randomized item's model, and their text names it ("I'll give you the Hover Boots!").
- **Lost Woods Skull Kid ocarina game** gives all its rewards after one song (every seed).

### Changed
- **Skip Epona Race works a new way:** a new save already owns Epona, and playing Epona's Song as adult calls her.
  No race needed. Confirmed in-game.
- **Open Death Mountain removes Zelda's Letter** from the seed, since it has no use there. Zelda gives a random
  item instead.
- **Skip Child Zelda's three starting checks can hold any item.** Before, they could only hold certain items.
- **Shop Shuffle puts a real item on more shelves.** Before, most chosen shelves looked unchanged because they got
  junk.
- **The Kokiri Shop is now part of Shop Shuffle.**

### Fixed
- **The Kokiri Sword chest** no longer plays the sword scene when Skip Story Scenes is on.
- **A Gold Skulltula that dropped a rupee came back** after you picked the rupee up. It now stays dead.

## 0.6.1 - 2026-11-16

### Added
- **Rainbow Bridge Requirement** (World tab): choose what makes the bridge to Ganon's Castle appear: **Vanilla**,
  a number of **Medallions**, all three **Spiritual Stones**, or a number of **Gold Skulltula Tokens**. Every option
  also needs the Bow and Light Arrows. All four options are confirmed in-game.
- **Number boxes** in the window for the medallion and token counts.
- **Per-Seed Saves** (ROM Options > Output, on by default): each seed keeps its own save slots, in Longshot and in
  emulators. **Play This Seed** switches back to an older seed with its saves. Nothing is deleted without a backup.
- **Status badges:** every option shows a coloured badge: Stable (green), In Testing (yellow) or Experimental (red).

### Fixed
- **Skip Epona Race** works a new way (still experimental).
- **Epona in the logic** now also needs Malon's song check as a child.
- **The seed number now changes** when you change a setting, so you don't overwrite your last seed by accident.
- **Skip Area Intros** also skips the Temple of Time's first visit and adult Link's first look at the ruined Castle
  Town. Not tested in-game yet.
- **Excluded Locations is now stable**, and it now gives a clear error when too many locations are excluded.
- **The Gold Skulltula outside Ganon's Castle** only needs adult Link in the logic now, as in the original game.

### Changed
- **Presets** now turn on Gold Skulltulas Day and Night, Any Age, and Skip Ganon's Trials.
- **Skip Ganon's Trials** and **Gold Skulltulas Day and Night, Any Age** are confirmed in-game and no longer marked
  experimental.
- **Tooltips of stable settings** now just say what the setting does.

## 0.6.0 - 2026-11-15

The randomizer is now called **Goggles of Truth**.

### Added
- **Every seed starts outside the Kokiri Shop.** This removes the long black screen after "New Game".
- **Skip Area Intro Cutscenes skips more intros**, including the Deku Tree, Death Mountain, Goron City, Zora's
  Domain, Lon Lon Ranch, Castle Town and several dungeons. Not tested in-game yet.
- **Gold Skulltulas Day and Night, Any Age:** night-only Gold Skulltulas appear in the day, and most adult-only ones
  appear for child Link too.
- **Skip Ganon's Trials** (experimental): the six trials in Ganon's Castle are already done.
- **Longshot updates are followed:** when Longshot updates, the randomizer switches to the new version's mods
  folder.

### Fixed
- **Skip Area Intro Cutscenes:** skipped areas now count as visited, so their names and map work normally.
  Kaepora also still waits at Lake Hylia.
- **Skip Kaepora Gaebora** now skips the talks it missed (on the way to Lake Hylia and in front of Hyrule Castle).
  Not tested in-game yet.
- **Refills Need Their Item** now covers Deku Nuts and Deku Sticks.

### Changed
- **Renamed to Goggles of Truth.** Seed folders are now named `GogglesOfTruth_<seed>`. Older seeds are still
  switched off properly.
- **New GitHub address:** https://github.com/AbyssDragonModding/Goggles-of-Truth. The old address still forwards.
- **Bombs Usable Without Goron Bracelet** is now called **Bag Bombs without Goron Bracelet**. Old settings still
  work.
- **Skip Story Scenes skips many more scenes**: what happens after each boss, the scenes before the adult temples,
  and Ganon's Castle's trials. Song lessons, boss fights and the ending still play.
- **Skip Story Scenes:** confirmed in-game for the Deku Tree after Gohma and Saria on the bridge.

## 0.5.1 - 2026-11-15

### Added
- **Longshot support:** a **Longshot** button finds your Longshot game and puts seeds in its mods folder. Older
  seeds are switched off automatically (renamed, never deleted).
- **Automatic updates** for people who downloaded with git. It never overwrites your own changes, and it can be
  turned off.

### Fixed
- **Skip Kaepora Gaebora** now also skips his Lost Woods talk after Saria's Song.
- **A starting ocarina couldn't be played** with Skip Child Zelda. Confirmed fixed in-game. Make a new save.

## 0.5.0 - 2026-11-13

### Added
- **Your settings are saved in `user_settings.toml`** next to the program, every time you change something.
  Delete the file to reset everything.
- **Presets: Beginner, Standard and Expert.**
- **Read the game straight from a `.nup` file**, as well as from an extracted romfs folder. Your game files are
  never changed.
- **The item tracker can read a `.nup` too.**
- **Items Shuffled Per Shop** (experimental, from OotrR): every shop sells 1 to 4 random items, each bought once.
  Set the prices with **Shop Prices**.
- **Business Scrubs** (experimental, from OotrR): the four scrubs that sell one item sell random items, and say
  what they're selling.
- **Character Gifts and Minigames** replaces Shuffle NPC & Minigame Rewards. New checks: the Deku Theater's Skull
  Mask and Mask of Truth rewards.
- **Shuffle Quest Rewards:** Zelda's Letter, the Light Arrows and Biggoron's reward.
- **Gossip Stone hints** (new Hints tab). Choose how strong the hints are. Hints are in the spoiler log too.
- **Gossip Stones: Mask of Truth Required / No Mask of Truth.**
- **Skip Opening Movie**, **Skip Saria's Wake-Up Scene** and **Skip the Great Deku Tree's Talk** (from Clawshot).
- **Chests Without Cutscene** (from OotrR): big chests open quickly. Small chests keep their normal opening.
- **Skip Story Scenes** (experimental): many story scenes don't play, and you get their item right away.

### Fixed
- **Skip Epona Race** didn't work (still experimental).
- **Small chests couldn't be opened.**
- **A bought shop shelf could be bought again.**
- **Junk dropped by a Gold Skulltula** could stay on the ground after you picked it up.
- **Door of Time: Open** left the door shut. It now works.
- **Songs looked like green rupees** in chests and other places. They now look like a harp everywhere.
- **Gold Skulltula drops** on vines couldn't be collected. Drops now float where the Skulltula died.
- **Own Dungeon boss keys, maps and compasses only go in chests**, since they didn't count anywhere else.
- **The Gerudo Membership Card is no longer shuffled**, since a shuffled one left the guards hostile.
- **Boss keys, maps and compasses in small chests didn't count.**

### Removed
- **Small Chests Only.** Replaced by Chests Without Cutscene.

### Changed
- **The randomizer window is now built from an XML file.** It looks and works the same.
- **The settings tabs are reorganized** into World, Items and Quality of Life. Old settings strings still work.
- **Tooltips** of confirmed settings now describe what they do in the game.

### Checked
- **Your game files are never changed** by the randomizer.
- Many settings were confirmed in-game and are no longer marked experimental.

## 0.4.5 - 2026-11-12

### Fixed
- **Songs Anywhere:** songs lying on the ground looked like a green rupee. They now show Sheik's harp.

## 0.4.4 - 2026-11-12

### Fixed
- **Skip Child Zelda:** some setting combinations couldn't make a seed.
- **Zora's Fountain: Open:** King Zora moved back in front of the door after Jabu-Jabu's Belly, which could
  softlock the game.
- **Items dropped by Gold Skulltulas on walls** and **shuffled items on the ground** are now collected by walking
  into them, instead of pressing A.
- **Door of Time: Closed:** the logic now expects an ocarina and meeting Zelda before going to adult.

### Changed
- Many settings were confirmed in-game and are no longer marked experimental.
- **Tooltips** now describe what happens in-game.
- **Door of Time: Closed:** when the Spiritual Stones are shuffled, all three are placed where child Link can reach
  them.

### Added
- **One-click setup** for Windows and Linux.
- **A step-by-step setup guide** in the README.

## 0.4.3 - 2026-11-11

### Fixed
- **Shuffle Freestanding Rupees:** an item dropped by a Deku Scrub in the Deku Tree could get stuck behind an
  invisible wall. Those three spots are no longer checks. Make a new seed.
- **Talon's Cuccos:** his prize could be collected again and again.

### Added
- **Biggoron's Sword** is now a check.
- **Big Poe Buyer Needs Only 1 Big Poe** (experimental).
- **Skip Kaepora Gaebora** (experimental).

### Changed
- **Shuffle NPC & Minigame Rewards** is no longer experimental.
- Partly confirmed settings are now labelled **needs further testing**.

## 0.4.2 - 2026-11-11

### Fixed
- **Small Chests Only:** the swapped chests couldn't be opened.

### Changed
- Every setting that isn't confirmed in-game is now marked experimental.

## 0.4.1 - 2026-11-11

### Fixed
- **Skip Child Zelda** with a Closed forest: Mido's invisible wall blocked the Deku Tree even with a sword and
  shield.
- **Small Chests Only:** swapped chests still played the long big-chest opening.

## 0.4.0 - 2026-11-11

### Added
- **Item tracker:** a clickable tracker for items, songs, stones, medallions and counters.
- **Small Chests Only** (experimental): big chests use the small chest's quick opening.
- **The Big Poe buyer's bottle** is now a check.

### Fixed
- **Zora's Fountain: Open:** King Zora still blocked the Fountain.
- **Skulltula House rewards:** all five rewards are now random.

### Known issue
- While holding Zelda's Letter you can't use the Cucco, because the remake keeps the child trade items in one
  slot. This can't be fixed.

## 0.3.2 - 2026-11-11

### Added
- **Skip Child Zelda** (experimental): you start with what Zelda, Malon and Impa would give you, and Hyrule Field
  has its normal day and night.
- **Shuffle Spiritual Stones/Medallions: Anywhere** (experimental).

### Changed
- The logic now follows finished dungeons instead of held stones and medallions, since that's what the remake
  checks.

## 0.3.1 - 2026-11-11

### Fixed
- **Shuffle Ocarinas:** Saria was missing from her greeting at the start of the game.

## 0.3.0 - 2026-11-11

### Added
- **Open Death Mountain:** the gate to Death Mountain starts open, so you don't need Zelda's Letter.
- This changelog, and a list of confirmed settings in the README.

### Removed
- **Load Saves at Dungeon Entrance.** It never worked in testing.

### Changed
- **Tokensanity** and **Bag Bombs Open Dodongo's Cavern** are no longer experimental.

## 0.2.1 - 2026-11-11

### Fixed
- **Bombchus** found without a Bomb Bag gave nothing. With **Refills Need Their Item**, they now give a Blue
  Rupee until you have a Bomb Bag.
- **Open forest:** Mido still blocked the path to the Deku Tree.
- **Shuffle Kokiri Sword:** the original sword chest still played the sword scene, and the sword disappeared after
  saving.

### Changed
- The test checklist has a new **Partial** result.

## 0.2.0 - 2026-11-10

### Added
- **Game version check:** the randomizer only runs on supported game versions (currently 1.1.1).

## 0.1.0 - 2026-11-10

First public release.

- Setup guide for testers.
- Test checklist with every check grouped by region.
- **Open Folder** button.
- Error messages and an error log when something goes wrong.
