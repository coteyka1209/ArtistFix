# ArtistFix

A tweak for iOS 6 (tested on iPhone 4S, iOS 6.1.3, ARMv7): splits compound artist tags
like `"Artist 1; Artist 2"` inside the Music.app (bundle `com.apple.mobileipod`).

## What it does

1. **Artists list.** All unique individual artist names in the library are computed by
   splitting the `artist` and `albumArtist` tags on `;`. Every individual artist gets
   exactly one row of their own: with tracks tagged `"Artist 1"`, `"Artist 1; Artist 2"`
   and `"Artist 2"` the list shows strictly `Artist 1` and `Artist 2` (no
   `"Artist 1; Artist 2"` row, no duplicate `"Artist 1"`). Works with the "Group by
   album/artist" iOS Settings option both on and off.
2. **Artist song list.** A track with a compound tag appears in the list of **every**
   artist it mentions. For example, with
   - `Song 1` → tag `"Artist 1; Artist 2"`
   - `Song 2` → tag `"Artist 1"`
   - `Song 3` → artist tag `"Artist 2"`

   the `Artist 1` list = `{Song 1, Song 2}`, the `Artist 2` list = `{Song 1, Song 3}`.
3. **Album display.** In album subtitles (the "Albums" list, album headers on artist pages
   and in CoverFlow) all artists of the album's songs are listed comma-separated without
   duplicates (`"Artist 1; Artist 2"`). The `"Unknown Artist"` caption of tracks with an
   empty Album Artist is replaced with the real artist lineup. The album itself shows up
   on the page of every participating artist.

## How it works

iOS 6 stores a **single** `item_artist_pid` / `album_artist_pid` per track (the
`item_artist`/`album_artist` tables, no many-to-many link), so the database physically
cannot say "this track belongs to two artists". The database is left untouched — the
queries are extended instead:

* `%hook IUMusicCoverFlowController` — for Cover Flow (`groupingType == 12`,
  `MPMediaGroupingAlbumByArtist`) redirects album parts hidden during the merge to the
  main cover in `-_currentSongIndexInCoverFlowQuery:(BOOL)allowCreateSuffix` (clearing
  `_suffixMediaItem` and updating `_albumIndexOfCurrentSong`, so no second phantom cover
  is created) and returns the full album artist lineup (`"Artist 1; Artist 2"`) in
  `-_stringValueForProperty:ofEntityAtIndex:placeholder:` (for the `albumAlbumArtist` key).
* `%hook MPMediaItem/MPConcreteMediaItem/MPMediaItemCollection/MPConcreteMediaItemCollection - valueForProperty:`
  — for the `artist` / `albumArtist` / `artistName` / `albumArtistName` keys returns only
  the lead artist (the first component before `;`).
* `AFBuildAllArtists()` — a map of `albumArtistPID` → artists-list row name: tag components
  are collected from the library groups (`MPMediaQuery` with `MPMediaGroupingAlbumArtist`);
  names of single-tag groups count as "taken", and a group is displayed under the first
  untaken component. The raw tag is read bypassing our own normalization
  (`gAFBypassArtistFix`), otherwise `"Artist 1; Artist 2"` could not be parsed anymore.
  The map is rebuilt on `IUArtistsDataSource - setQueries:`.
* `%hook IUArrayCellConfiguration - stringForLabelAtIndex:` — normalizes the cell header
  string, but only when the entity is an `MPMediaItemCollection` (so song titles containing
  `;` are never mangled), then replaces the artists-list row name with the computed one
  (`AFArtistRowLabel`: only the `IUPlaylistCellConfiguration` class and only the main
  label, so group names in "Albums"/"Songs" stay untouched).
* `%hook MPMediaQuery - addFilterPredicate:` / `- setFilterPredicates:` — the predicate
  `albumArtistPID == <pid>` (and `artistPID == <pid>`) is replaced with
  `<property> CONTAINS "<name>"`, where the name is the row name from the map (otherwise
  the `Artist 2` row would open the `Artist 1` list). The property is chosen by
  `AFWiderArtistProperty`: if every song with `albumArtist CONTAINS name` also has
  `artist CONTAINS name`, the track's artist tag is used (it is wider — songs without an
  album artist stay visible under the artist); otherwise `albumArtist` remains, and a
  plain `artist` when the album artist is empty. Because of this the artist drill-down
  shows all of their tracks, compound tags included.

## Limitations

* The `CONTAINS` comparison is substring-based, so `"Artist 2"` formally also matches
  `"Artist 20"`. On iOS 6 `MPMediaPropertyPredicate` only offers `EqualTo` and `Contains`.
* Parsing is done on `;` — the separators `&`, `feat.`, `/` are not supported.
* A song with both an empty album artist and an empty artist tag appears in no
  artists-list row (iOS does not show a group with an empty name).

## Install

Add the Cydia/Sileo source: `http://coteyka.qzz.io` — or grab the `.deb` from
[Releases](../../releases) and install it with `dpkg -i`.

## Build

```bash
git clone https://github.com/coteyka1209/ArtistFix.git && cd ArtistFix
THEOS=~/theos make package FINALPACKAGE=1
```

Makefile: `ARCHS=armv7`, `TARGET=iphone:clang:6.1:6.0`;
`THEOS_DEVICE_IP` defaults to `192.168.31.179` (iPhone 4S, root SSH) and can be
overridden from the environment. `after-install` restarts `Music~iphone` and removes
stale log files.

## Diagnostics

`#define AF_DIAG` at the top of `Tweak.xm`:

* `AF_DIAG 0` — work mode (current state, verified on device). Fully silent: the whole
  logging subsystem (code, buffers, file I/O) is cut out by the preprocessor, and
  diagnostic hooks stay installed with empty bodies (`AFLogDetail`/`AFLogDetailArray`
  expand to no-ops).
* `AF_DIAG 1` — verbose logging into `/var/mobile/Documents/ArtistFix.log`: a dump of the
  `ML3*/MP*/IU*` classes, `SELFTEST`, `QUERYTEST`, dumps of the visible tables and a UI
  autopilot (tap an artist row + dump the drill-down).
* `AF_TEST_HIDE_COMPOSITE` (declared next to `AF_DIAG`) — **strictly `0` in work mode**.
  With `1` *every* group with a compound tag is hidden from the artists list, so together
  with the `"Artist 1; Artist 2"` group the `Artist 2` row disappears — the artist vanishes
  from the list (symptom: `[rows] groups 2 -> rows 1 (hidden 1)`). The flag only works in
  `AF_DIAG 1` builds and exists purely to test the row-hiding mechanism;
  `bash _diag/virtual_rows_test_switch.py` toggles it 1 <-> 0.

```bash
bash _diag/run_app.sh          # clear the log, restart Music.app, wait 40 s
bash _diag/pull_log.sh         # pull the log from the device into _diag/af.log
bash _diag/rows.sh             # what is actually rendered: dump rows + UILabel texts
bash _diag/drilldown.sh        # which songs opened after every autopilot tap
bash _diag/analyze.sh 1 60     # squeeze the predicates and drill-downs out of the log
```

`_diag/` also contains: `db_tags.py` / `db_tags.sh` (dump and parse tags from
`/var/mobile/Media/iTunes_Control/iTunes/MediaLibrary.sqlitedb`), `db_dump.py` (a dump
matching the real iOS 6 schema: `item` + `item_extra` + `item_artist` / `album_artist` /
`album`; result — `_diag/dbdump.txt`), `db_query.py`, `db_refs.py`, `db_schema.py`,
`reorder.py`, `quiet_hooks.sh`, `release_mode.sh` (switch to a release build), and the
binary-parsing utilities `dump_strings.py` / `scan_bin.py` / `scan_u16.py` (ASCII and
UTF-16 strings: `@"..."` literals with non-ASCII characters are stored in Mach-O as
UTF-16, plain `strings` does not show them).

*(The `_diag/` helpers are local research tooling and are not part of this repository.)*

> **Note 1:** `%hook` blocks **cannot** be hidden inside `#if`. logos declares all
> `_logos_orig$*` / `_logos_method$*` in a single list at the point of the first `%hook`,
> and if the first `%hook` ends up inside `#if AF_DIAG`, the release build fails with
> `-Wundefined-internal`. Therefore diagnostic hooks are always compiled and only their
> bodies are "switched off".
>
> **Note 2:** local variables inside diagnostic hook bodies must stay inside
> `#if AF_DIAG`: in release `AFLogDetail` is `do { } while (0)`, its arguments are not
> evaluated, and the build fails with `-Werror,-Wunused-but-set-variable`.
>
> **Note 3:** keep `AF_TEST_HIDE_COMPOSITE` at `0` in every build except experiments with
> the row-hiding mechanism. A forgotten `1` looks like "the tweak hid Artist 2", while the
> grouping logic (`AFBuildGroupNames` / `AFRowNames` / wider-artist) is fully intact —
> that is exactly what the `0.0.2-20+debug` debugging was about.

## Verified on device (iPhone 4S, iOS 6.1.3)

`AF_DIAG 1`, autopilot: the artists list = 3 rows (`All Songs` + two artists).

```
[names] строки исполнителей: {8668412679042481770 = "Artist 2"; 6289584557699490344 = "Artist 1";}
[rowlabel] idx=0 'Artist 1' -> 'Artist 1' pid=6289584557699490344
[rowlabel] idx=0 'Artist 1; Artist 2' -> 'Artist 2' pid=8668412679042481770
[split] albumArtistPID == 6289584557699490344 -> albumArtist CONTAINS 'Artist 1' => ("Song 1","Song 2")
[split] albumArtistPID == 8668412679042481770 -> artist CONTAINS 'Artist 2' => ("Song 1","Song 3")
```

`AF_DIAG 0` (release, verified on `0.0.2-22+debug`) — same result, a 6-line log, no
autopilot or dumps (log-file output was later removed from work mode entirely, see
Diagnostics above).

## Known cosmetic quirks

* In the drill-down of the `Artist 2` group the album subtitle shows `Artist 1`: that is
  the album's own subtitle (its tag is `Artist 1; Artist 2`, normalized to the lead
  component), not the group name.
* `CONTAINS` is a substring comparison (see Limitations): exact matching by tag components
  would require filtering the already-fetched `items` additionally.

## License

[MIT](LICENSE).
