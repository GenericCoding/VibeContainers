#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#import <mach/machine.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <string.h>
#import "../../LiveContainer-3.8.0/LiveContainer/LCMachOUtils.h"

extern int32_t IOSSimHostMain(void);
extern int LiveContainerMain(int argc, char *argv[]);
extern void IOSSimInstallGuestExitControl(void);
extern bool IOSSimJITLessSigningConfigured(void);

#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

/// Whether a debugger or JIT provider advertises an attached/debugged process.
/// This is a routing signal only, never permission to execute a test page.
static bool IOSSimProcessIsDebugged(void) {
    int flags = 0;
    return csops(getpid(), 0, &flags, sizeof(flags)) == 0 &&
           (flags & CS_DEBUGGED) != 0;
}

bool IOSSimProcessHasJIT(void) {
#if TARGET_OS_SIMULATOR
    return true;
#else
    // MAP_JIT is not a capability check on iOS: a stock process can receive a
    // mapping and still be killed when the CPU fetches its first instruction.
    // CS_DEBUGGED can route a relaunch through an already attached provider,
    // but deliberately is not treated as proof that a test page is executable.
    return IOSSimProcessIsDebugged();
#endif
}

/// Reports the host's JIT mode without executing generated code.
///
/// A MAP_JIT/mprotect result and CS_DEBUGGED are not sufficient proof that an
/// arbitrary instruction fetch is safe on every iOS launch mode. In particular,
/// Xcode can mark a JIT-less process debugged while AMFI still rejects the fetch
/// before a POSIX signal handler can recover. This function is called whenever
/// Settings opens, so a destructive execution probe is the wrong abstraction.
/// The Simulator is known to support its host-backed runtime. A physical device
/// uses the selected JIT-less mode or provider/debugger state only; it never maps
/// or branches into generated memory here.
int32_t IOSSimProbeJIT(void) {
#if TARGET_OS_SIMULATOR
    return 0;
#else
    if (IOSSimJITLessSigningConfigured()) return EPERM;
    return IOSSimProcessHasJIT() ? 0 : EPERM;
#endif
}

static int32_t IOSSimOpenRelaunchURL(NSURL *launchURL, int tries) {
    UIApplication *application = UIApplication.sharedApplication;
    if (![application canOpenURL:launchURL]) return ENOENT;

    for (int attempt = 0; attempt < tries; attempt++) {
        [application openURL:launchURL options:@{} completionHandler:^(BOOL opened) {
            if (!opened) return;
            // A hard termination is LiveContainer's original handoff. It
            // avoids dismantling UIKit state underneath the incoming guest.
            raise(SIGKILL);
        }];
    }
    return 0;
}

/// LiveContainer's normal launcher queues its own URL twice and terminates the
/// current process. The second open request gives SpringBoard a pending launch
/// after the current UIKit scene disappears, so the guest starts in a fresh,
/// RunningBoard-managed process instead of replacing a live process with execv.
int32_t IOSSimRelaunchForGuest(void) {
#if TARGET_OS_SIMULATOR
    NSURL *launchURL = [NSURL URLWithString:@"iossim://livecontainer-relaunch"];
    return IOSSimOpenRelaunchURL(launchURL, 2);
#else
    UIApplication *application = UIApplication.sharedApplication;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    NSURL *launchURL = nil;

    // LiveContainer's JIT-less path is an ordinary self-relaunch: every guest
    // Mach-O already satisfies the host's library validation, so no provider
    // needs to attach to the fresh SpringBoard-managed process.
    if (IOSSimJITLessSigningConfigured()) {
        launchURL = [NSURL URLWithString:@"iossim://livecontainer-relaunch"];
        return IOSSimOpenRelaunchURL(launchURL, 2);
    }

    // Otherwise preserve LiveContainer's native device ordering. These
    // providers enable JIT on the fresh process before it consumes the ticket.
    // A process already launched with persistent JIT may relaunch itself.
    NSString *trollStoreMarker = [NSString stringWithFormat:@"%@/../_TrollStore",
                                  NSBundle.mainBundle.bundlePath];
    if (access(trollStoreMarker.fileSystemRepresentation, F_OK) == 0) {
        launchURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"apple-magnifier://enable-jit?bundle-id=%@", bundleID]];
    } else if ([application canOpenURL:[NSURL URLWithString:@"stikjit://"]]) {
        launchURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"stikjit://enable-jit?bundle-id=%@", bundleID]];
    } else if ([application canOpenURL:[NSURL URLWithString:@"sidestore://"]]) {
        launchURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"sidestore://sidejit-enable?bid=%@", bundleID]];
    } else if (IOSSimProcessHasJIT()) {
        launchURL = [NSURL URLWithString:@"iossim://livecontainer-relaunch"];
        return IOSSimOpenRelaunchURL(launchURL, 2);
    } else {
        return EPERM;
    }

    return IOSSimOpenRelaunchURL(launchURL, 1);
#endif
}

/// Returning to the host UI never needs JIT, so the Live Activity exit action
/// bypasses JIT providers and performs a normal self-URL relaunch.
int32_t IOSSimRelaunchForHost(void) {
    return IOSSimOpenRelaunchURL(
        [NSURL URLWithString:@"iossim://livecontainer-relaunch"], 2
    );
}

/// Uses LiveContainer's own Mach-O conversion rather than maintaining a second
/// executable patcher in iOSSim. The caller owns the returned error string.
char *IOSSimPatchGuestExecutable(const char *path) {
    __block BOOL foundArm64 = NO;
    __block BOOL encrypted = NO;
    __block int patchResult = 0;

    NSString *parseError = LCParseMachO(path, false, ^(const char *slicePath,
                                                        struct mach_header_64 *header,
                                                        int fd, void *mapping) {
        if (header->cputype != CPU_TYPE_ARM64) return;
        foundArm64 = YES;
        encrypted |= LCIsMachOEncrypted(header);
        if (!encrypted) {
            // iOSSim does not inject TweakLoader. LiveContainer still reserves
            // its load-command slot, preserving the upstream patch layout.
            patchResult = LCPatchExecSlice(slicePath, header, false);
        }
    });

    if (parseError) return strdup(parseError.UTF8String);
    if (!foundArm64) return strdup("The IPA has no arm64 executable slice.");
    if (encrypted) return strdup("The IPA is FairPlay-encrypted; use a decrypted IPA.");
    if (patchResult & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER) {
        // This bit is harmless here: no TweakLoader command is required.
        patchResult &= ~PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER;
    }
    NSURL *executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    LCPatchAppBundleFixupARM64eSlice(executableURL.URLByDeletingLastPathComponent);
    return NULL;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *ticketPath = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/.iossim-livecontainer-launch.plist"];
        NSDictionary *ticket = [NSDictionary dictionaryWithContentsOfFile:ticketPath];
        NSString *bundlePath = ticket[@"bundlePath"];
        NSString *homePath = ticket[@"homePath"];
        NSString *bundleIdentifier = ticket[@"bundleIdentifier"];

        if (bundlePath && homePath) {
            // A filesystem ticket can be synchronously unlinked before the
            // guest takes over NSUserDefaults/NSBundle, making launch truly
            // one-shot even when the guest terminates abnormally.
            [NSFileManager.defaultManager removeItemAtPath:ticketPath error:nil];
            [defaults removeObjectForKey:@"guest.launch.bundlePath"];
            [defaults removeObjectForKey:@"guest.launch.homePath"];
            [defaults removeObjectForKey:@"guest.launch.bundleIdentifier"];

            // Translate iOSSim's launch ticket into the keys and filesystem
            // names consumed by the unmodified LiveContainer bootstrap.
            [defaults setObject:bundlePath.lastPathComponent forKey:@"selected"];
            [defaults setObject:homePath.lastPathComponent forKey:@"selectedContainer"];
            if (bundleIdentifier) {
                [defaults setObject:bundleIdentifier forKey:@"guest.launch.lastBundle"];
            }
            [defaults removeObjectForKey:@"guest.launch.lastError"];
            [defaults removeObjectForKey:@"error"];
            [defaults synchronize];

            // LiveContainer performs the JIT/library-validation bypass, dyld
            // loadability routing, process/bundle hooks, dlopen, and guest-main
            // handoff from here.
            IOSSimInstallGuestExitControl();
            return LiveContainerMain(argc, argv);
        }

        // Clear tickets written by pre-filesystem builds; they are no longer
        // launch authority.
        [defaults removeObjectForKey:@"guest.launch.bundlePath"];
        [defaults removeObjectForKey:@"guest.launch.homePath"];
        [defaults removeObjectForKey:@"guest.launch.bundleIdentifier"];
        return IOSSimHostMain();
    }
}
