# Squeeze Player for Roku

A Roku channel that makes your Roku TV a Lyrion (Squeezebox) player. It connects to Lyrion over SlimProto like squeezelite does, so it shows up in every Lyrion app and can join sync groups with your other players.

Version 0.1.0 runs on an onn. Roku TV with Roku OS 16. It connects, plays FLAC and MP3, and moves through tracks. How tightly it syncs with other players still needs tuning by ear. See [What to check first](#what-to-check-first).

## Install on your TV

1. **Turn on developer mode.** On the Roku remote press Home 3 times, Up 2 times, then Right, Left, Right, Left, Right. Follow the prompts, note the TV's IP address and set a password. The TV restarts.
2. **Build the channel.**

   ```powershell
   npm install
   npm run build
   ```

   This writes `out/squeeze-roku.zip`.
3. **Install it.** Either:
   - run `npm run deploy` with `ROKU_HOST` set to the TV's IP and `ROKU_PASSWORD` set to the developer password, or
   - open `http://<TV IP>` in a browser, sign in as `rokudev`, and upload the zip.

The channel opens on the TV. Developer mode allows one sideloaded channel at a time, and installing another replaces this one.

## Use it

- The channel finds Lyrion on your network by itself. If it can't, press `*` and set **Server** to Lyrion's IP address.
- The TV appears in Lyrion under its Roku name. Play to it from Material Skin, the Lyrion web page or any Squeezebox app.
- Remote: **OK** play/pause, **Left/Right** previous/next track, **`*`** settings and sync group.
- **Volume:** use the TV remote. A Roku channel can't change the TV's volume, so Lyrion's volume slider does nothing for this player.
- The channel only plays while it's open. Switching to another app stops the music.

## Sync

Lyrion keeps sync. It tells each player when to start, reads each player's play position every second, and nudges anyone who drifts. A Roku channel can only hand a URL to the TV's audio player, so it can't start or skip to the millisecond the way squeezelite does. This channel gets as close as it can:

- **Start lag** is learned. The channel measures how long the TV takes from "play" to sound and stores it in Lyrion's per-player `startDelay` setting. Lyrion then starts the group late enough to start this TV early by that amount.
- **Speaker delay** (`*` menu) is how late this TV's speakers are compared with your other players. The channel stores it in Lyrion's `playDelay` setting. Start around 50 to 150 ms for TV speakers, more for a soundbar, and adjust by ear.
- **Sync tolerance** (`*` menu) is Lyrion's `minSyncAdjust` for this player: drift smaller than this is left alone. 40 ms is the default. Raise it if you hear frequent small jumps.
- **When behind** (`*` menu) decides what happens when Lyrion asks this TV to skip ahead:
  - *restart the group in step* (default): asks Lyrion to restart the group at its current position, so every player starts together again. You'll hear a short pause. It happens at most twice a minute.
  - *seek ahead*: seeks the TV's player forward. This may not work on Lyrion's streams; try it and see.
  - *do nothing*.

The channel sets these three Lyrion settings each time it connects, so change them here rather than in Lyrion's web settings.

**Track changes.** The TV's player can't queue the next track gaplessly, so there's a short gap between tracks. Lyrion sends the next track only when this TV reports the current one has finished.

## What to check first

On a real TV, in this order:

1. The channel connects and the TV appears in Lyrion.
2. A FLAC track plays from start to finish and the next one follows. If FLAC fails, switch **Stream format** to MP3 only.
3. Pause, resume, next and previous work from both the remote and a Lyrion app.
4. Internet radio plays.
5. Sync with a squeezelite player: start a group, listen side by side, and set **Speaker delay** until they sound together. Turn on Lyrion's `player.sync` logging (Settings > Advanced > Logging) to see the corrections it sends.
6. Whether *seek ahead* works, for **When behind**.

The BrightScript debug console shows the channel's output: `telnet <TV IP> 8085`.

## Develop

| Command | What it does |
| --- | --- |
| `npm test` | Runs the protocol tests in `tests/proto_test.brs` off-device with brs |
| `npm run check` | Compiles and validates every file without packaging |
| `npm run build` | Compiles and writes `out/squeeze-roku.zip` |
| `npm run deploy` | Installs the zip on `ROKU_HOST` |
| `npm run images` | Redraws the icons and splash screen |

```
manifest                   channel name, version, icons
source/main.brs            starts the scene
source/Proto.brs           SlimProto packets, discovery, play clock (tested off-device)
components/
  MainScene.xml/.brs       Now Playing screen, remote keys, settings, sync menu
  SlimProtoTask.xml/.brs   the player: TCP 3483, drives the Audio node, reports time
  DiscoveryTask.xml/.brs   finds Lyrion with the UDP 3483 broadcast
  JsonRpcTask.xml/.brs     now-playing info, player list and commands over port 9000
  Settings.brs             settings kept in the Roku registry
tests/proto_test.brs       protocol tests
tools/                     icon drawing and sideload scripts
```

### How the player works

`SlimProtoTask` connects to port 3483 and says HELO as device 12 (the SqueezePlay family, like squeezelite), offering the formats chosen in settings. When Lyrion sends `strm s`, the task turns the HTTP request in it into a URL and gives that to the scene's Audio node.

- **Status.** The task answers with the usual STAT events: `STMc` connect, `STMl` buffer ready, `STMs` track started, `STMd` decoder ready, `STMu` underrun, `STMp`/`STMr` pause/resume, `STMf` flushed, `STMn` unsupported. It sends `STMt` heartbeats every second while playing.
- **Elapsed time.** The time it reports comes from a play clock that smooths the Audio node's position updates.
- **Sync starts.** In a sync group Lyrion sends `strm s` with autostart off. The task reports buffer-ready at once and presses play at the time Lyrion gives in `strm u`.
- **Corrections.** `strm p` with an interval pauses for that long. `strm a` (skip ahead) is handled by the **When behind** setting.

`MainScene` handles everything that goes through Lyrion's JSON-RPC: now playing, the player list, remote commands, the sync menu and the three sync settings.
