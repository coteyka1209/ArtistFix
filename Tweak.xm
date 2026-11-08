// ArtistFix — a tweak for the iOS 6 Music.app
// Goal: split compound artist tags like "Artist 1; Artist 2" into separate artists.
//
// AF_DIAG = 1 — diagnostics: dump of ML3*/MP*/IU* ObjC classes + a log of every UI query
// to the media library
// AF_DIAG = 0 — work mode (verified on device, see README)

#define AF_DIAG 0

// AF_TEST_HIDE_COMPOSITE = 1 — mechanism test only: hides every artist-list group whose
// tag is compound (in normal operation only the groups that did not get a free component
// are hidden). Keep 0 in normal use: with 1, an artist disappears from the list whenever
// their group has a compound tag ("Artist 1; Artist 2" → the "Artist 2" row disappears).
// Enabled only for experiments: bash _diag/virtual_rows_test_switch.py (the same script
// sets it back to 0). Note: the flag only affects diagnostic builds (AF_DIAG 1).
#define AF_TEST_HIDE_COMPOSITE 0

// AF_ENABLE_AUTOPILOT = 1 — UI autopilot (switches tabs, taps artist rows automatically
// for testing). Keep strictly 0 in normal use, otherwise the Music app taps its own buttons.
#define AF_ENABLE_AUTOPILOT 0

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>

// Private MediaPlayer classes (not declared in the public SDK headers)
@interface MPConcreteMediaItemCollection : MPMediaItemCollection
@end

// Private iPodUI (IU) class: media-library entity cell configuration
@interface IUMediaEntityCellConfiguration : NSObject
- (id)entity;
- (id)displayProperties;
- (void)setSubtitle:(id)subtitle;
@end

@interface IUAlbumCellConfiguration : IUMediaEntityCellConfiguration
- (void)reloadStringsWithProperties:(id)props;
@end

@interface IUArrayCellConfiguration : NSObject
- (unsigned int)numberOfLabels;
- (id)stringForLabelAtIndex:(int)idx;
- (id)entity;
@end

// The base data source of the lists (artists/albums/songs) and the per-query source:
// needed as a full @interface, otherwise [self class] inside a hook body produces
// -Werror,-Wforward-declaration (AF_DIAG 1).
@interface IUMediaQueriesDataSource : NSObject
- (void)setQueries:(id)queries;
@end

@interface IUMediaEntitySpecifier : NSObject
@end

// CoverFlow (iOS 6 Music): the cover-flipping controller and its views
@interface IUCoverFlowViewController : NSObject
- (void)setDataSource:(id)ds;
- (id)dataSource;
@end

@interface IUMusicCoverFlowController : NSObject
- (int)numberOfItemsInCoverFlowView:(id)view;
- (id)query;
- (BOOL)_buildCoverFlow:(int)orientation;
- (id)initWithDelegate:(id)delegate;
- (unsigned int)_currentSongIndexInCoverFlowQuery:(BOOL)allowCreateSuffix;
- (id)_stringValueForProperty:(id)prop ofEntityAtIndex:(unsigned int)idx placeholder:(id)p;
@end

@interface IUMusicPropertiesView : UIView
- (void)setProperties:(id)props;
@end

@interface IUMediaDataSource : NSObject
- (unsigned int)count;
- (id)entityAtIndex:(unsigned int)idx;
@end

// Private MediaPlayer class
@interface MPConcreteMediaItem : MPMediaItem
@end

// Logos prologue. logos inserts these defines at the point of the first %hook, and our
// first %hook is inside "#if AF_DIAG". Left as is, the release build (AF_DIAG 0) would
// leave the other hooks without substrate.h and without the _LOGOS_SELF_TYPE_* macros.
// They are declared up front, outside any condition; logos' duplicate is identical and
// breaks nothing.
#include <substrate.h>

#ifndef _LOGOS_SELF_TYPE_NORMAL
#if defined(__clang__)
#if __has_feature(objc_arc)
#define _LOGOS_SELF_TYPE_NORMAL __unsafe_unretained
#define _LOGOS_SELF_TYPE_INIT __attribute__((ns_consumed))
#define _LOGOS_SELF_CONST const
#define _LOGOS_RETURN_RETAINED __attribute__((ns_returns_retained))
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif
#else
#define _LOGOS_SELF_TYPE_NORMAL
#define _LOGOS_SELF_TYPE_INIT
#define _LOGOS_SELF_CONST
#define _LOGOS_RETURN_RETAINED
#endif
#endif

#pragma mark - Logging
//
// File logging (/var/mobile/Documents/ArtistFix.log) exists only in the diagnostic
// build (AF_DIAG 1): the whole subsystem — code, buffers, I/O — is cut out by the
// preprocessor in release. Working functions log through AFLogDetail(), which in
// release expands to do {} while (0): no call, no arguments, no strings in the binary.

#if AF_DIAG
static NSString *gAFLogPath = nil;
static int gAFLogBudget = 30000;

static NSString *AFLogPath(void) {
    if (gAFLogPath) return gAFLogPath;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = [NSArray arrayWithObjects:
                      @"/var/mobile/Documents/ArtistFix.log",
                      @"/tmp/ArtistFix.log",
                      @"/var/tmp/ArtistFix.log", nil];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) continue;
        if ([fm fileExistsAtPath:p] ||
            [fm createFileAtPath:p contents:[NSData data] attributes:nil]) {
            gAFLogPath = p;
            return p;
        }
    }
    return nil;
}

static void AFLogWrite(NSString *fmt, ...) {
    if (gAFLogBudget <= 0) return;
    gAFLogBudget--;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ArtistFix] %@", msg);
    NSString *path = AFLogPath();
    if (!path) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [fh seekToEndOfFile];
    [fh writeData:d];
    [fh closeFile];
}
#endif // AF_DIAG — end of the logging subsystem

// Verbose logging: diagnostic build only (in release the calls disappear entirely, so
// they never slow down Music.app list rendering and never create file I/O).
#if AF_DIAG
#define AFLogDetail(...) AFLogWrite(__VA_ARGS__)
#define AFLogDetailArray(...) AFLogArrayImpl(__VA_ARGS__)
#else
#define AFLogDetail(...) do { } while (0)
#define AFLogDetailArray(...) do { } while (0)
#endif

#if AF_DIAG

#pragma mark - Class dump

static NSArray *AFInterestingNames(void) {
    return [NSArray arrayWithObjects:
            @"IUArtistsDataSource", @"IUAlbumsDataSource", @"IUMediaQueriesDataSource",
            @"IUMediaListDataSource", @"IUDataSource", @"IUMediaEntitySpecifier",
            @"MPMediaQuery", @"MPMediaItem", @"MPMediaItemCollection",
            @"MPConcreteMediaItem", @"MPConcreteMediaItemCollection", @"MPMediaEntity",
            @"MPMediaQuerySection", @"MPMediaQuerySectionInfo", @"MPMediaQueryCriteria",
            @"ML3Artist", @"ML3AlbumArtist", @"ML3Track", @"ML3MusicLibrary",
            @"ML3Query", @"ML3Entity", @"ML3Collection",
            @"IUCoverFlowViewController", @"IUMusicCoverFlowController",
            @"IUCoverFlowOwner", @"IUMediaDataSource", nil];
}

static BOOL AFNameMatches(NSString *name) {
    if ([name rangeOfString:@"Artist"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Cover"].location != NSNotFound) return YES;
    return [AFInterestingNames() containsObject:name];
}

static void AFDumpClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
    count = objc_getClassList(classes, count);
    AFLogWrite(@"=== CLASS DUMP START (total %d) ===", count);
    int matched = 0;
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        const char *cname = class_getName(c);
        if (!cname) continue;
        NSString *name = [NSString stringWithUTF8String:cname];
        if (!AFNameMatches(name)) continue;
        matched++;
        Class sc = class_getSuperclass(c);
        NSMutableString *chain = [NSMutableString string];
        while (sc) {
            [chain appendFormat:@" < %s", class_getName(sc)];
            sc = class_getSuperclass(sc);
        }
        AFLogWrite(@"\n@interface %@%@", name, chain);
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++)
            AFLogWrite(@"    - %s", sel_getName(method_getName(ms[j])));
        free(ms);
        mc = 0;
        ms = class_copyMethodList(object_getClass(c), &mc);
        for (unsigned int j = 0; j < mc; j++)
            AFLogWrite(@"    + %s", sel_getName(method_getName(ms[j])));
        free(ms);
        AFLogWrite(@"@end");
    }
    free(classes);
    AFLogWrite(@"=== CLASS DUMP END (matched %d) ===", matched);
}

static void AFLogArrayImpl(NSString *tag, NSArray *arr, NSUInteger max) {
    if (!arr) { AFLogWrite(@"%@ = nil", tag); return; }
    AFLogWrite(@"%@ count=%lu (%@)", tag, (unsigned long)[arr count],
               NSStringFromClass([arr class]));
    NSUInteger n = [arr count] < max ? [arr count] : max;
    for (NSUInteger i = 0; i < n; i++) {
        id o = [arr objectAtIndex:i];
        AFLogWrite(@"   [%lu] %@ => %@", (unsigned long)i,
                   NSStringFromClass([o class]), o);
        if ([o respondsToSelector:@selector(valueForProperty:)]) {
            @try {
                AFLogWrite(@"       artist=%@ | albumArtist=%@ | title=%@",
                           [o valueForProperty:@"artist"],
                           [o valueForProperty:@"albumArtist"],
                           [o valueForProperty:@"title"]);
            } @catch (NSException *e) { }
        }
    }
}


static void AFSelfTest(void) {
    AFLogWrite(@"=== SELFTEST START ===");
    MPMediaQuery *aq = [MPMediaQuery artistsQuery];
    AFLogWrite(@"artistsQuery class=%@ grouping=%lu",
               NSStringFromClass([aq class]), (unsigned long)aq.groupingType);
    NSArray *cols = [aq collections];
    AFLogWrite(@"artistsQuery collections=%lu collectionSections=%@",
               (unsigned long)[cols count], [aq collectionSections]);
    for (id c in cols) {
        id rep = nil;
        @try { rep = [c representativeItem]; } @catch (NSException *e) { rep = nil; }
        if (!rep) continue;
        id pidVal = nil;
        @try { pidVal = [rep valueForProperty:@"persistentID"]; } @catch (NSException *e) { }
        MPMediaQuery *iq = [[MPMediaQuery alloc] init];
        [iq setGroupingType:MPMediaGroupingTitle];
        [iq addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:pidVal forProperty:@"artistPID"]];
        NSArray *items = [iq items];
        AFLogWrite(@"  COLL(%@) title=%@ | artist=%@ | albumArtist=%@ | items=%lu | repPID=%@",
                   NSStringFromClass([c class]), [rep valueForProperty:@"title"],
                   [rep valueForProperty:@"artist"], [rep valueForProperty:@"albumArtist"],
                   (unsigned long)[items count], pidVal);
        for (id it in items)
            AFLogWrite(@"      ITEM(%@) title=%@ artist=%@ albumArtist=%@",
                       NSStringFromClass([it class]), [it valueForProperty:@"title"],
                       [it valueForProperty:@"artist"], [it valueForProperty:@"albumArtist"]);
    }
    NSArray *tags = [NSArray arrayWithObjects:@"Artist 1", @"Artist 2",
                     @"Artist 1; Artist 2", nil];
    for (NSString *t in tags) {
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingTitle];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:t forProperty:@"artist"]];
        AFLogDetailArray([NSString stringWithFormat:@"query artist='%@' items", t],
                         [q items], 10);
    }
    AFLogWrite(@"=== SELFTEST END ===");
}

static void AFQueryTest(void) {
    AFLogWrite(@"=== QUERYTEST START ===");
    MPMediaQuery *aq = [MPMediaQuery artistsQuery];
    NSArray *cols = [aq collections];
    AFLogWrite(@"QUERYTEST: artists=%lu", (unsigned long)[cols count]);
    for (id c in cols) {
        id rep = nil;
        @try { rep = [c representativeItem]; } @catch (NSException *e) { rep = nil; }
        if (!rep) continue;
        id pidVal = nil, name = nil;
        @try { pidVal = [rep valueForProperty:@"persistentID"]; } @catch (NSException *e) { }
        @try { name = [rep valueForProperty:@"artist"]; } @catch (NSException *e) { }
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingTitle];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:pidVal forProperty:@"artistPID"]];
        AFLogWrite(@"QUERYTEST: artist pid=%@ name='%@' songs=%lu", pidVal,
                   name ? name : @"", (unsigned long)[[q items] count]);
    }
    MPMediaQuery *aaq = [[MPMediaQuery alloc] init];
    [aaq setGroupingType:MPMediaGroupingAlbumArtist];
    [aaq addFilterPredicate:[MPMediaPropertyPredicate
                           predicateWithValue:[NSNumber numberWithInt:1]
                                  forProperty:@"mediaType"]];
    for (id c in [aaq collections]) {
        id pidVal = nil;
        @try { pidVal = [c valueForProperty:@"albumArtistPersistentID"]; } @catch (NSException *e) { }
        if (!pidVal) continue;
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingAlbum];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:pidVal forProperty:@"albumArtistPID"]];
        NSArray *albums = [q collections];
        NSArray *items = [q items];
        AFLogWrite(@"QUERYTEST: albumArtistPID=%@ -> albums=%lu items=%lu (predicates: %@)",
                   pidVal, (unsigned long)[albums count], (unsigned long)[items count],
                   [q filterPredicates]);
        for (id a in albums) {
            id rep = nil;
            @try { rep = [a representativeItem]; } @catch (NSException *e) { rep = nil; }
            if (!rep) continue;
            AFLogWrite(@"QUERYTEST:    album='%@' songs=%lu",
                       [rep valueForProperty:@"title"], (unsigned long)[[a items] count]);
        }
    }
    AFLogWrite(@"=== QUERYTEST END ===");
}

// Probe for working with albums: an album collection has almost no properties of its own
// (title/artist are null), and the cell subtitle and header are taken from the tracks.
// Here we figure out what the collection and its representative track actually return, and
// which key works for a title-based predicate (on iOS 6 MPMediaPropertyPredicate has no
// "real" albumTitle — if the key is unsupported the query returns 0 or throws).
static void AFAlbumProbe(void) {
    AFLogWrite(@"=== ALBUMPROBE START ===");
    NSArray *keys = [NSArray arrayWithObjects:@"persistentID", @"albumPID", @"title",
                     @"albumTitle", @"album", @"albumArtist", @"artist", nil];
    MPMediaQuery *aq = [[MPMediaQuery alloc] init];
    [aq setGroupingType:MPMediaGroupingAlbum];
    [aq addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:[NSNumber numberWithInt:1]
                                                           forProperty:@"mediaType"]];
    NSArray *cols = [aq collections];
    AFLogWrite(@"ALBUMPROBE: %lu albums in the library", (unsigned long)[cols count]);
    for (id c in cols) {
        NSMutableString *ps = [NSMutableString string];
        for (NSString *k in keys) {
            id v = nil;
            @try { v = [c valueForProperty:k]; } @catch (NSException *e) { v = @"<ex>"; }
            [ps appendFormat:@" %@=%@", k, v];
        }
        AFLogWrite(@"ALBUMPROBE: coll=%@%@", NSStringFromClass([c class]), ps);
        id rep = nil;
        @try { rep = [c representativeItem]; } @catch (NSException *e) { }
        if (rep) {
            NSMutableString *rs = [NSMutableString string];
            for (NSString *k in keys) {
                id v = nil;
                @try { v = [rep valueForProperty:k]; } @catch (NSException *e) { v = @"<ex>"; }
                [rs appendFormat:@" %@=%@", k, v];
            }
            AFLogWrite(@"ALBUMPROBE:   rep=%@%@", NSStringFromClass([rep class]), rs);
        }
    }
    for (NSString *k in [NSArray arrayWithObjects:@"album", @"albumTitle", @"albumName", nil]) {
        for (int cmp = 0; cmp <= 1; cmp++) {
            NSUInteger n = 0;
            NSString *err = @"";
            @try {
                MPMediaQuery *q = [[MPMediaQuery alloc] init];
                [q setGroupingType:MPMediaGroupingTitle];
                [q addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:@"Album"
                                                                       forProperty:k
                                                                    comparisonType:
                 (MPMediaPredicateComparison)cmp]];
                n = [[q items] count];
            } @catch (NSException *e) { err = [e description]; n = 0; }
            AFLogWrite(@"ALBUMPROBE: predicate %@ cmp=%d -> items=%lu %@", k, cmp,
                       (unsigned long)n, err);
        }
    }
    AFLogWrite(@"=== ALBUMPROBE END ===");
}

#endif // AF_DIAG — end of the class dump and self-tests


#pragma mark - Work part: compound artist tag parsing

// "Artist 1; Artist 2" -> ["Artist 1", "Artist 2"]
static NSArray *AFArtistComponents(NSString *raw) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *parts = [raw componentsSeparatedByString:@";"];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t length]) [out addObject:t];
    }
    return out;
}

// "Artist 1; Artist 2" -> "Artist 1" (the lead artist)
static NSString *AFPrimaryArtist(NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || ![raw length]) return raw;
    if ([raw rangeOfString:@";"].location == NSNotFound) return raw;
    NSArray *c = AFArtistComponents(raw);
    if ([c count] < 2) return raw;
    return [c objectAtIndex:0];
}

// Normalize the string the UI is about to display:
// "Artist 1; Artist 2" -> "Artist 1".
// Applied only to collection-entity strings (artists/albums), so that song titles
// containing ';' are never mangled.
static id AFNormalizeDisplayString(id s, id entity) {
    if (![s isKindOfClass:[NSString class]]) return s;
    if ([s rangeOfString:@";"].location == NSNotFound) return s;
    if (entity && ![entity isKindOfClass:[MPMediaItemCollection class]]) return s;
    NSArray *c = AFArtistComponents(s);
    if ([c count] < 2) return s;
    NSString *fixed = [c objectAtIndex:0];
    AFLogDetail(@"[fix] display: '%@' -> '%@'", s, fixed);
    return fixed;
}

// The raw (non-normalized) tag is read through this flag: our -valueForProperty: hooks
// would otherwise return the already-parsed tag ("A; B" -> "A"), while parsing the group
// composition needs the original tag.
static BOOL gAFBypassArtistFix = NO;

static BOOL AFIsArtistPropertyKey(id key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    return [key isEqualToString:@"artist"] ||
           [key isEqualToString:@"albumArtist"] ||
           [key isEqualToString:@"albumArtistName"] ||
           [key isEqualToString:@"artistName"] ||
           [key isEqualToString:@"albumAlbumArtist"] ||
           [key isEqualToString:@"effectiveAlbumArtist"];
}

static id AFMaybeFixArtistValue(id key, id value) {
    // Check order — cheapest first: the key (cheap isEqualToString calls, and usually not
    // an artist key) → the value class → scanning the string for ';'.
    // -valueForProperty: is called thousands of times per screen build, so a cheap early
    // exit is critical.
    if (gAFBypassArtistFix) return value;
    if (!AFIsArtistPropertyKey(key)) return value;
    if (![value isKindOfClass:[NSString class]]) return value;
    if ([value rangeOfString:@";"].location == NSNotFound) return value;
    NSString *fixed = AFPrimaryArtist(value);
    if (fixed != value) AFLogDetail(@"[fix] %@: '%@' -> '%@'", key, value, fixed);
    return fixed;
}


#pragma mark - Work part: artist-list row names
//
// The iOS 6 "Artists" list is grouped by album artist, i.e. by RAW tags: one group = one
// tag. If the library has both "Artist 1; Artist 2" and plain "Artist 1", there are two
// groups: the first is shown as "Artist 1" and the second — also as "Artist 1" (the lead
// artist of the tag), so the artist "Artist 2" is invisible in the list while "Artist 1"
// is shown twice.
//
// Therefore every group gets its own name: the first component of the tag that does not
// have a group of its own. For "Artist 1; Artist 2" with a separate "Artist 1" group it
// is "Artist 2". If all tag components already have their own rows, the whole tag is
// shown — that way the list never gets two rows with the same name.
//
// The same name is used by drill-down: the "albumArtistPID == X" predicate is turned into
// "albumArtist CONTAINS <row name>", otherwise tapping the "Artist 2" row would open the
// list of the "Artist 1; Artist 2" group, which is already titled differently in the UI.

static char kAFArtistNameKey;
static char kAFArtistPIDKey;
static char kAFArtistSongCountKey;

static NSArray *gAFAllArtists = nil;                    // All unique artist names in the library (sorted)
static NSMutableDictionary *gAFArtistSongCounts = nil;  // artistName -> NSNumber(count)
static NSMutableDictionary *gAFArtistItems = nil;       // artistName -> NSMutableArray(items)
static NSMutableDictionary *gAFArtistRealCols = nil;    // artistName -> MPConcreteMediaItemCollection
static NSMutableDictionary *gAFArtistPIDs = nil;        // artistName -> NSNumber(pid)
static NSMutableDictionary *gAFPIDToArtist = nil;       // NSNumber(pid) -> artistName
static BOOL gAFArtistsBuilding = NO;

// The raw tag value: our -valueForProperty: hooks normalize "A; B" -> "A", while parsing
// the group composition needs the original tag.
static id AFRawArtistValue(id obj, NSString *key) {
    if (!obj) return nil;
    gAFBypassArtistFix = YES;
    id v = nil;
    @try { v = [obj valueForProperty:key]; }
    @catch (NSException *e) { v = nil; }
    gAFBypassArtistFix = NO;
    return v;
}

// Group albumArtistPID: for a collection grouped by album artist the persistentID IS the
// albumArtistPID, but we try the explicit property first.
static unsigned long long AFArtistGroupPID(id collection) {
    unsigned long long pid = 0;
    @try { pid = [[collection valueForProperty:@"albumArtistPersistentID"] unsignedLongLongValue]; }
    @catch (NSException *e) { pid = 0; }
    if (!pid) {
        @try { pid = [[collection valueForProperty:@"artistPersistentID"] unsignedLongLongValue]; }
        @catch (NSException *e) { pid = 0; }
    }
    if (!pid) {
        @try { pid = [[collection valueForProperty:@"persistentID"] unsignedLongLongValue]; }
        @catch (NSException *e) { pid = 0; }
    }
    return pid;
}

static void AFBuildAllArtists(void) {
    if (gAFAllArtists || gAFArtistsBuilding) return;
    gAFArtistsBuilding = YES;

    NSMutableSet *uniqueNames = [NSMutableSet set];
    NSMutableDictionary *songCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *artistItems = [NSMutableDictionary dictionary];
    NSMutableDictionary *pids = [NSMutableDictionary dictionary];
    NSMutableDictionary *pidToName = [NSMutableDictionary dictionary];
    NSMutableDictionary *realCols = [NSMutableDictionary dictionary];

    @try {
        MPMediaQuery *sq = [MPMediaQuery songsQuery];
        NSArray *songs = [sq items];
        for (id item in songs) {
            NSString *rawAr = AFRawArtistValue(item, @"artist");
            NSString *rawAA = AFRawArtistValue(item, @"albumArtist");
            NSMutableSet *trackArtists = [NSMutableSet set];
            if ([rawAr isKindOfClass:[NSString class]] && [rawAr length]) {
                for (NSString *p in AFArtistComponents(rawAr)) {
                    if ([p length]) [trackArtists addObject:p];
                }
            }
            if ([rawAA isKindOfClass:[NSString class]] && [rawAA length]) {
                for (NSString *p in AFArtistComponents(rawAA)) {
                    if ([p length]) [trackArtists addObject:p];
                }
            }
            for (NSString *a in trackArtists) {
                [uniqueNames addObject:a];
                NSMutableArray *itArr = [artistItems objectForKey:a];
                if (!itArr) {
                    itArr = [NSMutableArray array];
                    [artistItems setObject:itArr forKey:a];
                }
                [itArr addObject:item];
                NSNumber *cnt = [songCounts objectForKey:a];
                NSUInteger c = cnt ? [cnt unsignedIntegerValue] + 1 : 1;
                [songCounts setObject:[NSNumber numberWithUnsignedInteger:c] forKey:a];
            }
        }
    } @catch (NSException *e) { }

    @try {
        MPMediaQuery *aq = [MPMediaQuery artistsQuery];
        for (id c in [aq collections]) {
            id rep = nil;
            @try { rep = [c representativeItem]; } @catch (NSException *e) { rep = nil; }
            if (!rep) continue;
            NSString *rawAr = AFRawArtistValue(rep, @"artist");
            unsigned long long pid = AFArtistGroupPID(c);
            if (pid && [rawAr isKindOfClass:[NSString class]] && [rawAr length]) {
                if ([uniqueNames containsObject:rawAr]) {
                    if (![pids objectForKey:rawAr]) {
                        NSNumber *k = [NSNumber numberWithUnsignedLongLong:pid];
                        [pids setObject:k forKey:rawAr];
                        [pidToName setObject:rawAr forKey:k];
                    }
                    if (![realCols objectForKey:rawAr]) {
                        [realCols setObject:c forKey:rawAr];
                    }
                }
            }
        }
    } @catch (NSException *e) { }

    NSArray *sorted = [[uniqueNames allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *a in sorted) {
        if (![pids objectForKey:a]) {
            unsigned long long hashPid = (unsigned long long)[a hash] | 0x8000000000000000ULL;
            NSNumber *k = [NSNumber numberWithUnsignedLongLong:hashPid];
            [pids setObject:k forKey:a];
            [pidToName setObject:a forKey:k];
        }
    }

    gAFAllArtists = sorted;
    gAFArtistSongCounts = songCounts;
    gAFArtistItems = artistItems;
    gAFArtistRealCols = realCols;
    gAFArtistPIDs = pids;
    gAFPIDToArtist = pidToName;
    gAFArtistsBuilding = NO;
    AFLogDetail(@"[artists] built %lu unique artists", (unsigned long)[sorted count]);
#if AF_DIAG
    for (NSString *a in sorted) {
        AFLogDetail(@"[artists]   '%@' -> pid=%@ songs=%@", a, [pids objectForKey:a], [songCounts objectForKey:a]);
    }
#endif
}

// NSClassFromString cache: a cell row is rendered on every list screen, and a class lookup
// by name is a hash + strcmp on every call.
static Class AFCachedClass(NSString *name) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    Class c = [cache objectForKey:name];
    if (!c) {
        c = NSClassFromString(name);
        if (c) [cache setObject:c forKey:name];
    }
    return c;
}

static NSString *AFArtistListNameForPID(unsigned long long pid, NSString **outProp) {
    if (!pid) return nil;
    AFBuildAllArtists();
    NSNumber *k = [NSNumber numberWithUnsignedLongLong:pid];
    NSString *name = [gAFPIDToArtist objectForKey:k];
    if (![name length]) return nil;
    if (outProp) *outProp = @"artist";
    return name;
}

static id AFArtistRowLabel(id s, id config, id entity) {
    if (![entity isKindOfClass:[MPMediaItemCollection class]]) return s;
    Class cls = AFCachedClass(@"IUPlaylistCellConfiguration");
    if (!cls || ![config isKindOfClass:cls]) return s;
    NSString *custom = objc_getAssociatedObject(entity, &kAFArtistNameKey);
    if ([custom length]) return custom;
    NSString *name = AFArtistListNameForPID(AFArtistGroupPID(entity), NULL);
    if ([name length] && ![name isEqualToString:s]) {
        return name;
    }
    return s;
}

#pragma mark - Work part: album = all songs of one title
//
// iOS 6 stores an album as a "title + album artist tag" pair: if the tracks of one album
// have different album artist tags ("Artist 1; Artist 2" on one track, "Artist 2" on
// another), the database ends up with SEVERAL album rows sharing the same title. Two
// problems follow:
//   * the album is repeated in lists as many times as there are album rows (the artist
//     page too);
//   * the row subtitle comes from a single representative track's tag, so the "second"
//     album has either an empty subtitle or one naming a different artist.
//
// Therefore albums are merged into one: album rows with the same title and INTERSECTING
// artist sets (intersection, not just the title — otherwise same-titled albums by
// different artists would merge). For a merged album:
//   * lists keep a single row — the first in library order (gAFAlbumMerge);
//   * the row subtitle is all album artists joined in one line (gAFAlbumLine);
//   * the album page searches songs by title (albumTitle), not albumPID: otherwise only
//     the songs of one of the album rows would land in it (see AFRewriteArtistPIDPredicate).
//
// Album artists are counted like in AFBuildGroupNames: the track's album artist tag, or
// the track's artist tag when empty. Order as in the tags, duplicates removed.

static NSMutableDictionary *gAFAlbumMerge = nil;       // NSNumber(pid) -> NSNumber(owner row pid)
static NSMutableDictionary *gAFAlbumLine = nil;        // NSNumber(pid) -> artist subtitle line
static NSMutableDictionary *gAFAlbumTitle = nil;       // NSNumber(pid) -> album title
static NSMutableDictionary *gAFAlbumTitleToLine = nil; // NSString(albumTitle) -> artist subtitle
static NSMutableSet *gAFAlbumMulti = nil;              // pids of album rows merged with others
static BOOL gAFAlbumMapBuilding = NO;                  // recursion guard during map building

// An album row in the database = one album: for a collection grouped by album the
// persistentID IS the albumPID (the collection has no explicit property for it — see
// ALBUMPROBE in diagnostics).
static unsigned long long AFAlbumPID(id collection) {
    unsigned long long pid = 0;
    @try { pid = [[collection valueForProperty:@"persistentID"] unsignedLongLongValue]; }
    @catch (NSException *e) { pid = 0; }
    return pid;
}

// Merging album rows: same title and at least one shared artist. The union is transitive
// (runs to a fixpoint), so the "Artist 1; Artist 2" row brings together both the
// "Artist 1" row and the "Artist 2" row. The owner row is the first in library order.
//
// Implementation — union-find with path halving: the old code was a while(changed) loop
// over all n² pairs with an O(n) group reassignment per union and an O(k) artist lookup
// in an array — cubic complexity on large libraries. Artist intersection is checked on
// the original row sets (NSSet), pairs are only enumerated inside same-title groups, and
// the artist order of the subtitle is preserved (NSMutableOrderedSet).
static NSUInteger AFFindRoot(NSUInteger *parent, NSUInteger x) {
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

static void AFBuildAlbumGroups(NSArray *pids, NSArray *names, NSArray *arts,
                               NSMutableDictionary *merge, NSMutableDictionary *line,
                               NSMutableDictionary *titles, NSMutableSet *multi,
                               NSMutableDictionary *titleToLine) {
    NSUInteger n = [pids count];
    if (!n) return;

    // Per-row artist sets — built once, intersection in O(smaller size).
    NSMutableArray *artSets = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
        [artSets addObject:[NSSet setWithArray:[arts objectAtIndex:i]]];

    // Only same-title rows can merge: group indices by title.
    NSMutableDictionary *rowsByTitle = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < n; i++) {
        NSString *t = [names objectAtIndex:i];
        if (![t length]) continue;
        NSMutableArray *rows = [rowsByTitle objectForKey:t];
        if (!rows) {
            rows = [NSMutableArray array];
            [rowsByTitle setObject:rows forKey:t];
        }
        [rows addObject:[NSNumber numberWithUnsignedInteger:i]];
    }

    // Union-find: parent[i] is the group root; the root is always the minimal index (the
    // smaller root absorbs the larger), i.e. the "owner row" is the first in order.
    NSUInteger *parent = (NSUInteger *)malloc(sizeof(NSUInteger) * n);
    if (!parent) return;
    for (NSUInteger i = 0; i < n; i++) parent[i] = i;
    for (NSString *t in rowsByTitle) {
        NSArray *rows = [rowsByTitle objectForKey:t];
        NSUInteger m = [rows count];
        for (NSUInteger a = 0; a < m; a++) {
            NSUInteger ia = [[rows objectAtIndex:a] unsignedIntegerValue];
            for (NSUInteger b = a + 1; b < m; b++) {
                NSUInteger ib = [[rows objectAtIndex:b] unsignedIntegerValue];
                NSUInteger ra = AFFindRoot(parent, ia);
                NSUInteger rb = AFFindRoot(parent, ib);
                if (ra == rb) continue;
                // Intersection — on the original row sets (as before); transitivity is
                // provided by union-find: A∩B and B∩C put A,B,C into one group.
                if (![[artSets objectAtIndex:ia] intersectsSet:[artSets objectAtIndex:ib]]) continue;
                if (ra < rb) parent[rb] = ra; else parent[ra] = rb;
            }
        }
    }

    // Group assembly in row iteration order (library order preserved).
    NSMutableArray *rootOrder = [NSMutableArray array];
    NSMutableDictionary *membersByRoot = [NSMutableDictionary dictionary]; // root -> [pid]
    NSMutableDictionary *artistsByRoot = [NSMutableDictionary dictionary]; // root -> NSMutableOrderedSet
    NSMutableDictionary *titlesByRoot = [NSMutableDictionary dictionary];  // root -> title
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger r = AFFindRoot(parent, i);
        NSNumber *rk = [NSNumber numberWithUnsignedInteger:r];
        NSMutableArray *mem = [membersByRoot objectForKey:rk];
        if (!mem) {
            mem = [NSMutableArray array];
            [membersByRoot setObject:mem forKey:rk];
            [artistsByRoot setObject:[NSMutableOrderedSet orderedSet] forKey:rk];
            [titlesByRoot setObject:[names objectAtIndex:i] forKey:rk];
            [rootOrder addObject:rk];
        }
        [mem addObject:[pids objectAtIndex:i]];
        [[artistsByRoot objectForKey:rk] addObjectsFromArray:[arts objectAtIndex:i]];
    }
    free(parent);

    for (NSNumber *rk in rootOrder) {
        NSArray *members = [membersByRoot objectForKey:rk];
        NSMutableOrderedSet *all = [artistsByRoot objectForKey:rk];
        NSString *lineStr = [[all array] componentsJoinedByString:@"; "];
        NSString *title = [titlesByRoot objectForKey:rk];
        NSNumber *keep = [members objectAtIndex:0];
        for (NSUInteger m = 0; m < [members count]; m++) {
            NSNumber *pk = [members objectAtIndex:m];
            [titles setObject:title forKey:pk];
            if ([lineStr length]) [line setObject:lineStr forKey:pk];
            if (m > 0) [merge setObject:keep forKey:pk];
        }
        if ([title length] && [lineStr length]) {
            [titleToLine setObject:lineStr forKey:title];
        }
        if ([members count] > 1) {
            [multi addObjectsFromArray:members];
            AFLogDetail(@"[albums] '%@': %lu album rows -> 1, subtitle '%@'",
                        title, (unsigned long)[members count], lineStr);
        }
    }
}

static void AFBuildAlbumMap(void) {
    if (gAFAlbumMerge || gAFAlbumMapBuilding) {
        AFLogDetail(@"[albumprobe] AFBuildAlbumMap skip: merge=%@ building=%d",
                    (gAFAlbumMerge ? @"set" : @"nil"), (int)gAFAlbumMapBuilding);
        return;
    }
    gAFAlbumMapBuilding = YES;
    AFLogDetail(@"[albumprobe] AFBuildAlbumMap START");
    NSMutableDictionary *merge = [NSMutableDictionary dictionary];
    NSMutableDictionary *line = [NSMutableDictionary dictionary];
    NSMutableDictionary *titles = [NSMutableDictionary dictionary];
    NSMutableDictionary *titleToLine = [NSMutableDictionary dictionary];
    NSMutableSet *multi = [NSMutableSet set];
    @try {
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingAlbum];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:[NSNumber numberWithInt:1]
                                     forProperty:@"mediaType"]];
        NSMutableArray *pids = [NSMutableArray array];
        NSMutableArray *names = [NSMutableArray array];   // album row title
        NSMutableArray *arts = [NSMutableArray array];    // album row artists
        for (id c in [q collections]) {
            unsigned long long pid = AFAlbumPID(c);
            if (!pid) continue;
            NSString *title = nil;
            NSMutableArray *artists = [NSMutableArray array];
            for (id it in [c items]) {
                if (!title) {
                    id t = nil;
                    @try { t = [it valueForProperty:@"albumTitle"]; } @catch (NSException *e) { }
                    if ([t isKindOfClass:[NSString class]] && [t length]) title = t;
                }
                NSString *raw = AFRawArtistValue(it, @"albumArtist");
                if (![raw isKindOfClass:[NSString class]] || ![raw length])
                    raw = AFRawArtistValue(it, @"artist");
                for (NSString *a in AFArtistComponents(raw))
                    if (![artists containsObject:a]) [artists addObject:a];
            }
            [pids addObject:[NSNumber numberWithUnsignedLongLong:pid]];
            [names addObject:title ? title : @""];
            [arts addObject:artists];
        }
        AFLogDetail(@"[albumprobe] collected %lu album rows", (unsigned long)[pids count]);
        for (NSUInteger i = 0; i < [pids count]; i++)
            AFLogDetail(@"[albumprobe]   pid=%@ name='%@' arts=%@",
                        [pids objectAtIndex:i], [names objectAtIndex:i],
                        [arts objectAtIndex:i]);
        AFBuildAlbumGroups(pids, names, arts, merge, line, titles, multi, titleToLine);
    } @catch (NSException *e) { }
    gAFAlbumMapBuilding = NO;
    gAFAlbumMerge = merge;
    gAFAlbumLine = line;
    gAFAlbumTitle = titles;
    gAFAlbumTitleToLine = titleToLine;
    gAFAlbumMulti = multi;
    AFLogDetail(@"[albumprobe] AFBuildAlbumMap END: merge=%lu multi=%lu line=%lu",
                (unsigned long)[merge count], (unsigned long)[multi count],
                (unsigned long)[line count]);
}

// Album row subtitle: all album artists in one line (nil — do not change).
static NSString *AFAlbumArtistsLineForTitle(NSString *title) {
    if (![title length]) return nil;
    AFBuildAlbumMap();
    NSString *line = [gAFAlbumTitleToLine objectForKey:title];
    return [line length] ? line : nil;
}

static NSString *AFAlbumArtistsLine(id entity) {
    if (![entity isKindOfClass:[MPMediaItemCollection class]]) return nil;
    unsigned long long pid = AFAlbumPID(entity);
    AFBuildAlbumMap();
    if (pid) {
        NSString *line = [gAFAlbumLine objectForKey:[NSNumber numberWithUnsignedLongLong:pid]];
        if ([line length]) return line;
    }
    id title = nil;
    @try { title = [entity valueForProperty:@"title"]; } @catch (NSException *e) { }
    if (![title length]) {
        @try { title = [entity valueForProperty:@"albumTitle"]; } @catch (NSException *e) { }
    }
    if ([title isKindOfClass:[NSString class]] && [title length]) {
        return AFAlbumArtistsLineForTitle(title);
    }
    return nil;
}

// Title of a merged album (nil — not merged, the page is searched by albumPID as before).
static NSString *AFAlbumMergedTitle(unsigned long long pid) {
    if (!pid) return nil;
    AFBuildAlbumMap();
    NSNumber *k = [NSNumber numberWithUnsignedLongLong:pid];
    if (![gAFAlbumMulti containsObject:k]) return nil;
    NSString *title = [gAFAlbumTitle objectForKey:k];
    return [title length] ? title : nil;
}

// All songs of a merged album (for CoverFlow and the album page).
// The result is cached by title: count/items of the collection are hit on every layout
// pass and scroll, and each call used to create a new MPMediaQuery — a fresh trip to the
// media library every time.
static NSArray *AFMergedAlbumItems(NSString *albumTitle) {
    if (![albumTitle length]) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSArray *cached = [cache objectForKey:albumTitle];
    if (cached) return cached;

    static BOOL inMergedQuery = NO;
    if (inMergedQuery) return nil;
    inMergedQuery = YES;
    NSArray *items = nil;
    @try {
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingTitle];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:albumTitle
                                     forProperty:@"albumTitle"]];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:[NSNumber numberWithInt:1]
                                     forProperty:@"mediaType"]];
        items = [q items];
    } @catch (NSException *e) { items = nil; }
    inMergedQuery = NO;
    if ([items count]) [cache setObject:items forKey:albumTitle];
    return items;
}

// Album cell: the "Albums" list and the albums on an artist page.
static BOOL AFIsAlbumCell(id config) {
    Class cls = AFCachedClass(@"IUAlbumCellConfiguration");
    return (cls && [config isKindOfClass:cls]) ? YES : NO;
}

#pragma mark - Work part: list rows = tag components, no duplicates
//
// The iOS 6 "Artists" list is built from album artist groups, i.e. from RAW tags: one
// group = one tag. The tag "Carol X; Дырявый Вова; Playboi Carti" is a single row, and no
// matter how many names it holds there are not enough rows for all of them: any renaming
// produces either duplicates or a long tag in a row. Therefore the extra groups are
// removed from the list: every artist gets exactly one row, and the songs of the removed
// groups are visible on the pages of all their artists — drill-down searches
// "<property> CONTAINS <name>".

static BOOL gAFInArtistFilter = NO;     // recursion guard during list filtering

// The indexes of the kept rows are stored on the query itself (associated object), not in
// one shared variable: the artists and albums lists live at the same time, and a shared
// "last" index array would swap sections between the two lists.
static char kAFKeptIndexesKey;

static NSArray *AFKeptIndexesOf(MPMediaQuery *q) {
    if (!q) return nil;
    return objc_getAssociatedObject(q, &kAFKeptIndexesKey);
}

// An "all artists" query: artist or album artist grouping with no artist-specific predicates.
static BOOL AFIsAllArtistsQuery(MPMediaQuery *q) {
    if (!q) return NO;
    NSUInteger gt = [q groupingType];
    if (gt != MPMediaGroupingArtist && gt != MPMediaGroupingAlbumArtist) return NO;
    NSSet *preds = nil;
    @try { preds = [q filterPredicates]; }
    @catch (NSException *e) { return NO; }
    if (!preds) return NO;
    for (id p in preds) {
        if (![p isKindOfClass:[MPMediaPropertyPredicate class]]) return NO;
        NSString *prop = [p property];
        if ([prop isEqualToString:@"artist"] || [prop isEqualToString:@"albumArtist"] ||
            [prop isEqualToString:@"artistPID"] || [prop isEqualToString:@"albumArtistPID"])
            return NO;
    }
    return YES;
}

static NSArray *AFFilterArtistCollections(MPMediaQuery *q, NSArray *arr) {
    if (gAFInArtistFilter) return arr;
    AFBuildAllArtists();
    if (![gAFAllArtists count]) return arr;

    gAFInArtistFilter = YES;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:[gAFAllArtists count]];
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[gAFAllArtists count]];
    NSMutableSet *usedPointers = [NSMutableSet set];

    id templateCol = [arr count] ? [arr objectAtIndex:0] : nil;
    if (!templateCol) {
        @try {
            NSArray *allCols = [[MPMediaQuery artistsQuery] collections];
            if ([allCols count]) templateCol = [allCols objectAtIndex:0];
        } @catch (NSException *e) { }
    }

    // pid -> collection from arr (the first in order). Previously the whole arr was
    // re-scanned per artist with valueForProperty:persistentID at every step —
    // O(artists × rows) on every list open.
    NSMutableDictionary *colsByPid = [NSMutableDictionary dictionaryWithCapacity:[arr count]];
    for (id c in arr) {
        unsigned long long cpid = 0;
        @try { cpid = [[c valueForProperty:@"persistentID"] unsignedLongLongValue]; } @catch (NSException *e) { }
        if (!cpid) continue;
        NSNumber *k = [NSNumber numberWithUnsignedLongLong:cpid];
        if (![colsByPid objectForKey:k]) [colsByPid setObject:c forKey:k];
    }

    for (NSUInteger idx = 0; idx < [gAFAllArtists count]; idx++) {
        NSString *artistName = [gAFAllArtists objectAtIndex:idx];
        NSNumber *artistPid = [gAFArtistPIDs objectForKey:artistName];
        id matchingCol = [gAFArtistRealCols objectForKey:artistName];

        NSValue *ptrVal = matchingCol ? [NSValue valueWithPointer:(__bridge const void *)matchingCol] : nil;
        if (!matchingCol || [usedPointers containsObject:ptrVal]) {
            matchingCol = artistPid ? [colsByPid objectForKey:artistPid] : nil;
            if (matchingCol) {
                NSValue *cpVal = [NSValue valueWithPointer:(__bridge const void *)matchingCol];
                if ([usedPointers containsObject:cpVal]) matchingCol = nil;
            }
        }

        ptrVal = matchingCol ? [NSValue valueWithPointer:(__bridge const void *)matchingCol] : nil;
        if (!matchingCol || [usedPointers containsObject:ptrVal]) {
            NSArray *items = [gAFArtistItems objectForKey:artistName];
            if ([items count]) {
                @try {
                    matchingCol = [MPMediaItemCollection collectionWithItems:items];
                } @catch (NSException *e) { matchingCol = nil; }
            }
            if (!matchingCol && templateCol && [[templateCol items] count]) {
                @try {
                    matchingCol = [MPMediaItemCollection collectionWithItems:[templateCol items]];
                } @catch (NSException *e) { matchingCol = nil; }
            }
        }

        if (matchingCol) {
            ptrVal = [NSValue valueWithPointer:(__bridge const void *)matchingCol];
            [usedPointers addObject:ptrVal];

            objc_setAssociatedObject(matchingCol, &kAFArtistNameKey, artistName, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (artistPid) {
                objc_setAssociatedObject(matchingCol, &kAFArtistPIDKey, artistPid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            NSNumber *songCnt = [gAFArtistSongCounts objectForKey:artistName];
            if (songCnt) {
                objc_setAssociatedObject(matchingCol, &kAFArtistSongCountKey, songCnt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [result addObject:matchingCol];
            [kept addObject:[NSNumber numberWithUnsignedInteger:idx]];
        }
    }
    gAFInArtistFilter = NO;
    objc_setAssociatedObject(q, &kAFKeptIndexesKey, kept, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    AFLogDetail(@"[artists] rows in the artist list: %lu", (unsigned long)[result count]);
    return result;
}

static NSArray *AFFilterCollections(MPMediaQuery *q, NSArray *arr) {
    if (gAFInArtistFilter || ![arr count]) return arr;
    BOOL artists = AFIsAllArtistsQuery(q);
    // 12 = the private MPMediaGroupingAlbumByArtist, used by CoverFlow (landscape orientation).
    BOOL albums = ([q groupingType] == MPMediaGroupingAlbum || [q groupingType] == 12);
    if (!artists && !albums) return arr;
    if (artists) return AFFilterArtistCollections(q, arr);
    if (albums) AFBuildAlbumMap();
    if (![gAFAlbumMerge count]) return arr;
    gAFInArtistFilter = YES;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *kept = [NSMutableArray array];
    NSUInteger hidden = 0;
    for (NSUInteger i = 0; i < [arr count]; i++) {
        id c = [arr objectAtIndex:i];
        unsigned long long pid = AFAlbumPID(c);
        NSNumber *k = pid ? [NSNumber numberWithUnsignedLongLong:pid] : nil;
        if (albums && k && [gAFAlbumMerge objectForKey:k]) { hidden++; continue; }
        [out addObject:c];
        [kept addObject:[NSNumber numberWithUnsignedInteger:i]];
    }
    gAFInArtistFilter = NO;
    if (!hidden) return arr;
    objc_setAssociatedObject(q, &kAFKeptIndexesKey, kept, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    AFLogDetail(@"[rows] albums: %lu rows -> %lu (hidden %lu)",
                (unsigned long)[arr count], (unsigned long)[out count], (unsigned long)hidden);
    return out;
}

// The A–Z sections of a query are computed over the original row array: after filtering
// the ranges must be recomputed, otherwise section headers and the alphabet index drift
// apart from the list contents.
static NSArray *AFSectionsForArtists(NSArray *artistNames) {
    if (![artistNames count]) return nil;
    Class cls = AFCachedClass(@"MPMediaQuerySection");
    if (!cls) return nil;
    NSMutableArray *out = [NSMutableArray array];
    NSString *currLetter = nil;
    NSUInteger startIdx = 0;
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < [artistNames count]; i++) {
        NSString *name = [artistNames objectAtIndex:i];
        NSString *letter = [name length] ? [[name substringToIndex:1] uppercaseString] : @"#";
        if (!currLetter) {
            currLetter = letter;
            startIdx = i;
            count = 1;
        } else if ([letter isEqualToString:currLetter]) {
            count++;
        } else {
            id s = [[cls alloc] init];
            @try {
                [s setValue:currLetter forKey:@"title"];
                [s setValue:[NSValue valueWithRange:NSMakeRange(startIdx, count)] forKey:@"range"];
            } @catch (NSException *e) { }
            [out addObject:s];
            currLetter = letter;
            startIdx = i;
            count = 1;
        }
    }
    if (currLetter && count > 0) {
        id s = [[cls alloc] init];
        @try {
            [s setValue:currLetter forKey:@"title"];
            [s setValue:[NSValue valueWithRange:NSMakeRange(startIdx, count)] forKey:@"range"];
        } @catch (NSException *e) { }
        [out addObject:s];
    }
    return out;
}

static NSArray *AFRemapSections(MPMediaQuery *q, NSArray *sections) {
    NSArray *keptIdx = AFKeptIndexesOf(q);
    if (![keptIdx count] || ![sections count]) return sections;
    Class cls = AFCachedClass(@"MPMediaQuerySection");
    if (!cls) return sections;
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger cum = 0, k = 0;
    for (id s in sections) {
        // Private section properties are read/written via KVC: the SDK only declares
        // title/range.
        NSRange r = [[s valueForKey:@"range"] rangeValue];
        id idxVal = [s valueForKey:@"sectionIndexTitleIndex"];
        id title = [s valueForKey:@"title"];
        NSUInteger n = 0;
        while (k < [keptIdx count]) {
            NSUInteger idx = [[keptIdx objectAtIndex:k] unsignedIntegerValue];
            if (idx >= r.location + r.length) break;
            if (idx >= r.location) n++;
            k++;
        }
        id ns = [[cls alloc] init];
        @try {
            if (title) [ns setValue:title forKey:@"title"];
            [ns setValue:[NSValue valueWithRange:NSMakeRange(cum, n)] forKey:@"range"];
            if (idxVal) [ns setValue:idxVal forKey:@"sectionIndexTitleIndex"];
        } @catch (NSException *e) { }
        [out addObject:ns];
        cum += n;
    }
    return out;
}

#pragma mark - Work part: a track belonging to several artists
//
// The iOS 6 schema stores ONE item_artist_pid/album_artist_pid per track, so an
// "Artist 1; Artist 2" track physically cannot live under two artists at once.
// Solution: leave the DB alone and extend drill-down queries — the predicate
// "albumArtistPID == X" is replaced by "albumArtist CONTAINS <X's name>".
// That way a song with a compound tag lands in the second artist's list too.

static BOOL gAFInPIDLookup = NO;

// How many library songs match the "<prop> CONTAINS <name>" predicate.
static NSUInteger AFCountItemsMatching(NSString *prop, NSString *name) {
    NSUInteger n = 0;
    if (![name length]) return 0;
    @try {
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingTitle];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:name
                                     forProperty:prop
                                  comparisonType:MPMediaPredicateComparisonContains]];
        n = [[q items] count];
    } @catch (NSException *e) { n = 0; }
    return n;
}


static NSMutableDictionary *gAFPropCache = nil;   // row name -> the tag property used for drill-down

// The item artist and album artist tags may diverge: a song can have only the artist tag
// filled (then it is in no album artist group) or only the album artist. If all songs with
// albumArtist CONTAINS name also have artist CONTAINS name, the artist-tag search is
// strictly wider — use it, otherwise a song without an album artist would be lost.
static NSString *AFWiderArtistProperty(NSString *name, NSString *prop) {
    if (![name length]) return prop;
    // The decision depends only on the library and costs three full-library queries —
    // so it is remembered until the next setQueries: of the artists list.
    NSString *cached = [gAFPropCache objectForKey:name];
    if ([cached length]) return cached;
    NSUInteger nAA = AFCountItemsMatching(@"albumArtist", name);
    NSUInteger nAr = AFCountItemsMatching(@"artist", name);
    NSString *res = prop;
    if (nAr > nAA) {
        // How many songs match both tags: if that equals the album artist count, the
        // album artist set is fully inside the item artist set.
        NSUInteger nBoth = 0;
        @try {
            MPMediaQuery *q = [[MPMediaQuery alloc] init];
            [q setGroupingType:MPMediaGroupingTitle];
            [q addFilterPredicate:[MPMediaPropertyPredicate
                                  predicateWithValue:name
                                         forProperty:@"albumArtist"
                                      comparisonType:MPMediaPredicateComparisonContains]];
            [q addFilterPredicate:[MPMediaPropertyPredicate
                                  predicateWithValue:name
                                         forProperty:@"artist"
                                      comparisonType:MPMediaPredicateComparisonContains]];
            nBoth = [[q items] count];
        } @catch (NSException *e) { nBoth = 0; }
        res = (nBoth == nAA) ? @"artist" : prop;
    }
    if (!gAFPropCache) gAFPropCache = [NSMutableDictionary dictionary];
    [gAFPropCache setObject:res forKey:name];
    return res;
}


// The lead artist name by pid (our -valueForProperty: already normalizes the tag).
// *outProp — which property to search this name by: "albumArtist" (the usual case) or
// "artist" (when a track has no album artist at all — then we rely on the track's artist
// tag, otherwise the artist list would end up empty).
static NSString *AFArtistNameForPIDProperty(unsigned long long pid,
                                            NSString *pidProp,
                                            NSString **outProp) {
    NSString *prop = @"albumArtist";
    NSString *name = nil;
    // Artists list: the row name may not be the lead tag component ("Artist 1; Artist 2"
    // -> "Artist 2"), so drill-down searches by that name.
    if ([pidProp isEqualToString:@"albumArtistPID"])
        name = AFArtistListNameForPID(pid, &prop);
    if (![name length]) {
        if (!pid || gAFInPIDLookup) {
            if (outProp) *outProp = prop;
            return name;
        }
        gAFInPIDLookup = YES;
        @try {
            MPMediaQuery *q = [[MPMediaQuery alloc] init];
            [q setGroupingType:MPMediaGroupingTitle];
            [q addFilterPredicate:
                 [MPMediaPropertyPredicate predicateWithValue:
                      [NSNumber numberWithUnsignedLongLong:pid]
                                                 forProperty:pidProp]];
            NSArray *items = [q items];
            if ([items count]) {
                id it = [items objectAtIndex:0];
                id aa = [it valueForProperty:@"albumArtist"];
                id ar = [it valueForProperty:@"artist"];
                if ([pidProp isEqualToString:@"artistPID"]) {
                    // Grouping by track artist: take the name from the artist tag.
                    if ([ar isKindOfClass:[NSString class]] && [ar length]) {
                        name = ar;
                        prop = @"artist";
                    }
                } else if ([aa isKindOfClass:[NSString class]] && [aa length]) {
                    name = aa;
                    prop = @"albumArtist";
                } else if ([ar isKindOfClass:[NSString class]] && [ar length]) {
                    name = ar;
                    prop = @"artist";
                }
            }
        } @catch (NSException *e) { }
        gAFInPIDLookup = NO;
    }
    if (![name length]) {
        if (outProp) *outProp = prop;
        return nil;
    }
    prop = AFWiderArtistProperty(name, prop);
    if (outProp) *outProp = prop;
    return name;
}


#if AF_DIAG
// Diagnostics: titles of the songs matching the "<prop> CONTAINS <name>" predicate.
__attribute__((unused)) static NSArray *AFItemTitles(NSString *prop, NSString *name) {
    NSMutableArray *t = [NSMutableArray array];
    if (![name length]) return t;
    @try {
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingTitle];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:name
                                     forProperty:prop
                                  comparisonType:MPMediaPredicateComparisonContains]];
        for (id it in [q items]) {
            id title = nil;
            @try { title = [it valueForProperty:@"title"]; } @catch (NSException *e) { }
            [t addObject:title ? title : @"?"];
        }
    } @catch (NSException *e) { }
    return t;
}
#endif // AF_DIAG

static id AFRewriteArtistPIDPredicate(id pred) {
#if AF_DIAG
    if ([pred isKindOfClass:[MPMediaPropertyPredicate class]]) {
        MPMediaPropertyPredicate *p2 = (MPMediaPropertyPredicate *)pred;
        AFLogDetail(@"[pred] prop=%@ value=%@ (%@) cmp=%d",
                    [p2 property], [p2 value],
                    NSStringFromClass([[p2 value] class]), (int)[p2 comparisonType]);
    } else {
        AFLogDetail(@"[pred] %@ (%@)", pred, NSStringFromClass([pred class]));
    }
#endif
    if (![pred isKindOfClass:[MPMediaPropertyPredicate class]]) return pred;
    MPMediaPropertyPredicate *pp = (MPMediaPropertyPredicate *)pred;
    NSString *prop = [pp property];
    id val = [pp value];
    if (![val isKindOfClass:[NSNumber class]]) return pred;
    if ([prop isEqualToString:@"albumPID"]) {
        // Merged album page: it has several album rows and the albumPID points to only one
        // of them — not all of its songs would land in the album by that pid. Search by
        // title instead.
        NSString *title = AFAlbumMergedTitle([val unsignedLongLongValue]);
        if (![title length]) return pred;
        AFLogDetail(@"[album] albumPID == %@ -> albumTitle == '%@'", val, title);
        return [MPMediaPropertyPredicate predicateWithValue:title forProperty:@"albumTitle"];
    }
    if (![prop isEqualToString:@"albumArtistPID"] &&
        ![prop isEqualToString:@"artistPID"]) return pred;
    NSString *name = [gAFPIDToArtist objectForKey:val];
    NSString *target = nil;
    if (![name length]) {
        name = AFArtistNameForPIDProperty([val unsignedLongLongValue], prop, &target);
    } else {
        target = AFWiderArtistProperty(name, @"artist");
    }
    if (![name length]) return pred;
    AFLogDetail(@"[drilldown] %@ == %@ -> %@ CONTAINS '%@'", prop, val, target, name);
    return [MPMediaPropertyPredicate predicateWithValue:name
                                            forProperty:target
                                         comparisonType:MPMediaPredicateComparisonContains];
}

// Row deduplication is not needed: every group now gets its own name (see above), so two
// rows with the same name never appear in the artists list.

%hook MPMediaQuery

// Lists are built from groups: for artists we drop the groups that got no row of their
// own, for albums — the album rows merged into another row of the same album (see
// AFFilterCollections).
- (NSArray *)collections {
    NSArray *r = %orig;
    AFLogDetail(@"[MPMediaQuery collections] self=%@ grouping=%lu count=%lu",
               self, (unsigned long)[self groupingType], (unsigned long)[r count]);
    AFLogDetailArray(@"[collections]", r, 12);
    return AFFilterCollections(self, r);
}

- (NSArray *)entities {
    NSArray *r = %orig;
    // main — the query is built on the main thread (background queries show 0)
    AFLogDetail(@"[MPMediaQuery entities] self=%@ grouping=%lu main=%d", self,
               (unsigned long)[self groupingType], (int)[NSThread isMainThread]);
    return AFFilterCollections(self, r);
}

- (NSArray *)collectionSections {
    if (AFIsAllArtistsQuery(self)) {
        AFBuildAllArtists();
        if ([gAFAllArtists count]) return AFSectionsForArtists(gAFAllArtists);
    }
    NSArray *r = %orig;
    AFLogDetail(@"[MPMediaQuery collectionSections] %@", r);
    if ([AFKeptIndexesOf(self) count]) return AFRemapSections(self, r);
    return r;
}

- (id)collectionSectionInfo {
    if (AFIsAllArtistsQuery(self)) {
        AFBuildAllArtists();
        if ([gAFAllArtists count]) {
            id r = %orig;
            if (r) {
                @try {
                    NSArray *sec = AFSectionsForArtists(gAFAllArtists);
                    if ([sec count]) [r setValue:sec forKey:@"sections"];
                } @catch (NSException *e) { }
            }
            return r;
        }
    }
    id r = %orig;
    AFLogDetail(@"[MPMediaQuery collectionSectionInfo] %@", r);
    if ([AFKeptIndexesOf(self) count] && r) {
        @try {
            NSArray *sec = [r valueForKey:@"sections"];
            if ([sec count]) [r setValue:AFRemapSections(self, sec) forKey:@"sections"];
        } @catch (NSException *e) { }
    }
    return r;
}

- (void)addFilterPredicate:(id)predicate {
    %orig(AFRewriteArtistPIDPredicate(predicate));
}

- (void)setFilterPredicates:(NSSet *)predicates {
    NSMutableSet *s = [NSMutableSet setWithCapacity:[predicates count]];
    for (id p in predicates) [s addObject:AFRewriteArtistPIDPredicate(p)];
    %orig(s);
}

%end


#pragma mark - Hooks: the point where a cell's display string is formed

%hook IUArrayCellConfiguration

- (id)stringForLabelAtIndex:(int)idx {
    id s = %orig;
    id ent = nil;
    @try {
        if ([self respondsToSelector:@selector(entity)]) ent = [self entity];
    } @catch (NSException *e) { }
#if AF_DIAG
    AFLogWrite(@"[label] %@ idx=%d -> '%@' entity=%@",
               NSStringFromClass([self class]), idx, s, NSStringFromClass([ent class]));
#endif
    id out = nil;
    if (idx == 1 && AFIsAlbumCell(self)) {
        NSString *line = AFAlbumArtistsLine(ent);
        out = [line length] ? line : s;
    } else {
        NSString *customArtist = ent ? objc_getAssociatedObject(ent, &kAFArtistNameKey) : nil;
        if (idx == 0 && [customArtist length]) {
            out = customArtist;
        } else if (idx == 1 && [customArtist length]) {
            NSNumber *cnt = objc_getAssociatedObject(ent, &kAFArtistSongCountKey);
            if (cnt) {
                NSUInteger c = [cnt unsignedIntegerValue];
                out = (c == 1) ? @"1 Song" : [NSString stringWithFormat:@"%lu Songs", (unsigned long)c];
            } else {
                out = s;
            }
        } else {
            out = AFNormalizeDisplayString(s, ent);
            if (idx == 0) out = AFArtistRowLabel(out, self, ent);
        }
    }
#if AF_DIAG
    // What exactly goes into the UILabel (after all substitutions): this line is what we
    // verify on the device — both the artists list and the album subtitles.
    if (out != s)
        AFLogWrite(@"[labelout] %@ idx=%d '%@' -> '%@'", NSStringFromClass([self class]),
                   idx, s, out);
    // What exactly goes into the UILabel of an artists-list row (after all substitutions).
    if ([self isKindOfClass:NSClassFromString(@"IUPlaylistCellConfiguration")])
        AFLogWrite(@"[rowlabel] idx=%d '%@' -> '%@' pid=%llu", idx, s, out,
                   AFArtistGroupPID(ent));
#endif
    return out;
}

%end

%hook MPMediaItem
- (id)valueForProperty:(id)key {
    id v = %orig;
    return AFMaybeFixArtistValue(key, v);
}
%end

%hook MPConcreteMediaItem
- (id)valueForProperty:(id)key {
    id v = %orig;
    return AFMaybeFixArtistValue(key, v);
}
%end

%hook MPMediaItemCollection
- (unsigned long long)persistentID {
    NSNumber *p = objc_getAssociatedObject(self, &kAFArtistPIDKey);
    if (p) return [p unsignedLongLongValue];
    return %orig;
}
- (id)valueForProperty:(id)key {
    NSString *custom = objc_getAssociatedObject(self, &kAFArtistNameKey);
    if ([custom length]) {
        if ([key isEqualToString:@"artist"] || [key isEqualToString:@"albumArtist"] ||
            [key isEqualToString:@"artistName"] || [key isEqualToString:@"albumArtistName"]) {
            return custom;
        }
        if ([key isEqualToString:@"persistentID"] ||
            [key isEqualToString:@"artistPersistentID"] ||
            [key isEqualToString:@"albumArtistPersistentID"]) {
            NSNumber *p = objc_getAssociatedObject(self, &kAFArtistPIDKey);
            if (p) return p;
        }
    }
    if (AFIsArtistPropertyKey(key)) {
        NSString *albumLine = AFAlbumArtistsLine(self);
        if ([albumLine length]) return albumLine;
    }
    id v = %orig;
    return AFMaybeFixArtistValue(key, v);
}
- (NSArray *)items {
    NSArray *r = %orig;
    unsigned long long pid = AFAlbumPID(self);
    NSString *mergedTitle = AFAlbumMergedTitle(pid);
    if ([mergedTitle length]) {
        NSArray *mergedItems = AFMergedAlbumItems(mergedTitle);
        if ([mergedItems count]) return mergedItems;
    }
    return r;
}
- (NSUInteger)count {
    NSNumber *c = objc_getAssociatedObject(self, &kAFArtistSongCountKey);
    if (c) return [c unsignedIntegerValue];
    unsigned long long pid = AFAlbumPID(self);
    NSString *mergedTitle = AFAlbumMergedTitle(pid);
    if ([mergedTitle length]) {
        NSArray *mergedItems = AFMergedAlbumItems(mergedTitle);
        if ([mergedItems count]) return [mergedItems count];
    }
    return %orig;
}
%end

%hook MPConcreteMediaItemCollection
- (unsigned long long)persistentID {
    NSNumber *p = objc_getAssociatedObject(self, &kAFArtistPIDKey);
    if (p) return [p unsignedLongLongValue];
    return %orig;
}
- (id)valueForProperty:(id)key {
    NSString *custom = objc_getAssociatedObject(self, &kAFArtistNameKey);
    if ([custom length]) {
        if ([key isEqualToString:@"artist"] || [key isEqualToString:@"albumArtist"] ||
            [key isEqualToString:@"artistName"] || [key isEqualToString:@"albumArtistName"]) {
            return custom;
        }
        if ([key isEqualToString:@"persistentID"] ||
            [key isEqualToString:@"artistPersistentID"] ||
            [key isEqualToString:@"albumArtistPersistentID"]) {
            NSNumber *p = objc_getAssociatedObject(self, &kAFArtistPIDKey);
            if (p) return p;
        }
    }
    if (AFIsArtistPropertyKey(key)) {
        NSString *albumLine = AFAlbumArtistsLine(self);
        if ([albumLine length]) return albumLine;
    }
    id v = %orig;
    return AFMaybeFixArtistValue(key, v);
}
- (NSArray *)items {
    NSArray *r = %orig;
    unsigned long long pid = AFAlbumPID(self);
    NSString *mergedTitle = AFAlbumMergedTitle(pid);
    if ([mergedTitle length]) {
        NSArray *mergedItems = AFMergedAlbumItems(mergedTitle);
        if ([mergedItems count]) return mergedItems;
    }
    return r;
}
- (NSUInteger)count {
    NSNumber *c = objc_getAssociatedObject(self, &kAFArtistSongCountKey);
    if (c) return [c unsignedIntegerValue];
    unsigned long long pid = AFAlbumPID(self);
    NSString *mergedTitle = AFAlbumMergedTitle(pid);
    if ([mergedTitle length]) {
        NSArray *mergedItems = AFMergedAlbumItems(mergedTitle);
        if ([mergedItems count]) return [mergedItems count];
    }
    return %orig;
}
%end

// ===AF_BLOCK_DIAG_HOOKS_BEGIN===
// Diagnostic hooks are always compiled: logos declares all _logos_orig$*/_logos_method$*
// in a single list at the point of the first %hook, so they cannot be hidden inside #if
// (the release build would fail with -Wundefined-internal). Their bodies are empty in
// release: AFLogDetail/AFLogDetailArray expand to no-ops and the hooks stay pass-through
// (they just call the original).
#pragma mark - Diagnostic hooks

%hook MPMediaQuery

- (id)init {
    id r = %orig;
    AFLogDetail(@"[MPMediaQuery init] %@", r);
    return r;
}

- (void)setGroupingType:(NSUInteger)type {
    AFLogDetail(@"[MPMediaQuery setGroupingType:%lu] self=%@",
               (unsigned long)type, self);
    %orig(type);
}

- (NSArray *)items {
    NSArray *r = %orig;
    AFLogDetail(@"[MPMediaQuery items] self=%@ grouping=%lu",
               self, (unsigned long)[self groupingType]);
    AFLogDetailArray(@"[items]", r, 12);
    return r;
}


- (NSArray *)itemSections {
    NSArray *r = %orig;
    AFLogDetail(@"[MPMediaQuery itemSections] %@", r);
    return r;
}

- (id)representativeItemForEntityAtIndex:(NSUInteger)idx {
    id r = %orig;
    AFLogDetail(@"[repItemForEntityAtIndex:%lu] self=%@ => %@ artist=%@",
               (unsigned long)idx, self, r,
               [r respondsToSelector:@selector(valueForProperty:)]
                   ? [r valueForProperty:@"artist"] : nil);
    return r;
}

- (id)itemSectionInfo {
    id r = %orig;
    AFLogDetail(@"[MPMediaQuery itemSectionInfo] %@", r);
    return r;
}

%end

%hook MPMediaItem

- (NSString *)artist {
    NSString *r = %orig;
    AFLogDetail(@"[MPMediaItem artist] %@ (title=%@)", r, [self valueForProperty:@"title"]);
    return r;
}

- (NSString *)albumArtist {
    NSString *r = %orig;
    AFLogDetail(@"[MPMediaItem albumArtist] %@ (title=%@)", r,
               [self valueForProperty:@"title"]);
    return r;
}

%end

%hook MPMediaItemCollection

+ (NSString *)titlePropertyForGroupingType:(int)type {
    NSString *r = %orig(type);
    AFLogDetail(@"+[MPMediaItemCollection titlePropertyForGroupingType:%d] => %@", type, r);
    return r;
}

+ (NSString *)representativePersistentIDPropertyForGroupingType:(int)type {
    NSString *r = %orig(type);
    AFLogDetail(@"+[MPMediaItemCollection representativePersistentIDPropertyForGroupingType:%d] => %@",
               type, r);
    return r;
}

%end

%hook MPConcreteMediaItemCollection

- (id)representativeItem {
    id r = %orig;
    AFLogDetail(@"[MPConcreteMediaItemCollection representativeItem] self=%@ id=%@ => %@ artist=%@",
               self, [self valueForProperty:@"persistentID"], r,
               [r respondsToSelector:@selector(valueForProperty:)]
                   ? [r valueForProperty:@"artist"] : nil);
    return r;
}

%end


#pragma mark - Diagnostic hooks: IU data sources

%hook IUMediaQueriesDataSource

- (NSUInteger)count {
    NSUInteger n = %orig;
    AFLogDetail(@"[IUMediaQueriesDataSource count] self=%@ => %lu", self, (unsigned long)n);
    return n;
}

- (id)entityAtIndex:(NSUInteger)idx {
    id r = %orig(idx);
    AFLogDetail(@"[entityAtIndex:%lu] self=%@ => %@ (%@)", (unsigned long)idx, self, r,
               NSStringFromClass([r class]));
    return r;
}

- (id)cellConfigurationForIndex:(NSUInteger)idx {
    id r = %orig(idx);
#if AF_DIAG
    id title = nil;
    @try {
        id e = [r respondsToSelector:@selector(entity)] ? [r entity] : nil;
        if ([e respondsToSelector:@selector(valueForProperty:)])
            title = [e valueForProperty:@"title"];
    } @catch (NSException *e) { }
    AFLogDetail(@"[cellConfigurationForIndex:%lu] self=%@ => %@ title=%@",
               (unsigned long)idx, self, r, title);
#endif
    return r;
}

- (id)cellConfigurationForIndex:(NSUInteger)idx shouldLoadArtwork:(BOOL)loadArtwork
    artworkLoadingCompletionHandler:(id)handler {
    id r = %orig(idx, loadArtwork, handler);
#if AF_DIAG
    id title = nil;
    @try {
        id e = [r respondsToSelector:@selector(entity)] ? [r entity] : nil;
        if ([e respondsToSelector:@selector(valueForProperty:)])
            title = [e valueForProperty:@"title"];
    } @catch (NSException *e) { }
    AFLogDetail(@"[cellConfigurationForIndex:%lu] self=%@ => %@ title=%@",
               (unsigned long)idx, self, r, title);
#endif
    return r;
}



%end

%hook IUArtistsDataSource

- (id)viewControllerContextForIndex:(NSUInteger)idx {
    id r = %orig(idx);
#if AF_DIAG
    id q = nil;
    @try { if ([r respondsToSelector:@selector(query)]) q = [r query]; }
    @catch (NSException *e) { }
    AFLogDetail(@"[IUArtistsDataSource viewControllerContextForIndex:%lu] => %@ query=%@",
               (unsigned long)idx, r, q);
#endif
    return r;
}

- (id)queryForDrillingIntoRowAtIndex:(NSUInteger)idx {
    id r = %orig(idx);
    if (idx < [gAFAllArtists count]) {
        NSString *artistName = [gAFAllArtists objectAtIndex:idx];
        AFLogDetail(@"[drilldown-row] row %lu -> artist '%@'", (unsigned long)idx, artistName);
        if ([artistName length]) {
            NSMutableSet *newPreds = [NSMutableSet set];
            for (id p in [r filterPredicates]) {
                if ([p isKindOfClass:[MPMediaPropertyPredicate class]]) {
                    NSString *prop = [p property];
                    if ([prop isEqualToString:@"artistPID"] || [prop isEqualToString:@"albumArtistPID"] ||
                        [prop isEqualToString:@"artist"] || [prop isEqualToString:@"albumArtist"]) {
                        continue;
                    }
                }
                [newPreds addObject:p];
            }
            NSString *widerProp = AFWiderArtistProperty(artistName, @"artist");
            [newPreds addObject:[MPMediaPropertyPredicate predicateWithValue:artistName
                                                                forProperty:widerProp
                                                             comparisonType:MPMediaPredicateComparisonContains]];
            [r setFilterPredicates:newPreds];
        }
    }
    AFLogDetail(@"[IUArtistsDataSource queryForDrillingIntoRowAtIndex:%lu] => %@",
               (unsigned long)idx, r);
    return r;
}

- (id)viewControllerContextForMediaQuery:(id)query {
    id r = %orig(query);
    AFLogDetail(@"[IUArtistsDataSource viewControllerContextForMediaQuery:%@] => %@",
               query, r);
    return r;
}

- (void)setQueries:(id)queries {
    AFLogDetail(@"[IUArtistsDataSource setQueries:%@]", queries);
    %orig(queries);
}

%end

// Cache resets are done on the common ancestor of all lists (artists, albums, songs,
// compilations): the library composition may have changed and the maps must be rebuilt.
// While the maps are being built we do not reset — the build runs on its own queries.
%hook IUMediaQueriesDataSource

- (void)setQueries:(id)queries {
    AFLogDetail(@"[IUMediaQueriesDataSource setQueries:%@] self=%@", queries,
               NSStringFromClass([self class]));
    if (!gAFArtistsBuilding && !gAFAlbumMapBuilding) {
        gAFAllArtists = nil;
        gAFArtistSongCounts = nil;
        gAFArtistItems = nil;
        gAFArtistRealCols = nil;
        gAFArtistPIDs = nil;
        gAFPIDToArtist = nil;
        gAFPropCache = nil;
        gAFAlbumMerge = nil;
        gAFAlbumLine = nil;
        gAFAlbumTitle = nil;
        gAFAlbumTitleToLine = nil;
        gAFAlbumMulti = nil;
    }
    %orig(queries);
}

%end

#pragma mark - Diagnostic hooks: IUMediaEntitySpecifier

%hook IUMediaEntitySpecifier

+ (id)mediaEntitySpecifierWithArtist:(id)artist albumString:(id)album baseMediaQuery:(id)q {
    id r = %orig(artist, album, q);
    AFLogDetail(@"+[IUMediaEntitySpecifier mediaEntitySpecifierWithArtist:%@ albumString:%@ baseMediaQuery:%@] => %@",
               artist, album, q, r);
    return r;
}

+ (id)_mediaEntitySpecifierWithArtist:(id)artist albumPID:(unsigned long long)pid
                        baseMediaQuery:(id)q {
    id r = %orig(artist, pid, q);
    AFLogDetail(@"+[IUMediaEntitySpecifier _mediaEntitySpecifierWithArtist:%@ albumPID:%llu baseMediaQuery:%@] => %@",
               artist, pid, q, r);
    return r;
}

+ (id)mediaQueryWithEntitiesOfType:(int)type givenSpecifier:(id)spec {
    id r = %orig(type, spec);
    AFLogDetail(@"+[IUMediaEntitySpecifier mediaQueryWithEntitiesOfType:%d givenSpecifier:%@] => %@",
               type, spec, r);
    return r;
}

%end


#pragma mark - Diagnostic hooks: cell configuration


@interface IUAlbumTrackListAggregateViewConfiguration : NSObject
- (id)_albumString;
- (id)_albumArtistString;
@end

%hook IUAlbumTrackListAggregateViewConfiguration

- (id)_albumArtistString {
    NSString *title = nil;
    @try { if ([self respondsToSelector:@selector(_albumString)]) title = [self _albumString]; } @catch (NSException *e) { }
    NSString *line = AFAlbumArtistsLineForTitle(title);
    if ([line length]) {
        AFLogDetail(@"[albumheader] _albumArtistString: '%@' -> '%@'", title, line);
        return line;
    }
    return %orig;
}

- (id)stringForLabelAtIndex:(NSUInteger)idx {
    if (idx == 0) {
        NSString *title = nil;
        @try { if ([self respondsToSelector:@selector(_albumString)]) title = [self _albumString]; } @catch (NSException *e) { }
        NSString *line = AFAlbumArtistsLineForTitle(title);
        if ([line length]) {
            AFLogDetail(@"[albumheader] stringForLabelAtIndex:0: '%@' -> '%@'", title, line);
            return line;
        }
    }
    return %orig(idx);
}

%end

%hook IUMediaEntityCellConfiguration

- (void)configureForEntity:(id)entity query:(id)query entityIndex:(unsigned int)idx
              entityCount:(unsigned int)cnt {
    @try {
        AFLogDetail(@"[cfg] self=%@ entity=%@ idx=%lu/%lu", NSStringFromClass([self class]),
                   NSStringFromClass([entity class]), (unsigned long)idx, (unsigned long)cnt);
        AFLogDetail(@"[cfg]   coll artist='%@' albumArtist='%@' title='%@' pid=%@",
                   [entity valueForProperty:@"artist"], [entity valueForProperty:@"albumArtist"],
                   [entity valueForProperty:@"title"], [entity valueForProperty:@"persistentID"]);
        if ([entity respondsToSelector:@selector(representativeItem)]) {
#if AF_DIAG
            id rep = [entity representativeItem];
            AFLogDetail(@"[cfg]   rep=%@ artist='%@' title='%@'",
                       NSStringFromClass([rep class]), [rep valueForProperty:@"artist"],
                       [rep valueForProperty:@"title"]);
#endif
        }
        AFLogDetail(@"[cfg]   displayProps=%@", [self displayProperties]);
    } @catch (NSException *e) { AFLogDetail(@"[cfg] ex %@", e); }
    %orig;
}

- (void)reloadStringsWithProperties:(id)props {
    AFLogDetail(@"[cfg reloadStrings] self=%@ props=%@ entity=%@",
               NSStringFromClass([self class]), props, [self entity]);
    %orig;
    @try { AFLogDetail(@"[cfg reloadStrings] strings=%@", [self valueForKey:@"strings"]); }
    @catch (NSException *e) { }
}

%end

%hook IUAlbumCellConfiguration

- (void)reloadStringsWithProperties:(id)props {
    %orig(props);
    id ent = nil;
    @try { ent = [self entity]; } @catch (NSException *e) { }
    NSString *line = AFAlbumArtistsLine(ent);
    if ([line length]) {
        @try { [self setSubtitle:line]; } @catch (NSException *e) { }
    }
}

%end

%hook IUCoverFlowViewController

- (void)setDataSource:(id)ds {
    AFLogDetail(@"[coverflow] IUCoverFlowViewController setDataSource: <%@>",
                NSStringFromClass([ds class]));
    %orig;
}

%end

%hook IUMusicCoverFlowController

- (id)initWithDelegate:(id)delegate {
    id r = %orig(delegate);
    AFLogDetail(@"[coverflow] initWithDelegate: self=%@ delegate=<%@>", self,
                NSStringFromClass([delegate class]));
    return r;
}

- (id)query {
    id q = %orig;
#if AF_DIAG
    NSArray *cols = nil;
    @try { cols = [q collections]; } @catch (NSException *e) { cols = nil; }
    AFLogDetail(@"[coverflow] -query => %@ grouping=%lu preds=%@ cols=%lu", q,
                q ? (unsigned long)[q groupingType] : 0UL,
                q ? [q filterPredicates] : nil, (unsigned long)[cols count]);
    for (NSUInteger i = 0; i < [cols count] && i < 16; i++) {
        id c = [cols objectAtIndex:i];
        AFLogDetail(@"[coverflow]   col[%lu] %@ pid=%llu albumPID=%@",
                    (unsigned long)i, NSStringFromClass([c class]),
                    AFAlbumPID(c), [c valueForProperty:@"albumPID"]);
    }
#endif
    return q;
}

- (BOOL)_buildCoverFlow:(int)orientation {
    AFLogDetail(@"[coverflow] _buildCoverFlow:%d enter self=%@", orientation, self);
    BOOL r = %orig(orientation);
#if AF_DIAG
    id q = nil;
    @try { q = [self query]; } @catch (NSException *e) { }
    NSArray *cols = nil, *items = nil;
    @try { cols = [q collections]; } @catch (NSException *e) { }
    @try { items = [q items]; } @catch (NSException *e) { }
    AFLogDetail(@"[coverflow] _buildCoverFlow: exit r=%d query=%@ grouping=%lu cols=%lu items=%lu",
                (int)r, q, q ? (unsigned long)[q groupingType] : 0UL,
                (unsigned long)[cols count], (unsigned long)[items count]);
#endif
    return r;
}

- (unsigned int)_currentSongIndexInCoverFlowQuery:(BOOL)allowCreateSuffix {
    unsigned int idx = %orig(allowCreateSuffix);
    id q = nil;
    @try { q = [self query]; } @catch (NSException *e) { }
    NSArray *cols = nil;
    @try { cols = [q collections]; } @catch (NSException *e) { }
    NSUInteger count = [cols count];
    if (!count || idx < count) return idx;

    // If the current song belongs to the merged part of an album (its albumPID was hidden
    // in AFFilterCollections), the original method did not find it in cols, stored it in
    // _suffixMediaItem and returned count (which makes CoverFlow show a second copy of
    // the album). Redirect to the main cover.
    AFBuildAlbumMap();
    id item = nil;
    @try { item = [self valueForKey:@"_suffixMediaItem"]; } @catch (NSException *e) { }
    if (!item) {
        @try {
            Class avCls = NSClassFromString(@"MPAVController");
            if (avCls && [avCls respondsToSelector:@selector(sharedInstance)]) {
                id av = [avCls performSelector:@selector(sharedInstance)];
                if ([av respondsToSelector:@selector(currentMediaItem)])
                    item = [av performSelector:@selector(currentMediaItem)];
            }
        } @catch (NSException *e) { }
    }
    if (!item) return idx;

    unsigned long long itemAlbumPID = 0;
    @try { itemAlbumPID = [[item valueForProperty:@"albumPID"] unsignedLongLongValue]; }
    @catch (NSException *e) { itemAlbumPID = 0; }

    NSNumber *keepNum = itemAlbumPID
        ? [gAFAlbumMerge objectForKey:[NSNumber numberWithUnsignedLongLong:itemAlbumPID]]
        : nil;
    unsigned long long targetPID = keepNum ? [keepNum unsignedLongLongValue] : itemAlbumPID;

    NSUInteger foundIdx = NSNotFound;
    if (targetPID) {
        for (NSUInteger i = 0; i < count; i++) {
            if (AFAlbumPID([cols objectAtIndex:i]) == targetPID) {
                foundIdx = i;
                break;
            }
        }
    }
    if (foundIdx == NSNotFound) {
        NSString *itemAlbumTitle = nil;
        @try { itemAlbumTitle = [item valueForProperty:@"albumTitle"]; } @catch (NSException *e) { }
        if ([itemAlbumTitle length]) {
            for (NSUInteger i = 0; i < count; i++) {
                NSString *colTitle = nil;
                @try { colTitle = [[cols objectAtIndex:i] valueForProperty:@"albumName"]; } @catch (NSException *e) { }
                if (![colTitle length]) {
                    @try { colTitle = [[cols objectAtIndex:i] valueForProperty:@"albumTitle"]; } @catch (NSException *e) { }
                }
                if ([colTitle isEqualToString:itemAlbumTitle]) {
                    foundIdx = i;
                    break;
                }
            }
        }
    }

    if (foundIdx != NSNotFound) {
        @try { [self setValue:nil forKey:@"_suffixMediaItem"]; } @catch (NSException *e) { }
        Ivar idxIvar = class_getInstanceVariable([self class], "_albumIndexOfCurrentSong");
        if (idxIvar) {
            unsigned int *idxPtr = (unsigned int *)((char *)(__bridge void *)self + ivar_getOffset(idxIvar));
            *idxPtr = (unsigned int)foundIdx;
        }
        AFLogDetail(@"[coverflow] mapped merged song (albumPID=%llu -> %llu) to cover %lu, cleared _suffixMediaItem",
                    itemAlbumPID, targetPID, (unsigned long)foundIdx);
        return (unsigned int)foundIdx;
    }
    return idx;
}

- (int)numberOfItemsInCoverFlowView:(id)view {
    int n = %orig(view);
    AFLogDetail(@"[coverflow] numberOfItemsInCoverFlowView: => %d", n);
    return n;
}

- (id)_stringValueForProperty:(id)prop ofEntityAtIndex:(unsigned int)idx placeholder:(id)placeholder {
    if (AFIsArtistPropertyKey(prop)) {
        id q = nil;
        @try { q = [self query]; } @catch (NSException *e) { }
        NSArray *cols = nil;
        @try { cols = [q collections]; } @catch (NSException *e) { }
        if (idx < [cols count]) {
            NSString *line = AFAlbumArtistsLine([cols objectAtIndex:idx]);
            if ([line length]) {
                AFLogDetail(@"[coverflow] _stringValueForProperty:%@ idx=%u -> '%@'", prop, idx, line);
                return line;
            }
        }
        NSString *albumTitle = nil;
        @try { albumTitle = %orig(@"albumName", idx, nil); } @catch (NSException *e) { }
        if (![albumTitle length]) {
            @try { albumTitle = %orig(@"albumTitle", idx, nil); } @catch (NSException *e) { }
        }
        if ([albumTitle length]) {
            NSString *line = AFAlbumArtistsLineForTitle(albumTitle);
            if ([line length]) {
                AFLogDetail(@"[coverflow] _stringValueForProperty:%@ idx=%u -> '%@'", prop, idx, line);
                return line;
            }
        }
    }
    return %orig(prop, idx, placeholder);
}

%end

%hook IUMusicPropertiesView

- (void)setProperties:(id)props {
    if ([props isKindOfClass:[NSArray class]] && [props count] >= 2) {
        NSString *album = [props lastObject];
        if ([album isKindOfClass:[NSString class]] && [album length]) {
            NSString *line = AFAlbumArtistsLineForTitle(album);
            if ([line length]) {
                NSMutableArray *m = [props mutableCopy];
                [m replaceObjectAtIndex:0 withObject:line];
                %orig(m);
                return;
            }
        }
    }
    %orig(props);
}

%end

%hook IUMediaDataSource

- (unsigned int)count {
    unsigned int n = %orig;
    if ([self isKindOfClass:NSClassFromString(@"IUAlbumsDataSource")])
        AFLogDetail(@"[coverflow] IUMediaDataSource count self=<%@> => %u",
                    NSStringFromClass([self class]), n);
    return n;
}

%end

// ===AF_BLOCK_DIAG_HOOKS_END===


// ===AF_BLOCK_AUTOPILOT_BEGIN===
#if AF_DIAG
#if AF_ENABLE_AUTOPILOT

#pragma mark - Artist page dump (diagnostics, no taps)

// Check that "the album is attributed to every participating artist": for each
// artists-list group we build the same query as drill-down (albumArtistPID == <pid> — our
// hook turns it into CONTAINS) and print the page's albums together with the subtitle our
// hook returns (AFAlbumArtistsLine) and the page's songs. The fragile autopilot navigation
// is not needed here.
static void AFDumpArtistPages(void) {
    AFLogWrite(@"=== ARTISTPAGES START ===");
    MPMediaQuery *aq = [[MPMediaQuery alloc] init];
    [aq setGroupingType:MPMediaGroupingAlbumArtist];
    [aq addFilterPredicate:[MPMediaPropertyPredicate predicateWithValue:[NSNumber numberWithInt:1]
                                                           forProperty:@"mediaType"]];
    for (id c in [aq collections]) {
        unsigned long long pid = AFArtistGroupPID(c);
        NSString *name = AFArtistListNameForPID(pid, NULL);
        MPMediaQuery *q = [[MPMediaQuery alloc] init];
        [q setGroupingType:MPMediaGroupingAlbum];
        [q addFilterPredicate:[MPMediaPropertyPredicate
                              predicateWithValue:[NSNumber numberWithUnsignedLongLong:pid]
                                     forProperty:@"albumArtistPID"]];
        NSArray *albums = [q collections];
        AFLogWrite(@"ARTISTPAGES: artist '%@' (pid=%llu): %lu albums, %lu songs",
                   name ? name : @"?", pid, (unsigned long)[albums count],
                   (unsigned long)[[q items] count]);
        for (id a in albums) {
            id title = nil, apid = nil;
            @try { title = [a valueForProperty:@"title"]; } @catch (NSException *e) { }
            @try { apid = [a valueForProperty:@"persistentID"]; } @catch (NSException *e) { }
            AFLogWrite(@"ARTISTPAGES:   '%@' / '%@' (album pid=%@, %lu songs)", title,
                       AFAlbumArtistsLine(a), apid, (unsigned long)[[a items] count]);
        }
        for (id it in [q items]) {
            AFLogWrite(@"ARTISTPAGES:   song '%@' (artist='%@' albumArtist='%@')",
                       [it valueForProperty:@"title"], [it valueForProperty:@"artist"],
                       [it valueForProperty:@"albumArtist"]);
        }
    }
    AFLogWrite(@"=== ARTISTPAGES END ===");
}

#pragma mark - UI autopilot (diagnostics)

static UITableView *AFFindTable(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITableView class]]) return (UITableView *)v;
    for (UIView *s in [v subviews]) {
        UITableView *t = AFFindTable(s);
        if (t) return t;
    }
    return nil;
}

static UIWindow *AFKeyWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = [app keyWindow];
    if (!w && [[app windows] count]) w = [[app windows] objectAtIndex:0];
    return w;
}

static void AFDumpLabels(UIView *v, NSString *tag, int depth) {
    if (!v || depth > 4) return;
    if ([v isKindOfClass:[UILabel class]] && [[(UILabel *)v text] length])
        AFLogWrite(@"%@:       label '%@'", tag, [(UILabel *)v text]);
    for (UIView *s in [v subviews]) AFDumpLabels(s, tag, depth + 1);
}

static UITabBarController *AFFindTabBarController(void) {
    NSMutableArray *q = [NSMutableArray array];
    for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
        if ([w rootViewController]) [q addObject:[w rootViewController]];
        [q addObject:w];
    }
    while ([q count]) {
        id o = [q objectAtIndex:0];
        [q removeObjectAtIndex:0];
        if ([o isKindOfClass:[UITabBarController class]]) return (UITabBarController *)o;
        if ([o isKindOfClass:[UIViewController class]]) {
            UIViewController *vc = (UIViewController *)o;
            if ([vc presentedViewController]) [q addObject:[vc presentedViewController]];
            for (UIViewController *c in [vc childViewControllers]) [q addObject:c];
        } else if ([o isKindOfClass:[UIView class]]) {
            for (UIView *s in [(UIView *)o subviews]) {
                [q addObject:s];
                if ([s isKindOfClass:[UITabBar class]]) {
                    id d = [(UITabBar *)s delegate];
                    if ([d isKindOfClass:[UITabBarController class]])
                        return (UITabBarController *)d;
                }
            }
        }
    }
    return nil;
}

static BOOL AFSelectArtistsTab(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UITabBarController *tbc = AFFindTabBarController();
    if (!tbc) {
        UIWindow *w = [app keyWindow];
        AFLogWrite(@"AFDRIVE: no tabbar; rootVC=%@ windowSubviews=%@",
                   NSStringFromClass([[w rootViewController] class]), [w subviews]);
        return NO;
    }
    NSArray *vcs = [tbc viewControllers];
    NSUInteger target = 0;
    for (NSUInteger i = 0; i < [vcs count]; i++) {
        UIViewController *vc = [vcs objectAtIndex:i];
        NSString *inner = @"";
        if ([vc isKindOfClass:[UINavigationController class]])
            inner = NSStringFromClass([[(UINavigationController *)vc topViewController] class]);
        NSString *hay = [[NSString stringWithFormat:@"%@ %@ %@", NSStringFromClass([vc class]),
                          [[vc tabBarItem] title], inner] lowercaseString];
        AFLogWrite(@"AFDRIVE tab[%lu] %@ title=%@ inner=%@", (unsigned long)i,
                   NSStringFromClass([vc class]), [[vc tabBarItem] title], inner);
        if ([hay rangeOfString:@"artist"].location != NSNotFound) target = i;
    }
    AFLogWrite(@"AFDRIVE: selecting tab %lu (current %lu)",
               (unsigned long)target, (unsigned long)[tbc selectedIndex]);
    [tbc setSelectedIndex:target];
    return YES;
}


// The table actually shown right now: take it from the selected tab's top controller
// instead of the first one found in the hierarchy (two tables live in the window during
// transitions).
static UITableView *AFVisibleTable(void) {
    UITabBarController *tbc = AFFindTabBarController();
    id sel = [tbc selectedViewController];
    if ([sel isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = [(UINavigationController *)sel topViewController];
        UITableView *tv = AFFindTable([top view]);
        if (tv) return tv;
    }
    return AFFindTable(AFKeyWindow());
}

static NSInteger AFVisibleTableRows(NSInteger section) {
    UITableView *tv = AFVisibleTable();
    if (!tv) return 0;
    if (section >= [tv numberOfSections]) return 0;
    return [tv numberOfRowsInSection:section];
}

// The row's cell configuration: it holds exactly the strings the user sees.
// [tv dataSource] is IUMusicViewController; cellConfigurationForIndex: is forwarded to its
// IU*DataSource, so respondsToSelector: lies here — just call it and catch the exception.
static id AFCellConfigurationAt(id ds, NSInteger row) {
    if (!ds) return nil;
    typedef id (*AFIntFn)(id, SEL, int);
    id cfg = nil;
    @try { cfg = ((AFIntFn)objc_msgSend)(ds, @selector(cellConfigurationForIndex:), (int)row); }
    @catch (NSException *e) { cfg = nil; }
    return cfg;
}

// An action row ("Play All"/"Shuffle All") — never tap those.
static BOOL AFIsActionRow(id ds, NSInteger row) {
    id cfg = AFCellConfigurationAt(ds, row);
    Class act = NSClassFromString(@"IUMusicActionRowCellConfiguration");
    return (act && cfg && [cfg isKindOfClass:act]) ? YES : NO;
}

static BOOL AFIsArtistsListVisible(void) {
    UITableView *tv = AFVisibleTable();
    if (!tv) return NO;
    Class cls = NSClassFromString(@"IUArtistsDataSource");
    return cls && [[tv dataSource] isKindOfClass:cls];
}

static BOOL AFTapRowAt(NSString *tag, NSInteger section, NSInteger row) {
    UITableView *tv = AFVisibleTable();
    if (!tv) { AFLogWrite(@"%@: no table", tag); return NO; }
    if (section >= [tv numberOfSections] ||
        row >= [tv numberOfRowsInSection:section]) {
        AFLogWrite(@"%@: no row %ld/%ld (sections=%ld)",
                   tag, (long)section, (long)row, (long)[tv numberOfSections]);
        return NO;
    }
    id del = [tv delegate];
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
    AFLogWrite(@"%@: delegate=%@ ds=%@ tap row %ld/%ld", tag,
               NSStringFromClass([del class]), NSStringFromClass([[tv dataSource] class]),
               (long)section, (long)row);
    @try { [del tableView:tv didSelectRowAtIndexPath:ip]; }
    @catch (NSException *e) { AFLogWrite(@"%@: ex %@", tag, e); }
    return YES;
}

static void AFPopVisibleNav(void) {
    UITabBarController *tbc = AFFindTabBarController();
    id sel = [tbc selectedViewController];
    if ([sel isKindOfClass:[UINavigationController class]]) {
        AFLogWrite(@"AFDRIVE: pop to root (stack=%lu)",
                   (unsigned long)[[(UINavigationController *)sel viewControllers] count]);
        [(UINavigationController *)sel popToRootViewControllerAnimated:NO];
    }
}


static void AFDumpVisibleTable(NSString *tag) {
    UITableView *tv = AFVisibleTable();
    if (!tv) { AFLogWrite(@"%@: table not found", tag); return; }
    id ds = [tv dataSource];
    AFLogWrite(@"%@: table=%@ dataSource=%@ sections=%ld", tag, tv,
               NSStringFromClass([ds class]), (long)[tv numberOfSections]);
    for (NSInteger s = 0; s < [tv numberOfSections]; s++) {
        NSInteger rows = [tv numberOfRowsInSection:s];
        AFLogWrite(@"%@:   section %ld rows=%ld", tag, (long)s, (long)rows);
        for (NSInteger r = 0; r < rows && r < 6; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            UITableViewCell *cell = nil;
            @try { cell = [ds tableView:tv cellForRowAtIndexPath:ip]; }
            @catch (NSException *e) { }
            AFLogWrite(@"%@:     row %ld cell=%@ text=%@ detail=%@", tag, (long)r,
                       NSStringFromClass([cell class]), [[cell textLabel] text],
                       [[cell detailTextLabel] text]);
            AFDumpLabels(cell, tag, 0);
            id cfg = AFCellConfigurationAt(ds, r);
            if (cfg) {
                id l0 = nil, l1 = nil;
                @try { l0 = [cfg stringForLabelAtIndex:0]; } @catch (NSException *e) { }
                @try { l1 = [cfg stringForLabelAtIndex:1]; } @catch (NSException *e) { }
                AFLogWrite(@"%@:     cfg=%@ label0='%@' label1='%@' entity=%@", tag,
                           NSStringFromClass([cfg class]), l0, l1,
                           NSStringFromClass([[cfg entity] class]));
            }
        }
    }
}

// Walk over all artists-list rows: tap -> dump -> back -> next row.
static void AFDriveRow(NSInteger row, NSInteger rows) {
    if (row >= rows) { AFLogWrite(@"AFDRIVE: all rows done (%ld)", (long)rows); return; }
    UITableView *tv = AFVisibleTable();
    if (AFIsActionRow([tv dataSource], row)) {
        AFLogWrite(@"AFDRIVE: row %ld is an action row, skipping", (long)row);
        AFDriveRow(row + 1, rows);
        return;
    }
    NSString *tag = [NSString stringWithFormat:@"AFDRIVE-tap%ld", (long)row];
    AFTapRowAt(tag, 1, row);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AFDumpVisibleTable([NSString stringWithFormat:@"AFDRIVE-detail%ld", (long)row]);
        AFPopVisibleNav();
        // Return to the artists list explicitly: pop does not always reach the root, and
        // the tab has to be selected again, otherwise the next row is tapped in the wrong
        // list.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AFSelectArtistsTab();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AFDumpVisibleTable(@"AFDRIVE-back");
                AFDriveRow(row + 1, AFVisibleTableRows(1));
            });
        });
    });
}

static void AFDriveStep(int attempt) {
    if (attempt > 25) { AFLogWrite(@"AFDRIVE: giving up"); return; }
    if (!AFSelectArtistsTab()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ AFDriveStep(attempt + 1); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AFDumpVisibleTable(@"AFDRIVE-list");
        NSInteger rows = AFVisibleTableRows(1);
        if (rows <= 1 && attempt < 10) {
            AFLogWrite(@"AFDRIVE: %ld rows, list still loading", (long)rows);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ AFDriveStep(attempt + 1); });
            return;
        }
        AFLogWrite(@"AFDRIVE: artists list rows = %ld (artistsList=%d)",
                   (long)rows, (int)AFIsArtistsListVisible());
        AFDriveRow(0, rows);
    });
}

static void AFDrive(void) {
    AFDriveStep(0);
}
#endif // AF_ENABLE_AUTOPILOT

%ctor {
    AFLogWrite(@"=== ArtistFix loaded: %@ pid=%d ===",
               [[NSProcessInfo processInfo] processName], getpid());
    AFLogWrite(@"runtime: ML3MusicLibrary=%@ ML3Track=%@ ML3Artist=%@ MPMediaQuery=%@",
               objc_getClass("ML3MusicLibrary") ? @"yes" : @"no",
               objc_getClass("ML3Track") ? @"yes" : @"no",
               objc_getClass("ML3Artist") ? @"yes" : @"no",
               objc_getClass("MPMediaQuery") ? @"yes" : @"no");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AFDumpClasses();
        AFSelfTest();
        AFQueryTest();
        AFAlbumProbe();
    });
#if AF_ENABLE_AUTOPILOT
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AFDumpArtistPages();
        AFDrive();
    });
#endif
}

#endif // AF_DIAG — end of the diagnostic autopilot

#pragma mark - Entry point

%ctor {
    AFLogDetail(@"=== ArtistFix (work mode) loaded: %@ ===",
                [[NSProcessInfo processInfo] processName]);
}
