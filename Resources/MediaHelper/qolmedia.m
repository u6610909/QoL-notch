// QoL Notch's now-playing helper.
//
// Since macOS 15.4 only Apple's own programs may read what is playing system-wide (which is
// how a browser tab's music is visible at all). The system Perl is one of those programs, so
// QoL Notch runs this small library inside /usr/bin/perl and reads its output. Written for QoL Notch; MIT.
//
// QOL_MODE=stream  print one JSON line each time the now-playing state changes
// QOL_MODE=cmd     send the media command numbered QOL_ARG (2 play/pause, 4 next, 5 previous)
// QOL_MODE=seek    jump to QOL_ARG seconds
#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(unsigned int, CFDictionaryRef);
typedef void (*SeekFn)(double);

static void *lib;
static NSData *lastArtwork;
static NSString *artworkPath;
static int artworkCount;
static NSString *lastLine;

static void emit(void) {
    GetInfoFn getInfo = (GetInfoFn)dlsym(lib, "MRMediaRemoteGetNowPlayingInfo");
    GetPlayingFn getPlaying = (GetPlayingFn)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetPIDFn getPID = (GetPIDFn)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!getInfo || !getPlaying || !getPID) return;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = raw ? [(__bridge NSDictionary *)raw copy] : @{};
        getPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getPID(dispatch_get_main_queue(), ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = @([stamp isKindOfClass:NSDate.class] ? stamp.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
                out[@"playing"] = @(playing ? YES : NO);
                out[@"pid"] = @(pid);

                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && art.length > 0) {
                    if (![art isEqualToData:lastArtwork]) {
                        if (artworkPath) [NSFileManager.defaultManager removeItemAtPath:artworkPath error:nil];
                        artworkPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"qolnotch-artwork-%d-%d", getpid(), ++artworkCount]];
                        [art writeToFile:artworkPath atomically:YES];
                        lastArtwork = art;
                    }
                    out[@"artwork"] = artworkPath;
                } else {
                    out[@"artwork"] = @"";
                }

                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                if (!line || [line isEqualToString:lastLine]) return;
                lastLine = line;
                printf("%s\n", line.UTF8String);
                fflush(stdout);
            });
        });
    });
}

void qol_run(void *unused1, void *unused2) {
    @autoreleasepool {
        lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!lib) exit(2);
        NSString *mode = NSProcessInfo.processInfo.environment[@"QOL_MODE"] ?: @"stream";
        NSString *arg = NSProcessInfo.processInfo.environment[@"QOL_ARG"] ?: @"0";

        if ([mode isEqualToString:@"cmd"]) {
            SendFn send = (SendFn)dlsym(lib, "MRMediaRemoteSendCommand");
            if (send) send((unsigned int)arg.intValue, NULL);
        } else if ([mode isEqualToString:@"seek"]) {
            SeekFn seek = (SeekFn)dlsym(lib, "MRMediaRemoteSetElapsedTime");
            if (seek) seek(arg.doubleValue);
        }
        if (![mode isEqualToString:@"stream"]) {
            // Give the command a moment to leave before quitting.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
            CFRunLoopRun();
            return;
        }

        RegisterFn reg = (RegisterFn)dlsym(lib, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (reg) reg(dispatch_get_main_queue());
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { emit(); }];
        }
        emit();
        // Re-check now and then in case a notification was missed, and quit when QoL Notch has gone.
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{
            if (getppid() == 1) {
                if (artworkPath) [NSFileManager.defaultManager removeItemAtPath:artworkPath error:nil];
                exit(0);
            }
            emit();
        });
        dispatch_resume(timer);
        CFRunLoopRun();
    }
}
