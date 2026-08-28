#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <libkern/OSByteOrder.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <os/lock.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <ptrauth.h>
#import <sys/stat.h>
#import <string.h>
#import <unistd.h>

#import "../../LiveContainer-3.8.0/LiveContainer/LCMachOUtils.h"
#import "../../LiveContainer-3.8.0/LiveContainer/LCSharedUtils.h"
#import "../../LiveContainer-3.8.0/ZSign/zsigner.h"
#import "WidgetRuntimeCaptureShim.h"
#import "WidgetGuestEnvironment.h"

static NSString *const IOSSimCertificateDataKey = @"LCCertificateData";
static NSString *const IOSSimCertificatePasswordKey = @"LCCertificatePassword";
static NSString *const IOSSimCertificateTeamIDKey = @"IOSSimCertificateTeamID";
static NSString *const IOSSimCertificateUpdateDateKey = @"LCCertificateUpdateDate";
static NSString *const IOSSimWidgetRunnerBundleIdentifier = @"com.genericcoding.vibecontainers.WidgetRunner";
static NSString *const IOSSimWidgetRunnerBundleName = @"IOSSimWidgetRunner.appex";
static NSString *const IOSSimWidgetRunnerProfileName = @"ContainerWidgetRunner";
static NSString *const IOSSimWidgetSourceIdentifierKey = @"IOSSimSourceWidgetBundleIdentifier";
static NSString *const IOSSimWidgetSourceRelativePathKey = @"IOSSimSourceWidgetRelativePath";
static NSString *const IOSSimWidgetSourceSizeKey = @"IOSSimSourceWidgetExecutableSize";
static NSString *const IOSSimWidgetSourceModificationDateKey = @"IOSSimSourceWidgetExecutableModificationDate";
static NSString *const IOSSimWidgetModuleFormatVersionKey = @"IOSSimWidgetModuleFormatVersion";
static NSInteger const IOSSimWidgetModuleFormatVersion = 2;
static NSString *const IOSSimWidgetModuleStagePrefix = @".IOSSimWidgetModule-stage-";
static NSString *const IOSSimWidgetModuleBackupPrefix = @".IOSSimWidgetModule-backup-";

@interface IOSSimLoadedWidgetModuleRecord : NSObject
@property(nonatomic, assign) void *handle;
@property(nonatomic, copy) NSString *executablePath;
@property(nonatomic, copy) NSString *sourceIdentifier;
@end

@implementation IOSSimLoadedWidgetModuleRecord
@end

static os_unfair_lock IOSSimLoadedWidgetModuleLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, IOSSimLoadedWidgetModuleRecord *>
    *IOSSimLoadedWidgetModulesByExecutablePath;

static void IOSSimInitializeLoadedWidgetModuleRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        IOSSimLoadedWidgetModulesByExecutablePath = [NSMutableDictionary dictionary];
    });
}

enum {
    IOSSimCSMagicCodeDirectory = 0xfade0c02,
    IOSSimCSMagicEmbeddedSignature = 0xfade0cc0,
    IOSSimCSMagicEmbeddedEntitlements = 0xfade7171,
    IOSSimCSMagicBlobWrapper = 0xfade0b01,
    IOSSimCSSlotCodeDirectory = 0,
    IOSSimCSSlotInfo = 1,
    IOSSimCSSlotResourceDirectory = 3,
    IOSSimCSSlotEntitlements = 5,
    IOSSimCSSlotAlternateCodeDirectories = 0x1000,
    IOSSimCSSlotAlternateCodeDirectoryLimit = 0x1005,
    IOSSimCSSlotSignature = 0x10000,
    IOSSimCSHashTypeSHA1 = 1,
    IOSSimCSHashTypeSHA256 = 2,
    IOSSimCSHashTypeSHA256Truncated = 3,
    IOSSimCSHashTypeSHA384 = 4,
    IOSSimCSSupportsTeamID = 0x20200,
    IOSSimCSSupportsCodeLimit64 = 0x20300,
    IOSSimCSSupportsExecSegment = 0x20400,
    IOSSimCSExecSegmentMainBinary = 0x1
};

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
} IOSSimCSSuperBlob;

typedef struct __attribute__((packed)) {
    uint32_t type;
    uint32_t offset;
} IOSSimCSBlobIndex;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t length;
} IOSSimCSGenericBlob;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t length;
    uint32_t version;
    uint32_t flags;
    uint32_t hashOffset;
    uint32_t identOffset;
    uint32_t nSpecialSlots;
    uint32_t nCodeSlots;
    uint32_t codeLimit;
    uint8_t hashSize;
    uint8_t hashType;
    uint8_t platform;
    uint8_t pageSize;
    uint32_t spare2;
    uint32_t scatterOffset;
    uint32_t teamOffset;
    uint32_t spare3;
    uint64_t codeLimit64;
    uint64_t execSegBase;
    uint64_t execSegLimit;
    uint64_t execSegFlags;
} IOSSimCSCodeDirectory;

static NSObject *IOSSimWidgetRunnerLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSObject *IOSSimWidgetModuleStageLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static char *IOSSimSignerError(NSString *message) {
    return strdup((message ?: @"An unknown signing error occurred.").UTF8String);
}

static NSError *IOSSimSigningError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"iOSSim.JITLessSigner"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL IOSSimIsMachOAtPath(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    NSData *header = [handle readDataOfLength:sizeof(uint32_t)];
    [handle closeFile];
    if (header.length != sizeof(uint32_t)) return NO;

    uint32_t magic = 0;
    [header getBytes:&magic length:sizeof(magic)];
    return magic == MH_MAGIC_64 || magic == MH_CIGAM_64
        || magic == FAT_MAGIC || magic == FAT_CIGAM
        || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64;
}

static NSError *IOSSimMakeExecutable(NSString *path, NSString *label) {
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory]
        || directory) {
        return IOSSimSigningError(10, [NSString stringWithFormat:
            @"%@ is missing at %@.", label, path.lastPathComponent]);
    }
    if (chmod(path.fileSystemRepresentation, 0755) != 0) {
        return IOSSimSigningError(11, [NSString stringWithFormat:
            @"Could not restore execute permission on %@: %s", label, strerror(errno)]);
    }
    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) != 0) {
        return IOSSimSigningError(12, [NSString stringWithFormat:
            @"Could not inspect %@ after chmod 0755: %s", label, strerror(errno)]);
    }
    if (!S_ISREG(status.st_mode) || (status.st_mode & 0111) == 0) {
        return IOSSimSigningError(13, [NSString stringWithFormat:
            @"%@ has mode %04o after chmod, not an executable-file mode.",
            label, status.st_mode & 07777]);
    }
    return nil;
}

static NSArray<NSString *> *IOSSimMachOPathsUnderRoot(NSString *root) {
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:rootURL
                          includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                        errorHandler:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSNumber *regular = nil;
        if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil]
            || !regular.boolValue) continue;
        if (IOSSimIsMachOAtPath(url.path)) [paths addObject:url.path];
    }
    return paths;
}

/// ZIPs made by Windows tools commonly omit Unix modes. Restore every bundle
/// executable and every Mach-O, rather than trusting central-directory mode
/// bits that may not exist. ZSign replaces files while writing signatures, so
/// this is also run after signing.
static NSError *IOSSimRepairExecutableModes(NSString *appRoot) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *bundles = [NSMutableArray arrayWithObject:
        [NSURL fileURLWithPath:appRoot isDirectory:YES]];
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [manager enumeratorAtURL:bundles.firstObject
      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                    errorHandler:nil];
    NSSet<NSString *> *bundleExtensions = [NSSet setWithArray:
        @[@"app", @"appex", @"framework", @"xpc"]];
    for (NSURL *url in enumerator) {
        NSNumber *directory = nil;
        if ([url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil]
            && directory.boolValue
            && [bundleExtensions containsObject:url.pathExtension.lowercaseString]) {
            [bundles addObject:url];
        }
    }

    for (NSURL *bundleURL in bundles) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
            [bundleURL URLByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = info[@"CFBundleExecutable"];
        if (!executable.length) continue;
        NSString *path = [bundleURL URLByAppendingPathComponent:executable].path;
        NSError *error = IOSSimMakeExecutable(path, [NSString stringWithFormat:
            @"%@ CFBundleExecutable", bundleURL.lastPathComponent]);
        if (error) return error;
    }

    for (NSString *path in IOSSimMachOPathsUnderRoot(appRoot)) {
        NSError *error = IOSSimMakeExecutable(path, [NSString stringWithFormat:
            @"nested Mach-O %@", path.lastPathComponent]);
        if (error) return error;
    }
    return nil;
}

static NSError *IOSSimValidateWidgetBundle(NSString *appRoot,
                                           NSString *extensionPath) {
    NSString *root = appRoot.stringByStandardizingPath;
    NSString *appex = extensionPath.stringByStandardizingPath;
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    if (![appex hasPrefix:rootPrefix]) {
        return IOSSimSigningError(20,
            @"The widget extension path is outside its installed app bundle.");
    }

    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:appex isDirectory:&directory]
        || !directory) {
        return IOSSimSigningError(21,
            @"The widget .appex directory is missing from the installed container.");
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [appex stringByAppendingPathComponent:@"Info.plist"]];
    if (!info) {
        return IOSSimSigningError(22, @"The widget .appex has no readable Info.plist.");
    }
    NSString *extensionPoint = info[@"NSExtension"][@"NSExtensionPointIdentifier"];
    if (![extensionPoint isEqualToString:@"com.apple.widgetkit-extension"]) {
        return IOSSimSigningError(23, [NSString stringWithFormat:
            @"The selected .appex has extension point '%@', not com.apple.widgetkit-extension.",
            extensionPoint ?: @"missing"]);
    }
    NSString *executable = info[@"CFBundleExecutable"];
    if (!executable.length) {
        return IOSSimSigningError(24,
            @"The widget Info.plist is missing CFBundleExecutable.");
    }
    NSString *executablePath = [appex stringByAppendingPathComponent:executable];
    BOOL executableDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:executablePath
                                            isDirectory:&executableDirectory]
        || executableDirectory) {
        return IOSSimSigningError(25, [NSString stringWithFormat:
            @"The widget Info.plist names '%@', but that binary is missing from the .appex.",
            executable]);
    }
    if (!IOSSimIsMachOAtPath(executablePath)) {
        return IOSSimSigningError(26, [NSString stringWithFormat:
            @"The widget binary '%@' exists, but it is not a supported Mach-O.", executable]);
    }
    struct stat status = {0};
    if (stat(executablePath.fileSystemRepresentation, &status) != 0 || !S_ISREG(status.st_mode)) {
        return IOSSimSigningError(27, [NSString stringWithFormat:
            @"The widget binary '%@' cannot be inspected as a regular file: %s",
            executable, strerror(errno)]);
    }
    return nil;
}

static NSURL *IOSSimWidgetRunnerURL(NSString *appRoot) {
    return [[NSURL fileURLWithPath:appRoot isDirectory:YES]
        URLByAppendingPathComponent:[@"PlugIns" stringByAppendingPathComponent:
            IOSSimWidgetRunnerBundleName]
                    isDirectory:YES];
}

static NSDictionary *IOSSimWidgetInfo(NSString *extensionPath) {
    return [NSDictionary dictionaryWithContentsOfFile:
        [extensionPath stringByAppendingPathComponent:@"Info.plist"]];
}

static NSString *IOSSimRelativePath(NSString *path, NSString *root) {
    NSString *standardPath = path.stringByStandardizingPath;
    NSString *standardRoot = root.stringByStandardizingPath;
    NSString *prefix = [standardRoot stringByAppendingString:@"/"];
    return [standardPath hasPrefix:prefix]
        ? [standardPath substringFromIndex:prefix.length]
        : nil;
}

static NSString *IOSSimCanonicalPath(NSString *path) {
    return path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
}

static BOOL IOSSimPathsReferToSameFile(NSString *first, NSString *second) {
    if (!first.length || !second.length) return NO;
    if ([IOSSimCanonicalPath(first) isEqualToString:IOSSimCanonicalPath(second)]) {
        return YES;
    }
    struct stat firstStatus = {0};
    struct stat secondStatus = {0};
    return stat(first.fileSystemRepresentation, &firstStatus) == 0
        && stat(second.fileSystemRepresentation, &secondStatus) == 0
        && firstStatus.st_dev == secondStatus.st_dev
        && firstStatus.st_ino == secondStatus.st_ino;
}

static NSDictionary *IOSSimWidgetSourceMetadata(NSString *appRoot,
                                                NSString *extensionPath,
                                                NSError **error) {
    NSDictionary *info = IOSSimWidgetInfo(extensionPath);
    NSString *identifier = info[@"CFBundleIdentifier"];
    NSString *executable = info[@"CFBundleExecutable"];
    NSString *relativePath = IOSSimRelativePath(extensionPath, appRoot);
    NSString *executablePath = [extensionPath stringByAppendingPathComponent:executable ?: @""];
    NSError *attributesError = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:executablePath error:&attributesError];
    NSNumber *size = attributes[NSFileSize];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    if (!identifier.length || !relativePath.length || !size || !modificationDate) {
        if (error) {
            *error = IOSSimSigningError(28, [NSString stringWithFormat:
                @"Could not fingerprint the source widget extension: %@",
                attributesError.localizedDescription ?: @"required metadata is missing"]);
        }
        return nil;
    }
    return @{
        IOSSimWidgetSourceIdentifierKey: identifier,
        IOSSimWidgetSourceRelativePathKey: relativePath,
        IOSSimWidgetSourceSizeKey: size,
        IOSSimWidgetSourceModificationDateKey: modificationDate,
        IOSSimWidgetModuleFormatVersionKey: @(IOSSimWidgetModuleFormatVersion)
    };
}

static NSString *IOSSimWidgetModuleFingerprint(NSDictionary *metadata) {
    NSDate *modificationDate = metadata[IOSSimWidgetSourceModificationDateKey];
    NSString *material = [NSString stringWithFormat:@"%@\n%@\n%@\n%.9f\n%@",
        metadata[IOSSimWidgetSourceIdentifierKey] ?: @"",
        metadata[IOSSimWidgetSourceRelativePathKey] ?: @"",
        metadata[IOSSimWidgetSourceSizeKey] ?: @0,
        modificationDate.timeIntervalSinceReferenceDate,
        metadata[IOSSimWidgetModuleFormatVersionKey] ?: @0];
    NSData *data = [material dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:48];
    for (NSUInteger index = 0; index < 24; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static NSURL *IOSSimWidgetModuleURL(NSString *sourceExtensionPath,
                                    NSDictionary *sourceMetadata) {
    NSString *name = [NSString stringWithFormat:@".IOSSimWidgetModule-%@.appex",
        IOSSimWidgetModuleFingerprint(sourceMetadata)];
    return [[NSURL fileURLWithPath:sourceExtensionPath isDirectory:YES]
        .URLByDeletingLastPathComponent URLByAppendingPathComponent:name isDirectory:YES];
}

static BOOL IOSSimWidgetModuleMatchesSource(NSString *appRoot,
                                            NSString *sourceExtensionPath,
                                            NSURL *moduleURL,
                                            NSError **error) {
    NSError *metadataError = nil;
    NSDictionary *source = IOSSimWidgetSourceMetadata(appRoot, sourceExtensionPath,
                                                       &metadataError);
    if (!source) {
        if (error) *error = metadataError;
        return NO;
    }
    NSDictionary *moduleInfo = [NSDictionary dictionaryWithContentsOfURL:
        [moduleURL URLByAppendingPathComponent:@"Info.plist"]];
    if (!moduleInfo) {
        if (error) *error = IOSSimSigningError(80,
            @"The staged widget module has no readable Info.plist.");
        return NO;
    }
    for (NSString *key in @[ IOSSimWidgetSourceIdentifierKey,
                             IOSSimWidgetSourceRelativePathKey,
                             IOSSimWidgetSourceSizeKey,
                             IOSSimWidgetSourceModificationDateKey,
                             IOSSimWidgetModuleFormatVersionKey ]) {
        if (![moduleInfo[key] isEqual:source[key]]) {
            if (error) *error = IOSSimSigningError(81, [NSString stringWithFormat:
                @"The staged widget module is stale (source %@ changed).", key]);
            return NO;
        }
    }
    return YES;
}

static BOOL IOSSimRunnerMatchesSource(NSString *appRoot,
                                      NSString *sourceExtensionPath,
                                      NSURL *runnerURL,
                                      NSError **error) {
    NSError *metadataError = nil;
    NSDictionary *source = IOSSimWidgetSourceMetadata(appRoot, sourceExtensionPath,
                                                       &metadataError);
    if (!source) {
        if (error) *error = metadataError;
        return NO;
    }
    NSDictionary *runnerInfo = [NSDictionary dictionaryWithContentsOfURL:
        [runnerURL URLByAppendingPathComponent:@"Info.plist"]];
    if (!runnerInfo) {
        if (error) *error = IOSSimSigningError(29,
            @"The provisioned widget runner has no readable Info.plist.");
        return NO;
    }
    if (![runnerInfo[@"CFBundleIdentifier"] isEqualToString:
            IOSSimWidgetRunnerBundleIdentifier]) {
        if (error) *error = IOSSimSigningError(30,
            @"The staged widget runner has the wrong provisioned bundle identifier.");
        return NO;
    }
    for (NSString *key in @[ IOSSimWidgetSourceIdentifierKey,
                             IOSSimWidgetSourceRelativePathKey,
                             IOSSimWidgetSourceSizeKey,
                             IOSSimWidgetSourceModificationDateKey ]) {
        if (![runnerInfo[key] isEqual:source[key]]) {
            if (error) *error = IOSSimSigningError(31, [NSString stringWithFormat:
                @"The provisioned widget runner is stale (source %@ changed).", key]);
            return NO;
        }
    }
    return YES;
}

static NSDictionary *IOSSimProvisioningPayload(NSData *profileData, NSError **error) {
    NSData *xmlStartData = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *plistEndData = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange start = [profileData rangeOfData:xmlStartData
                                    options:0
                                      range:NSMakeRange(0, profileData.length)];
    if (start.location == NSNotFound) {
        if (error) *error = IOSSimSigningError(40,
            @"The bundled widget-runner provisioning profile has no plist payload.");
        return nil;
    }
    NSRange remaining = NSMakeRange(start.location, profileData.length - start.location);
    NSRange end = [profileData rangeOfData:plistEndData options:0 range:remaining];
    if (end.location == NSNotFound) {
        if (error) *error = IOSSimSigningError(41,
            @"The bundled widget-runner provisioning profile has a truncated plist payload.");
        return nil;
    }
    NSRange plistRange = NSMakeRange(start.location, NSMaxRange(end) - start.location);
    NSData *plistData = [profileData subdataWithRange:plistRange];
    NSError *plistError = nil;
    id payload = [NSPropertyListSerialization propertyListWithData:plistData
                                                           options:NSPropertyListImmutable
                                                            format:nil
                                                             error:&plistError];
    if (![payload isKindOfClass:NSDictionary.class]) {
        if (error) *error = IOSSimSigningError(42, [NSString stringWithFormat:
            @"The widget-runner provisioning profile cannot be decoded: %@",
            plistError.localizedDescription ?: @"invalid property list"]);
        return nil;
    }
    return payload;
}

static NSData *IOSSimWidgetRunnerProfile(NSError **error) {
    NSURL *profileURL = [NSBundle.mainBundle URLForResource:IOSSimWidgetRunnerProfileName
                                             withExtension:@"mobileprovision"];
    if (!profileURL) {
        if (error) *error = IOSSimSigningError(43,
            @"This VibeContainers build does not contain its widget-runner provisioning profile. Rebuild and reinstall the signed app.");
        return nil;
    }
    NSError *readError = nil;
    NSData *profileData = [NSData dataWithContentsOfURL:profileURL
                                               options:NSDataReadingMappedIfSafe
                                                 error:&readError];
    if (!profileData.length) {
        if (error) *error = IOSSimSigningError(44, [NSString stringWithFormat:
            @"The widget-runner provisioning profile could not be read: %@",
            readError.localizedDescription ?: @"empty profile"]);
        return nil;
    }
    NSError *payloadError = nil;
    NSDictionary *payload = IOSSimProvisioningPayload(profileData, &payloadError);
    if (!payload) {
        if (error) *error = payloadError;
        return nil;
    }
    NSArray *teams = payload[@"TeamIdentifier"];
    NSDictionary *entitlements = payload[@"Entitlements"];
    NSString *applicationIdentifier = entitlements[@"application-identifier"];
    NSString *storedTeam = [NSUserDefaults.standardUserDefaults
        stringForKey:IOSSimCertificateTeamIDKey];
    NSString *expectedApplicationIdentifier = storedTeam.length
        ? [NSString stringWithFormat:@"%@.%@", storedTeam,
                                     IOSSimWidgetRunnerBundleIdentifier]
        : nil;
    if (!storedTeam.length || ![teams containsObject:storedTeam]) {
        if (error) *error = IOSSimSigningError(45, [NSString stringWithFormat:
            @"The widget-runner profile belongs to team %@, not the imported signing team %@.",
            [teams componentsJoinedByString:@", "] ?: @"unknown", storedTeam ?: @"unknown"]);
        return nil;
    }
    if (![applicationIdentifier isEqualToString:expectedApplicationIdentifier]) {
        if (error) *error = IOSSimSigningError(46, [NSString stringWithFormat:
            @"The widget-runner profile authorizes '%@', not '%@'.",
            applicationIdentifier ?: @"missing", expectedApplicationIdentifier]);
        return nil;
    }
    NSDate *expirationDate = payload[@"ExpirationDate"];
    if (![expirationDate isKindOfClass:NSDate.class] || expirationDate.timeIntervalSinceNow <= 0) {
        if (error) *error = IOSSimSigningError(47,
            @"The bundled widget-runner provisioning profile has expired. Rebuild and reinstall VibeContainers to refresh it.");
        return nil;
    }
    return profileData;
}

static NSData *IOSSimDigest(NSData *data, BOOL sha256) {
    if (sha256) {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        return [NSData dataWithBytes:digest length:sizeof(digest)];
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH] = {0};
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSData *IOSSimCreateCodeResources(NSURL *bundleURL,
                                         NSString *executableName,
                                         NSError **error) {
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSMutableDictionary *files2 = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:bundleURL
 includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:nil];
    NSString *root = bundleURL.path.stringByStandardizingPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    for (NSURL *fileURL in enumerator) {
        NSNumber *regular = nil;
        if (![fileURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil]
            || !regular.boolValue) continue;
        NSString *path = fileURL.path.stringByStandardizingPath;
        if (![path hasPrefix:prefix]) continue;
        NSString *relative = [path substringFromIndex:prefix.length];
        if ([relative isEqualToString:executableName]
            || [relative hasPrefix:@"_CodeSignature/"]) continue;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe
                                               error:&readError];
        if (!data) {
            if (error) *error = IOSSimSigningError(48, [NSString stringWithFormat:
                @"Could not seal widget resource '%@': %@", relative,
                readError.localizedDescription ?: @"read failed"]);
            return nil;
        }
        files[relative] = IOSSimDigest(data, NO);
        if (![relative isEqualToString:@"Info.plist"]) {
            files2[relative] = @{ @"hash2": IOSSimDigest(data, YES) };
        }
    }
    NSDictionary *rules = @{
        @"^.*": @YES,
        @"^.*\\.lproj/": @{ @"optional": @YES, @"weight": @1000 },
        @"^.*\\.lproj/locversion\\.plist$": @{ @"omit": @YES, @"weight": @1100 },
        @"^Base\\.lproj/": @{ @"weight": @1010 },
        @"^version\\.plist$": @YES
    };
    NSDictionary *rules2 = @{
        @".*\\.dSYM($|/)": @{ @"weight": @11 },
        @"^.*": @YES,
        @"^.*\\.lproj/": @{ @"optional": @YES, @"weight": @1000 },
        @"^.*\\.lproj/locversion\\.plist$": @{ @"omit": @YES, @"weight": @1100 },
        @"^(.*/)?\\.DS_Store$": @{ @"omit": @YES, @"weight": @2000 },
        @"^Base\\.lproj/": @{ @"weight": @1010 },
        @"^embedded\\.provisionprofile$": @{ @"weight": @20 },
        @"^Info\\.plist$": @{ @"omit": @YES, @"weight": @20 },
        @"^PkgInfo$": @{ @"omit": @YES, @"weight": @20 },
        @"^version\\.plist$": @{ @"weight": @20 }
    };
    NSDictionary *seal = @{ @"files": files, @"files2": files2,
                             @"rules": rules, @"rules2": rules2 };
    NSError *serializationError = nil;
    NSData *result = [NSPropertyListSerialization dataWithPropertyList:seal
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                options:0
                                                                  error:&serializationError];
    if (!result && error) {
        *error = IOSSimSigningError(49, [NSString stringWithFormat:
            @"Could not serialize the widget resource seal: %@",
            serializationError.localizedDescription ?: @"unknown error"]);
    }
    return result;
}

static NSError *IOSSimAttachKernelSignature(NSString *path) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    __block BOOL checked = NO;
    __block BOOL accepted = NO;
    __block int failureErrno = 0;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (checked || header->cputype != CPU_TYPE_ARM64) return;
            checked = YES;
            struct load_command *command = (struct load_command *)((uint8_t *)header
                + sizeof(struct mach_header_64));
            struct linkedit_data_command *signature = NULL;
            for (uint32_t index = 0; index < header->ncmds; index++) {
                if (command->cmd == LC_CODE_SIGNATURE
                    && command->cmdsize >= sizeof(struct linkedit_data_command)) {
                    signature = (struct linkedit_data_command *)command;
                    break;
                }
                if (command->cmdsize < sizeof(struct load_command)) break;
                command = (struct load_command *)((uint8_t *)command + command->cmdsize);
            }
            if (!signature) return;
            fsignatures_t signatureInfo = {0};
            signatureInfo.fs_file_start = (off_t)((uint8_t *)header - (uint8_t *)fileBase);
            signatureInfo.fs_blob_start = (void *)(uintptr_t)signature->dataoff;
            signatureInfo.fs_blob_size = signature->datasize;
            errno = 0;
            accepted = fcntl(fd, F_ADDFILESIGS_RETURN, &signatureInfo) == 0;
            failureErrno = accepted ? 0 : errno;
        });
    if (accepted) return nil;
    NSString *detail = parseError.length ? parseError
        : (checked
            ? [NSString stringWithFormat:@"F_ADDFILESIGS_RETURN failed: %s (%d)",
                                         strerror(failureErrno), failureErrno]
            : @"no arm64 code-signature command was found");
    return IOSSimSigningError(50, [NSString stringWithFormat:
        @"The kernel rejected the staged signature on '%@': %@.",
        path.lastPathComponent, detail]);
#endif
}

static BOOL IOSSimSignatureRangeFits(uint64_t offset,
                                     uint64_t length,
                                     uint64_t containerLength) {
    return offset <= containerLength && length <= containerLength - offset;
}

static BOOL IOSSimSignatureDigest(const void *bytes,
                                  size_t length,
                                  uint8_t hashType,
                                  uint8_t hashSize,
                                  uint8_t digest[CC_SHA512_DIGEST_LENGTH]) {
    if (length > UINT32_MAX) return NO;
    switch (hashType) {
        case IOSSimCSHashTypeSHA1:
            if (hashSize != CC_SHA1_DIGEST_LENGTH) return NO;
            CC_SHA1(bytes, (CC_LONG)length, digest);
            return YES;
        case IOSSimCSHashTypeSHA256:
            if (hashSize != CC_SHA256_DIGEST_LENGTH) return NO;
            CC_SHA256(bytes, (CC_LONG)length, digest);
            return YES;
        case IOSSimCSHashTypeSHA256Truncated:
            if (hashSize != 20) return NO;
            CC_SHA256(bytes, (CC_LONG)length, digest);
            return YES;
        case IOSSimCSHashTypeSHA384:
            if (hashSize != CC_SHA384_DIGEST_LENGTH) return NO;
            CC_SHA384(bytes, (CC_LONG)length, digest);
            return YES;
        default:
            return NO;
    }
}

static NSString *IOSSimSignatureString(const uint8_t *blob,
                                       uint32_t blobLength,
                                       uint32_t offset) {
    if (offset == 0 || offset >= blobLength) return nil;
    const char *value = (const char *)blob + offset;
    size_t available = blobLength - offset;
    const char *terminator = memchr(value, '\0', available);
    if (!terminator) return nil;
    return [[NSString alloc] initWithBytes:value
                                    length:(NSUInteger)(terminator - value)
                                  encoding:NSUTF8StringEncoding];
}

static NSString *IOSSimValidateSpecialSlot(const uint8_t *codeDirectoryBytes,
                                           uint32_t codeDirectoryLength,
                                           uint32_t hashOffset,
                                           uint32_t specialSlotCount,
                                           uint8_t hashType,
                                           uint8_t hashSize,
                                           uint32_t slot,
                                           const void *content,
                                           size_t contentLength,
                                           NSString *label) {
    if (specialSlotCount < slot) {
        return [NSString stringWithFormat:
            @"the CodeDirectory does not bind its %@ (special slot %u is absent)",
            label, slot];
    }
    uint64_t distance = (uint64_t)slot * hashSize;
    if (distance > hashOffset
        || !IOSSimSignatureRangeFits(hashOffset - distance,
                                     hashSize,
                                     codeDirectoryLength)) {
        return [NSString stringWithFormat:
            @"the %@ special-slot hash is outside the CodeDirectory", label];
    }
    uint8_t digest[CC_SHA512_DIGEST_LENGTH] = {0};
    if (!IOSSimSignatureDigest(content, contentLength, hashType, hashSize, digest)) {
        return [NSString stringWithFormat:
            @"the CodeDirectory uses unsupported hash type %u/size %u for %@",
            hashType, hashSize, label];
    }
    const uint8_t *recordedHash = codeDirectoryBytes + hashOffset - distance;
    if (memcmp(recordedHash, digest, hashSize) != 0) {
        return [NSString stringWithFormat:
            @"the CodeDirectory %@ special-slot hash does not match the staged file",
            label];
    }
    return nil;
}

static NSString *IOSSimValidateCodeDirectory(const uint8_t *codeDirectoryBytes,
                                             uint32_t codeDirectoryLength,
                                             const uint8_t *sliceBytes,
                                             uint64_t sliceLength,
                                             uint32_t signatureDataOffset,
                                             NSData *infoData,
                                             NSData *codeResources,
                                             const uint8_t *entitlementsBlob,
                                             uint32_t entitlementsBlobLength,
                                             NSString *expectedIdentifier,
                                             NSString *expectedTeam,
                                             uint64_t *execSegmentFlagsResult,
                                             NSString **summaryResult) {
    if (codeDirectoryLength < sizeof(IOSSimCSCodeDirectory)) {
        return @"a CodeDirectory is truncated before its executable-segment fields";
    }
    const IOSSimCSCodeDirectory *codeDirectory =
        (const IOSSimCSCodeDirectory *)codeDirectoryBytes;
    if (OSSwapBigToHostInt32(codeDirectory->magic) != IOSSimCSMagicCodeDirectory) {
        return @"a CodeDirectory index does not point to a CodeDirectory blob";
    }
    uint32_t version = OSSwapBigToHostInt32(codeDirectory->version);
    if (version < IOSSimCSSupportsExecSegment) {
        return [NSString stringWithFormat:
            @"CodeDirectory version 0x%x has no executable-segment classification", version];
    }
    NSString *identifier = IOSSimSignatureString(codeDirectoryBytes,
        codeDirectoryLength, OSSwapBigToHostInt32(codeDirectory->identOffset));
    if (![identifier isEqualToString:expectedIdentifier]) {
        return [NSString stringWithFormat:
            @"CodeDirectory identifier '%@' does not match runner identifier '%@'",
            identifier ?: @"invalid", expectedIdentifier];
    }
    if (version < IOSSimCSSupportsTeamID) {
        return @"the provisioned CodeDirectory has no team-identifier field";
    }
    NSString *team = IOSSimSignatureString(codeDirectoryBytes,
        codeDirectoryLength, OSSwapBigToHostInt32(codeDirectory->teamOffset));
    if (![team isEqualToString:expectedTeam]) {
        return [NSString stringWithFormat:
            @"CodeDirectory team '%@' does not match imported team '%@'",
            team ?: @"invalid", expectedTeam];
    }

    uint32_t hashOffset = OSSwapBigToHostInt32(codeDirectory->hashOffset);
    uint32_t specialSlotCount = OSSwapBigToHostInt32(codeDirectory->nSpecialSlots);
    uint32_t codeSlotCount = OSSwapBigToHostInt32(codeDirectory->nCodeSlots);
    uint8_t hashSize = codeDirectory->hashSize;
    uint8_t hashType = codeDirectory->hashType;
    uint64_t specialHashBytes = (uint64_t)specialSlotCount * hashSize;
    uint64_t codeHashBytes = (uint64_t)codeSlotCount * hashSize;
    if (hashSize == 0 || specialHashBytes > hashOffset
        || !IOSSimSignatureRangeFits(hashOffset, codeHashBytes,
                                     codeDirectoryLength)) {
        return @"the CodeDirectory hash table is outside its blob";
    }

    uint64_t codeLimit = OSSwapBigToHostInt32(codeDirectory->codeLimit);
    if (version >= IOSSimCSSupportsCodeLimit64 && codeLimit == UINT32_MAX) {
        codeLimit = OSSwapBigToHostInt64(codeDirectory->codeLimit64);
    }
    if (codeLimit != signatureDataOffset || codeLimit > sliceLength) {
        return [NSString stringWithFormat:
            @"CodeDirectory code limit %llu does not match LC_CODE_SIGNATURE offset %u",
            codeLimit, signatureDataOffset];
    }
    uint8_t pageSizeLog2 = codeDirectory->pageSize;
    if (pageSizeLog2 > 31) return @"the CodeDirectory has an invalid page size";
    uint64_t pageSize = pageSizeLog2 == 0 ? MAX(codeLimit, 1) : 1ULL << pageSizeLog2;
    uint64_t expectedCodeSlots = codeLimit == 0 ? 0 : (codeLimit + pageSize - 1) / pageSize;
    if (expectedCodeSlots != codeSlotCount) {
        return [NSString stringWithFormat:
            @"CodeDirectory has %u code slots, expected %llu for its code limit",
            codeSlotCount, expectedCodeSlots];
    }
    for (uint32_t slot = 0; slot < codeSlotCount; slot++) {
        uint64_t pageOffset = (uint64_t)slot * pageSize;
        size_t pageLength = (size_t)MIN(pageSize, codeLimit - pageOffset);
        uint8_t digest[CC_SHA512_DIGEST_LENGTH] = {0};
        if (!IOSSimSignatureDigest(sliceBytes + pageOffset, pageLength,
                                   hashType, hashSize, digest)) {
            return [NSString stringWithFormat:
                @"the CodeDirectory uses unsupported hash type %u/size %u",
                hashType, hashSize];
        }
        const uint8_t *recordedHash = codeDirectoryBytes + hashOffset
            + (uint64_t)slot * hashSize;
        if (memcmp(recordedHash, digest, hashSize) != 0) {
            return [NSString stringWithFormat:
                @"CodeDirectory code-slot %u does not match the staged executable", slot];
        }
    }

    NSString *slotError = IOSSimValidateSpecialSlot(codeDirectoryBytes,
        codeDirectoryLength, hashOffset, specialSlotCount, hashType, hashSize,
        IOSSimCSSlotInfo, infoData.bytes, infoData.length, @"Info.plist");
    if (slotError) return slotError;
    slotError = IOSSimValidateSpecialSlot(codeDirectoryBytes,
        codeDirectoryLength, hashOffset, specialSlotCount, hashType, hashSize,
        IOSSimCSSlotResourceDirectory, codeResources.bytes, codeResources.length,
        @"CodeResources");
    if (slotError) return slotError;
    slotError = IOSSimValidateSpecialSlot(codeDirectoryBytes,
        codeDirectoryLength, hashOffset, specialSlotCount, hashType, hashSize,
        IOSSimCSSlotEntitlements, entitlementsBlob, entitlementsBlobLength,
        @"entitlements");
    if (slotError) return slotError;

    uint64_t execSegmentFlags = OSSwapBigToHostInt64(codeDirectory->execSegFlags);
    if (execSegmentFlagsResult) *execSegmentFlagsResult |= execSegmentFlags;
    if (summaryResult) {
        *summaryResult = [NSString stringWithFormat:
            @"id=%@ team=%@ version=0x%x flags=0x%x execSegFlags=0x%llx hash=%u/%u slots=%u+%u",
            identifier, team, version, OSSwapBigToHostInt32(codeDirectory->flags),
            execSegmentFlags, hashType, hashSize, specialSlotCount, codeSlotCount];
    }
    return nil;
}

static NSString *IOSSimValidateProvisionedMainSlice(struct mach_header_64 *header,
                                                    void *fileBase,
                                                    uint64_t fileLength,
                                                    NSData *infoData,
                                                    NSData *codeResources,
                                                    NSString *expectedIdentifier,
                                                    NSString *expectedTeam) {
    uint64_t sliceOffset = (uint8_t *)header - (uint8_t *)fileBase;
    if (!IOSSimSignatureRangeFits(sliceOffset, sizeof(*header), fileLength)) {
        return @"the arm64 Mach-O header is outside the file";
    }
    if (header->filetype != MH_EXECUTE) {
        return [NSString stringWithFormat:
            @"the staged runner main has Mach-O filetype %u, not MH_EXECUTE", header->filetype];
    }
    uint64_t commandsOffset = sliceOffset + sizeof(*header);
    if (!IOSSimSignatureRangeFits(commandsOffset, header->sizeofcmds, fileLength)) {
        return @"the Mach-O load-command table is outside the file";
    }
    const uint8_t *commandsEnd = (const uint8_t *)header + sizeof(*header)
        + header->sizeofcmds;
    const struct load_command *command = (const struct load_command *)
        ((const uint8_t *)header + sizeof(*header));
    const struct linkedit_data_command *signature = nil;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((const uint8_t *)command + sizeof(*command) > commandsEnd
            || command->cmdsize < sizeof(*command)
            || (const uint8_t *)command + command->cmdsize > commandsEnd) {
            return @"the Mach-O contains a malformed load command";
        }
        if (command->cmd == LC_CODE_SIGNATURE) {
            if (command->cmdsize < sizeof(struct linkedit_data_command)) {
                return @"LC_CODE_SIGNATURE is truncated";
            }
            signature = (const struct linkedit_data_command *)command;
        }
        command = (const struct load_command *)((const uint8_t *)command
                                                 + command->cmdsize);
    }
    if (!signature || signature->datasize < sizeof(IOSSimCSSuperBlob)) {
        return @"the provisioned main has no usable LC_CODE_SIGNATURE";
    }
    uint64_t signatureOffset = sliceOffset + signature->dataoff;
    if (!IOSSimSignatureRangeFits(signatureOffset, signature->datasize, fileLength)) {
        return @"LC_CODE_SIGNATURE points outside the staged executable";
    }
    const uint8_t *signatureBytes = (const uint8_t *)fileBase + signatureOffset;
    const IOSSimCSSuperBlob *superBlob = (const IOSSimCSSuperBlob *)signatureBytes;
    if (OSSwapBigToHostInt32(superBlob->magic) != IOSSimCSMagicEmbeddedSignature) {
        return @"the embedded-signature SuperBlob has the wrong magic";
    }
    uint32_t superBlobLength = OSSwapBigToHostInt32(superBlob->length);
    uint32_t blobCount = OSSwapBigToHostInt32(superBlob->count);
    uint64_t indexBytes = (uint64_t)blobCount * sizeof(IOSSimCSBlobIndex);
    uint64_t indexEnd = sizeof(IOSSimCSSuperBlob) + indexBytes;
    if (superBlobLength > signature->datasize
        || !IOSSimSignatureRangeFits(sizeof(IOSSimCSSuperBlob), indexBytes,
                                     superBlobLength)) {
        return @"the embedded-signature SuperBlob index is out of bounds";
    }
    const IOSSimCSBlobIndex *indices = (const IOSSimCSBlobIndex *)
        (signatureBytes + sizeof(IOSSimCSSuperBlob));
    const uint8_t *entitlementsBlob = nil;
    uint32_t entitlementsBlobLength = 0;
    BOOL foundCMS = NO;
    BOOL foundPrimaryCodeDirectory = NO;
    NSUInteger codeDirectoryCount = 0;
    for (uint32_t index = 0; index < blobCount; index++) {
        uint32_t type = OSSwapBigToHostInt32(indices[index].type);
        uint32_t offset = OSSwapBigToHostInt32(indices[index].offset);
        if (offset < indexEnd
            || !IOSSimSignatureRangeFits(offset, sizeof(IOSSimCSGenericBlob),
                                         superBlobLength)) {
            return [NSString stringWithFormat:
                @"signature index %u points outside the SuperBlob", index];
        }
        const IOSSimCSGenericBlob *blob = (const IOSSimCSGenericBlob *)
            (signatureBytes + offset);
        uint32_t length = OSSwapBigToHostInt32(blob->length);
        if (length < sizeof(IOSSimCSGenericBlob)
            || !IOSSimSignatureRangeFits(offset, length, superBlobLength)) {
            return [NSString stringWithFormat:
                @"signature blob %u has an invalid length", index];
        }
        uint32_t magic = OSSwapBigToHostInt32(blob->magic);
        if (type == IOSSimCSSlotCodeDirectory
            || (type >= IOSSimCSSlotAlternateCodeDirectories
                && type < IOSSimCSSlotAlternateCodeDirectoryLimit)) {
            if (magic != IOSSimCSMagicCodeDirectory) {
                return @"a CodeDirectory slot contains the wrong blob type";
            }
            if (type == IOSSimCSSlotCodeDirectory) {
                if (foundPrimaryCodeDirectory) {
                    return @"the primary CodeDirectory slot is duplicated";
                }
                foundPrimaryCodeDirectory = YES;
            }
            codeDirectoryCount++;
        } else if (type == IOSSimCSSlotEntitlements) {
            if (magic != IOSSimCSMagicEmbeddedEntitlements || entitlementsBlob) {
                return @"the embedded entitlements blob is invalid or duplicated";
            }
            entitlementsBlob = (const uint8_t *)blob;
            entitlementsBlobLength = length;
        } else if (type == IOSSimCSSlotSignature) {
            if (magic != IOSSimCSMagicBlobWrapper
                || length <= sizeof(IOSSimCSGenericBlob) || foundCMS) {
                return @"the CMS signature slot is empty, invalid, or duplicated";
            }
            foundCMS = YES;
        }
    }
    if (codeDirectoryCount == 0 || !foundPrimaryCodeDirectory) {
        return @"the signature has no primary CodeDirectory";
    }
    if (!entitlementsBlob || entitlementsBlobLength <= sizeof(IOSSimCSGenericBlob)) {
        return @"the provisioned main has no embedded entitlements";
    }
    if (!foundCMS) return @"the provisioned main has no CMS signature";

    NSData *entitlementsData = [NSData dataWithBytes:
        entitlementsBlob + sizeof(IOSSimCSGenericBlob)
        length:entitlementsBlobLength - sizeof(IOSSimCSGenericBlob)];
    NSError *plistError = nil;
    id entitlements = [NSPropertyListSerialization propertyListWithData:entitlementsData
                                                                 options:NSPropertyListImmutable
                                                                  format:nil
                                                                   error:&plistError];
    if (![entitlements isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:
            @"embedded entitlements are not a property list: %@",
            plistError.localizedDescription ?: @"decode failed"];
    }
    NSString *expectedApplicationIdentifier = [NSString stringWithFormat:
        @"%@.%@", expectedTeam, expectedIdentifier];
    NSString *applicationIdentifier = entitlements[@"application-identifier"];
    NSString *teamIdentifier = entitlements[@"com.apple.developer.team-identifier"];
    if (![applicationIdentifier isEqualToString:expectedApplicationIdentifier]
        || ![teamIdentifier isEqualToString:expectedTeam]) {
        return [NSString stringWithFormat:
            @"embedded entitlements identify app '%@' and team '%@', expected '%@' and '%@'",
            applicationIdentifier ?: @"missing", teamIdentifier ?: @"missing",
            expectedApplicationIdentifier, expectedTeam];
    }

    uint64_t aggregateExecSegmentFlags = 0;
    NSMutableArray<NSString *> *summaries = [NSMutableArray array];
    const uint8_t *sliceBytes = (const uint8_t *)header;
    uint64_t sliceLength = fileLength - sliceOffset;
    for (uint32_t index = 0; index < blobCount; index++) {
        uint32_t type = OSSwapBigToHostInt32(indices[index].type);
        if (type != IOSSimCSSlotCodeDirectory
            && !(type >= IOSSimCSSlotAlternateCodeDirectories
                 && type < IOSSimCSSlotAlternateCodeDirectoryLimit)) continue;
        uint32_t offset = OSSwapBigToHostInt32(indices[index].offset);
        const IOSSimCSGenericBlob *blob = (const IOSSimCSGenericBlob *)
            (signatureBytes + offset);
        uint32_t length = OSSwapBigToHostInt32(blob->length);
        NSString *summary = nil;
        NSString *directoryError = IOSSimValidateCodeDirectory(
            (const uint8_t *)blob, length, sliceBytes, sliceLength,
            signature->dataoff, infoData, codeResources,
            entitlementsBlob, entitlementsBlobLength,
            expectedIdentifier, expectedTeam, &aggregateExecSegmentFlags, &summary);
        if (directoryError) return directoryError;
        [summaries addObject:[NSString stringWithFormat:@"slot 0x%x {%@}", type, summary]];
    }
    if ((aggregateExecSegmentFlags & IOSSimCSExecSegmentMainBinary) == 0) {
        return @"the provisioned MH_EXECUTE CodeDirectories are not marked CS_EXECSEG_MAIN_BINARY";
    }
    NSLog(@"[WidgetRunner] Provisioned main signature is structurally valid: "
          @"LC_CODE_SIGNATURE=%u+%u SuperBlob=%u blobs=%u entitlements=%@ CodeDirectories=%@",
          signature->dataoff, signature->datasize, superBlobLength, blobCount,
          expectedApplicationIdentifier, summaries);
    NSLog(@"[WidgetRunner] Skipping host-side F_ADDFILESIGS_RETURN for the main executable: "
          @"XNU intentionally returns EBADEXEC (85) when CS_EXECSEG_MAIN_BINARY is attached "
          @"through the shared-library API; the exec/PlugInKit loader uses the main-binary path.");
    return nil;
}

static NSError *IOSSimValidateProvisionedMainSignature(NSString *path,
                                                       NSString *runnerPath) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSData *infoData = [NSData dataWithContentsOfFile:
        [runnerPath stringByAppendingPathComponent:@"Info.plist"]];
    NSData *codeResources = [NSData dataWithContentsOfFile:
        [runnerPath stringByAppendingPathComponent:@"_CodeSignature/CodeResources"]];
    NSString *expectedTeam = [NSUserDefaults.standardUserDefaults
        stringForKey:IOSSimCertificateTeamIDKey];
    if (!infoData.length || !codeResources.length || !expectedTeam.length) {
        return IOSSimSigningError(78,
            @"The staged provisioned main is missing Info.plist, CodeResources, or its imported team identity.");
    }
    __block BOOL checked = NO;
    __block NSString *validationFailure = nil;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (checked || header->cputype != CPU_TYPE_ARM64) return;
            checked = YES;
            struct stat status = {0};
            if (fstat(fd, &status) != 0 || status.st_size <= 0) {
                validationFailure = [NSString stringWithFormat:
                    @"the staged executable size could not be read: %s", strerror(errno)];
                return;
            }
            validationFailure = IOSSimValidateProvisionedMainSlice(header, fileBase,
                (uint64_t)status.st_size, infoData, codeResources,
                IOSSimWidgetRunnerBundleIdentifier, expectedTeam);
        });
    if (checked && !validationFailure) return nil;
    NSString *detail = validationFailure ?: parseError
        ?: @"no arm64 Mach-O slice was found";
    NSLog(@"[WidgetRunner] Provisioned main signature validation failed for %@: %@",
          path.lastPathComponent, detail);
    return IOSSimSigningError(78, [NSString stringWithFormat:
        @"The staged widget runner's provisioned main signature is invalid: %@.", detail]);
#endif
}

static NSError *IOSSimRegisterWidgetRunner(NSURL *runnerURL) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    void *coreServices = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        RTLD_NOW | RTLD_GLOBAL);
    if (!coreServices) {
        return IOSSimSigningError(51, [NSString stringWithFormat:
            @"CoreServices could not be loaded for widget registration: %s",
            dlerror() ?: "unknown error"]);
    }
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    Class proxyClass = NSClassFromString(@"LSPlugInKitProxy");
    SEL defaultWorkspace = NSSelectorFromString(@"defaultWorkspace");
    SEL registerPlugin = NSSelectorFromString(@"registerPlugin:");
    SEL proxyForIdentifier = NSSelectorFromString(@"pluginKitProxyForIdentifier:");
    if (!workspaceClass || !proxyClass
        || ![workspaceClass respondsToSelector:defaultWorkspace]
        || ![proxyClass respondsToSelector:proxyForIdentifier]) {
        return IOSSimSigningError(52,
            @"This iOS build does not expose the PlugInKit registration APIs.");
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspace);
    if (![workspace respondsToSelector:registerPlugin]) {
        return IOSSimSigningError(53,
            @"LSApplicationWorkspace does not support registerPlugin: on this iOS build.");
    }
    BOOL registered = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace,
                                                            registerPlugin,
                                                            runnerURL);
    NSURL *actualURL = nil;
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass,
                                                       proxyForIdentifier,
                                                       IOSSimWidgetRunnerBundleIdentifier);
        SEL bundleURLSelector = NSSelectorFromString(@"bundleURL");
        if ([proxy respondsToSelector:bundleURLSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURLSelector);
            if ([value isKindOfClass:NSURL.class]) actualURL = value;
        }
        NSString *expected = runnerURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
        NSString *actual = actualURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
        if ([actual isEqualToString:expected]) return nil;
        usleep(50000);
    }
    return IOSSimSigningError(54, [NSString stringWithFormat:
        @"PlugInKit registration %@, but LaunchServices resolved '%@' to %@ instead of %@.",
        registered ? @"returned YES" : @"returned NO",
        IOSSimWidgetRunnerBundleIdentifier,
        actualURL.path ?: @"no record", runnerURL.path]);
#endif
}

/// ZSign stays a separately loaded dylib, just as it does in LiveContainer.
/// Keeping it out of the initial image graph also means OpenSSL is loaded only
/// when the user configures or uses JIT-less signing.
static Class IOSSimLoadZSigner(NSError **error) {
    static Class signerClass;
    static NSString *loadFailure;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath
            stringByAppendingPathComponent:@"ZSign.dylib"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            const char *detail = dlerror();
            loadFailure = detail ? [NSString stringWithUTF8String:detail]
                                 : @"The ZSign dylib could not be loaded.";
            return;
        }
        signerClass = NSClassFromString(@"ZSigner");
        if (!signerClass) loadFailure = @"The ZSigner class is missing from ZSign.dylib.";
    });

    if (!signerClass && error) {
        *error = [NSError errorWithDomain:@"iOSSim.JITLessSigner"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: loadFailure}];
    }
    return signerClass;
}

static NSUserDefaults *IOSSimSharedSigningDefaults(void) {
    NSString *appGroupID = [LCSharedUtils appGroupID];
    if (!appGroupID.length || [appGroupID isEqualToString:@"Unknown"]) return nil;
    return [[NSUserDefaults alloc] initWithSuiteName:appGroupID];
}

static void IOSSimWriteSigningValue(id value, NSString *key) {
    NSUserDefaults *standard = NSUserDefaults.standardUserDefaults;
    if (value) [standard setObject:value forKey:key];
    else [standard removeObjectForKey:key];

    NSUserDefaults *shared = IOSSimSharedSigningDefaults();
    if (value) [shared setObject:value forKey:key];
    else [shared removeObjectForKey:key];
}

static NSError *IOSSimSignPaths(Class signerClass,
                                NSArray<NSString *> *paths,
                                NSString *bundleIdentifier,
                                NSData *certificate,
                                NSString *password) {
    if (paths.count == 0) return nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *signingError;
    __block BOOL succeeded = NO;
    [(id)signerClass signMachOPathArr:paths
                            bundleId:bundleIdentifier
                                cert:certificate
                                pass:password
                   completionHandler:^(BOOL success, NSError *error) {
        succeeded = success;
        signingError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (succeeded) return nil;
    return signingError ?: [NSError errorWithDomain:@"iOSSim.JITLessSigner"
                                                code:2
                                            userInfo:@{
        NSLocalizedDescriptionKey: @"ZSign did not sign the selected Mach-O."
    }];
}

static NSError *IOSSimSignProvisionedMain(Class signerClass,
                                          NSString *path,
                                          NSString *bundleIdentifier,
                                          NSData *certificate,
                                          NSString *password,
                                          NSData *profile,
                                          NSData *infoPlist,
                                          NSData *codeResources) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *signingError;
    __block BOOL succeeded = NO;
    [(id)signerClass signMachOPathArr:@[ path ]
                            bundleId:bundleIdentifier
                                cert:certificate
                                pass:password
                           provision:profile
                           infoPlist:infoPlist
                       codeResources:codeResources
                   completionHandler:^(BOOL success, NSError *error) {
        succeeded = success;
        signingError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (succeeded) return nil;
    return signingError ?: IOSSimSigningError(55,
        @"ZSign did not sign the provisioned widget-runner executable.");
}

static NSError *IOSSimSignTree(Class signerClass,
                               NSString *root,
                               NSString *bundleIdentifier,
                               NSData *certificate,
                               NSString *password) {
    if (!root.length || ![NSFileManager.defaultManager fileExistsAtPath:root]) return nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *signingError;
    __block BOOL succeeded = NO;
    [(id)signerClass signWithAppPath:root
                           bundleId:bundleIdentifier
                               cert:certificate
                               pass:password
                  completionHandler:^(BOOL success, NSError *error) {
        succeeded = success;
        signingError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (succeeded) return nil;
    return signingError ?: [NSError errorWithDomain:@"iOSSim.JITLessSigner"
                                                code:3
                                            userInfo:@{
        NSLocalizedDescriptionKey: @"ZSign did not sign the selected bundle."
    }];
}

static NSError *IOSSimValidateRunnerSignatures(NSString *runnerPath,
                                               NSString *mainExecutablePath) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSArray<NSString *> *machOs = IOSSimMachOPathsUnderRoot(runnerPath);
    BOOL containsMainExecutable = NO;
    for (NSString *path in machOs) {
        if (IOSSimPathsReferToSameFile(path, mainExecutablePath)) {
            containsMainExecutable = YES;
            break;
        }
    }
    if (machOs.count == 0 || !containsMainExecutable) {
        return IOSSimSigningError(56,
            @"The staged widget runner contains no main arm64 Mach-O executable.");
    }
    NSError *mainSignatureError = IOSSimValidateProvisionedMainSignature(
        mainExecutablePath, runnerPath);
    if (mainSignatureError) return mainSignatureError;
    for (NSString *path in machOs) {
        // F_ADDFILESIGS_RETURN is dyld's shared-library attachment path. XNU
        // rejects a correctly provisioned MH_EXECUTE CodeDirectory there with
        // EBADEXEC when CS_EXECSEG_MAIN_BINARY is present; PlugInKit's normal
        // exec loader validates that main through CS_BLOB_ADD_ALLOW_MAIN_BINARY.
        // Keep both kernel attachment and F_CHECK_LV for every host-signed
        // nested image, where those checks are required and meaningful.
        if (IOSSimPathsReferToSameFile(path, mainExecutablePath)) continue;
        NSError *kernelError = IOSSimAttachKernelSignature(path);
        if (kernelError) return kernelError;
        if (!checkCodeSignature(path.fileSystemRepresentation)) {
            NSString *relative = IOSSimRelativePath(path, runnerPath) ?: path.lastPathComponent;
            return IOSSimSigningError(57, [NSString stringWithFormat:
                @"The kernel attached the signature on nested Mach-O '%@', but current-process library validation rejected it. Reimport the exact VibeContainers development identity.",
                relative]);
        }
    }
    return nil;
#endif
}

static BOOL IOSSimMachOSliceBounds(struct mach_header_64 *header,
                                   void *fileBase,
                                   int fd,
                                   uint64_t *sliceLengthOut) {
    struct stat status = {0};
    if (!header || !fileBase || fd < 0 || fstat(fd, &status) != 0
        || status.st_size < (off_t)sizeof(struct mach_header_64)) return NO;
    uintptr_t fileAddress = (uintptr_t)fileBase;
    uintptr_t headerAddress = (uintptr_t)header;
    if (headerAddress < fileAddress) return NO;
    uint64_t sliceOffset = headerAddress - fileAddress;
    uint64_t fileLength = (uint64_t)status.st_size;
    if (!IOSSimSignatureRangeFits(sliceOffset, sizeof(struct mach_header_64), fileLength)) {
        return NO;
    }
    uint64_t sliceLength = fileLength - sliceOffset;
    if (!IOSSimSignatureRangeFits(sizeof(struct mach_header_64),
                                  header->sizeofcmds, sliceLength)) return NO;
    if (sliceLengthOut) *sliceLengthOut = sliceLength;
    return YES;
}

static BOOL IOSSimForEachLoadCommand(
    struct mach_header_64 *header,
    uint64_t sliceLength,
    BOOL (^visitor)(struct load_command *command, NSError **error),
    NSError **error
) {
    if (!header || header->magic != MH_MAGIC_64
        || !IOSSimSignatureRangeFits(sizeof(struct mach_header_64),
                                     header->sizeofcmds, sliceLength)) {
        if (error) *error = IOSSimSigningError(82,
            @"The widget module has a malformed arm64 Mach-O header.");
        return NO;
    }
    uint8_t *commandsStart = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *commandsEnd = commandsStart + header->sizeofcmds;
    struct load_command *command = (struct load_command *)commandsStart;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        uint8_t *address = (uint8_t *)command;
        if (address > commandsEnd
            || (uint64_t)(commandsEnd - address) < sizeof(struct load_command)
            || command->cmdsize < sizeof(struct load_command)
            || (uint64_t)command->cmdsize > (uint64_t)(commandsEnd - address)) {
            if (error) *error = IOSSimSigningError(83, [NSString stringWithFormat:
                @"The widget module has a malformed load command at index %u.", index]);
            return NO;
        }
        if (visitor && !visitor(command, error)) return NO;
        command = (struct load_command *)(address + command->cmdsize);
    }
    return YES;
}

static NSError *IOSSimCollectWidgetObjectiveCClassNames(
    NSString *imagePath,
    NSMutableSet<NSString *> *classNames
) {
    __block NSError *sliceError = nil;
    NSString *parseError = LCParseMachO(
        imagePath.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header,
          int fd, void *fileBase) {
            (void)unusedPath;
            if (sliceError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                sliceError = IOSSimSigningError(276, [NSString stringWithFormat:
                    @"The Objective-C metadata in %@ has invalid arm64 slice bounds.",
                    imagePath.lastPathComponent]);
                return;
            }

            __block struct symtab_command symbolTable = {0};
            __block NSUInteger symbolTableCount = 0;
            NSError *commandError = nil;
            BOOL valid = IOSSimForEachLoadCommand(
                header, sliceLength,
                ^BOOL(struct load_command *command, NSError **visitorError) {
                    if (command->cmd != LC_SYMTAB) return YES;
                    if (command->cmdsize < sizeof(struct symtab_command)) {
                        if (visitorError) *visitorError = IOSSimSigningError(
                            277, @"The widget module has a truncated symbol table while checking Objective-C classes.");
                        return NO;
                    }
                    symbolTable = *(struct symtab_command *)command;
                    symbolTableCount++;
                    return YES;
                }, &commandError);
            if (!valid) {
                sliceError = commandError ?: IOSSimSigningError(
                    283, @"The widget module's Objective-C metadata could not be validated.");
                return;
            }
            if (symbolTableCount == 0) return;
            if (symbolTableCount != 1
                || !IOSSimSignatureRangeFits(
                    symbolTable.symoff,
                    (uint64_t)symbolTable.nsyms * sizeof(struct nlist_64),
                    sliceLength)
                || !IOSSimSignatureRangeFits(
                    symbolTable.stroff, symbolTable.strsize, sliceLength)) {
                sliceError = IOSSimSigningError(280,
                    @"The widget module has an out-of-range Objective-C symbol table.");
                return;
            }

            const struct nlist_64 *symbols = (const struct nlist_64 *)
                ((const uint8_t *)header + symbolTable.symoff);
            const char *strings = (const char *)header + symbolTable.stroff;
            static const char prefix[] = "_OBJC_CLASS_$_";
            for (uint32_t index = 0; index < symbolTable.nsyms; index++) {
                const struct nlist_64 *symbol = &symbols[index];
                if ((symbol->n_type & N_STAB) != 0
                    || (symbol->n_type & N_TYPE) == N_UNDF
                    || symbol->n_un.n_strx == 0
                    || symbol->n_un.n_strx >= symbolTable.strsize) continue;
                const char *name = strings + symbol->n_un.n_strx;
                size_t remaining = symbolTable.strsize - symbol->n_un.n_strx;
                const char *terminator = memchr(name, '\0', remaining);
                if (!terminator) {
                    sliceError = IOSSimSigningError(281,
                        @"The widget module has an unterminated Objective-C class symbol.");
                    return;
                }
                size_t length = (size_t)(terminator - name);
                size_t prefixLength = sizeof(prefix) - 1;
                if (length <= prefixLength
                    || memcmp(name, prefix, prefixLength) != 0) continue;
                NSString *className = [[NSString alloc]
                    initWithBytes:name + prefixLength
                           length:length - prefixLength
                         encoding:NSUTF8StringEncoding];
                if (!className.length) {
                    sliceError = IOSSimSigningError(282,
                        @"The widget module has a non-UTF-8 Objective-C class symbol.");
                    return;
                }
                [classNames addObject:className];
            }
        });
    if (sliceError) return sliceError;
    if (parseError.length) {
        return IOSSimSigningError(284, [NSString stringWithFormat:
            @"Could not inspect Objective-C classes in %@: %@",
            imagePath.lastPathComponent, parseError]);
    }
    return nil;
}

static NSError *IOSSimValidateWidgetObjectiveCClassIsolation(
    NSString *modulePath,
    NSString *mainExecutablePath
) {
    NSMutableArray<NSString *> *machOs =
        [IOSSimMachOPathsUnderRoot(modulePath) mutableCopy];
    BOOL containsMain = NO;
    for (NSString *path in machOs) {
        if (IOSSimPathsReferToSameFile(path, mainExecutablePath)) {
            containsMain = YES;
            break;
        }
    }
    if (!containsMain && IOSSimIsMachOAtPath(mainExecutablePath)) {
        [machOs addObject:mainExecutablePath];
    }

    for (NSString *imagePath in machOs) {
        NSMutableSet<NSString *> *classNames = [NSMutableSet set];
        NSError *metadataError = IOSSimCollectWidgetObjectiveCClassNames(
            imagePath, classNames);
        if (metadataError) return metadataError;
        for (NSString *className in classNames) {
            Class existingClass = objc_lookUpClass(className.UTF8String);
            if (!existingClass) continue;
            const char *existingImageBytes = class_getImageName(existingClass);
            NSString *existingImage = existingImageBytes
                ? [NSString stringWithUTF8String:existingImageBytes] : @"unknown image";

            NSString *relativeImage = IOSSimRelativePath(imagePath, modulePath)
                ?: imagePath.lastPathComponent;
            return IOSSimSigningError(285, [NSString stringWithFormat:
                @"Widget module image '%@' defines Objective-C class '%@', which is already registered by %@. Loading it in-process would corrupt host class dispatch, so this widget is not compatible with the device renderer.",
                relativeImage, className, existingImage]);
        }
    }
    return nil;
}

/// Objective-C does not run a category's `+initialize` when the category is
/// attached by dlopen after its target class has already initialized. Some
/// widget dependencies rely on that initializer to build dynamic-property
/// metadata for categories on NSUserDefaults (Roxas is one example). Invoke
/// only the implementation that the just-loaded, isolated module installed;
/// never call Foundation's initializer or an implementation owned by another
/// guest image.
static NSError *IOSSimInitializeLateLoadedWidgetDefaultsCategory(
    NSString *modulePath
) {
    Class defaultsClass = NSUserDefaults.class;
    SEL initializeSelector = sel_registerName("initialize");
    Method initializeMethod = class_getClassMethod(defaultsClass,
                                                   initializeSelector);
    if (!initializeMethod) return nil;

    IMP implementation = method_getImplementation(initializeMethod);
    Dl_info implementationInfo = {0};
    if (!implementation
        || dladdr((const void *)implementation, &implementationInfo) == 0
        || !implementationInfo.dli_fname) return nil;

    NSString *implementationImage = IOSSimCanonicalPath(
        [NSString stringWithUTF8String:implementationInfo.dli_fname]
    );
    NSString *canonicalModule = IOSSimCanonicalPath(modulePath);
    NSString *modulePrefix = [canonicalModule stringByAppendingString:@"/"];
    if (![implementationImage hasPrefix:modulePrefix]) return nil;

    static NSObject *initializationLock;
    static NSMutableSet<NSString *> *initializedImplementations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        initializationLock = [NSObject new];
        initializedImplementations = [NSMutableSet set];
    });

    NSString *implementationKey = [NSString stringWithFormat:@"%@::%p",
        implementationImage, implementation];
    @synchronized (initializationLock) {
        if ([initializedImplementations containsObject:implementationKey]) {
            return nil;
        }

        @try {
            ((void (*)(id, SEL))implementation)(defaultsClass,
                                                initializeSelector);
        } @catch (NSException *exception) {
            return IOSSimSigningError(286, [NSString stringWithFormat:
                @"The widget dependency initializer in %@ raised %@: %@",
                implementationImage.lastPathComponent,
                exception.name,
                exception.reason ?: @"no reason"]);
        }
        [initializedImplementations addObject:implementationKey];
    }

    NSLog(@"[WidgetModule] Initialized late-loaded NSUserDefaults category from %@.",
          implementationImage.lastPathComponent);
    return nil;
}

static BOOL IOSSimWidgetSliceTargetsIOS(struct mach_header_64 *header,
                                        uint64_t sliceLength,
                                        NSError **error) {
    __block BOOL sawPlatform = NO;
    __block BOOL targetsIOS = NO;
    BOOL valid = IOSSimForEachLoadCommand(header, sliceLength,
        ^BOOL(struct load_command *command, NSError **visitorError) {
            if (command->cmd == LC_BUILD_VERSION) {
                if (command->cmdsize < sizeof(struct build_version_command)) {
                    if (visitorError) *visitorError = IOSSimSigningError(84,
                        @"The widget module has a truncated LC_BUILD_VERSION command.");
                    return NO;
                }
                sawPlatform = YES;
                // mach-o/loader.h defines PLATFORM_IOS as 2. Keep the numeric
                // comparison usable with older SDK headers as well.
                targetsIOS = ((struct build_version_command *)command)->platform == 2;
            } else if (command->cmd == LC_VERSION_MIN_IPHONEOS) {
                sawPlatform = YES;
                targetsIOS = YES;
            } else if (command->cmd == LC_VERSION_MIN_MACOSX
                       || command->cmd == LC_VERSION_MIN_TVOS
                       || command->cmd == LC_VERSION_MIN_WATCHOS) {
                sawPlatform = YES;
            }
            return YES;
        }, error);
    if (!valid) return NO;
    if (!sawPlatform || !targetsIOS) {
        if (error) *error = IOSSimSigningError(85,
            @"The widget executable does not target the physical-iOS Mach-O platform required by this host process.");
        return NO;
    }
    return YES;
}

/// Widget extensions conventionally reach their containing application's
/// frameworks with `@executable_path/../../Frameworks`. A converted widget is
/// a dylib inside an already-running host, so preserving that traversal would
/// either point at VibeContainers or back into the immutable installed guest.
/// Collapse only that well-known app-framework traversal into the staged
/// module's own Frameworks directory. Other executable-relative paths retain
/// their exact suffix and are checked by the dependency validator.
static NSString *IOSSimRelocatedWidgetExecutableSuffix(const char *bytes,
                                                        size_t length) {
    NSString *suffix = [[NSString alloc] initWithBytes:bytes
                                                length:length
                                              encoding:NSUTF8StringEncoding];
    if (!suffix.length) return suffix;
    NSArray<NSString *> *components = suffix.pathComponents;
    NSUInteger index = 0;
    while (index < components.count
           && ([components[index] isEqualToString:@"/"]
               || [components[index] isEqualToString:@"."])) index++;
    NSUInteger parentCount = 0;
    while (index < components.count
           && [components[index] isEqualToString:@".."]) {
        parentCount++;
        index++;
    }
    if (parentCount < 2 || index >= components.count
        || ![components[index] isEqualToString:@"Frameworks"]) {
        return suffix;
    }
    NSMutableArray<NSString *> *relocated = [NSMutableArray arrayWithObject:@"Frameworks"];
    if (index + 1 < components.count) {
        [relocated addObjectsFromArray:[components subarrayWithRange:
            NSMakeRange(index + 1, components.count - index - 1)]];
    }
    return [@"/" stringByAppendingString:
        [NSString pathWithComponents:relocated]];
}

static BOOL IOSSimRewriteExecutablePathCommands(struct mach_header_64 *header,
                                                uint64_t sliceLength,
                                                BOOL rewrite,
                                                NSString *replacementPrefix,
                                                BOOL imageDirectoryIsInFrameworks,
                                                NSUInteger *rewriteCountOut,
                                                NSError **error) {
    static const char oldPrefix[] = "@executable_path";
    __block NSUInteger rewriteCount = 0;
    BOOL valid = IOSSimForEachLoadCommand(header, sliceLength,
        ^BOOL(struct load_command *command, NSError **visitorError) {
            uint32_t stringOffset = 0;
            switch (command->cmd) {
                case LC_RPATH:
                    if (command->cmdsize < sizeof(struct rpath_command)) return YES;
                    stringOffset = ((struct rpath_command *)command)->path.offset;
                    break;
                case LC_ID_DYLIB:
                case LC_LOAD_DYLIB:
                case LC_LOAD_WEAK_DYLIB:
                case LC_REEXPORT_DYLIB:
                case LC_LOAD_UPWARD_DYLIB:
                case LC_LAZY_LOAD_DYLIB:
                    if (command->cmdsize < sizeof(struct dylib_command)) return YES;
                    stringOffset = ((struct dylib_command *)command)->dylib.name.offset;
                    break;
                default:
                    return YES;
            }
            if (stringOffset >= command->cmdsize) {
                if (visitorError) *visitorError = IOSSimSigningError(86,
                    @"The widget executable contains an out-of-range load-command path.");
                return NO;
            }
            char *value = (char *)command + stringOffset;
            size_t capacity = command->cmdsize - stringOffset;
            size_t oldLength = strnlen(value, capacity);
            if (oldLength == capacity) {
                if (visitorError) *visitorError = IOSSimSigningError(87,
                    @"The widget executable contains an unterminated load-command path.");
                return NO;
            }
            size_t oldPrefixLength = sizeof(oldPrefix) - 1;
            if (oldLength < oldPrefixLength
                || memcmp(value, oldPrefix, oldPrefixLength) != 0
                || (oldLength > oldPrefixLength && value[oldPrefixLength] != '/')) {
                return YES;
            }
            if (!rewrite) {
                rewriteCount++;
                return YES;
            }
            const char *suffix = value + oldPrefixLength;
            size_t suffixLength = oldLength - oldPrefixLength;
            NSString *relocatedSuffix = IOSSimRelocatedWidgetExecutableSuffix(
                suffix, suffixLength);
            if (!relocatedSuffix) {
                if (visitorError) *visitorError = IOSSimSigningError(141,
                    @"The widget executable contains a non-UTF-8 executable-relative path.");
                return NO;
            }
            NSString *replacementValue = [replacementPrefix ?: @"@loader_path"
                stringByAppendingString:relocatedSuffix];
            // Images copied below Module/Frameworks do not need to walk all
            // the way back to the module root and then descend into
            // Frameworks again. Cancelling that common component makes paths
            // such as @executable_path/Frameworks strictly shorter, which is
            // required by Mach-O commands whose string capacity is exact.
            if (imageDirectoryIsInFrameworks
                && [replacementPrefix hasSuffix:@"/.."]
                && ([relocatedSuffix isEqualToString:@"/Frameworks"]
                    || [relocatedSuffix hasPrefix:@"/Frameworks/"])) {
                NSString *compactPrefix = [replacementPrefix substringToIndex:
                    replacementPrefix.length - @"/..".length];
                NSString *compactSuffix = [relocatedSuffix substringFromIndex:
                    @"/Frameworks".length];
                replacementValue = [compactPrefix stringByAppendingString:compactSuffix];
            }
            const char *replacement = replacementValue.UTF8String;
            size_t replacementLength = replacement ? strlen(replacement) : 0;
            if (replacementLength + 1 > capacity) {
                if (visitorError) *visitorError = IOSSimSigningError(88,
                    @"The widget executable has no room for its loader-relative dependency path.");
                return NO;
            }
            memset(value, 0, capacity);
            memcpy(value, replacement, replacementLength);
            rewriteCount++;
            return YES;
        }, error);
    if (valid && rewrite) {
        // Two distinct source runpaths can intentionally converge on the same
        // isolated Frameworks directory. dyld rejects duplicate LC_RPATH
        // strings, so retain the first and turn later redundant commands into
        // unique, nonexistent loader-relative search paths without resizing
        // or deleting any load command.
        NSMutableSet<NSString *> *seenRunpaths = [NSMutableSet set];
        __block NSUInteger duplicateIndex = 0;
        valid = IOSSimForEachLoadCommand(header, sliceLength,
            ^BOOL(struct load_command *command, NSError **visitorError) {
                if (command->cmd != LC_RPATH) return YES;
                if (command->cmdsize < sizeof(struct rpath_command)) {
                    if (visitorError) *visitorError = IOSSimSigningError(151,
                        @"The widget executable contains a truncated LC_RPATH command.");
                    return NO;
                }
                uint32_t stringOffset = ((struct rpath_command *)command)->path.offset;
                if (stringOffset >= command->cmdsize) {
                    if (visitorError) *visitorError = IOSSimSigningError(152,
                        @"The widget executable contains an out-of-range LC_RPATH string.");
                    return NO;
                }
                char *value = (char *)command + stringOffset;
                size_t capacity = command->cmdsize - stringOffset;
                size_t length = strnlen(value, capacity);
                if (length == capacity) {
                    if (visitorError) *visitorError = IOSSimSigningError(153,
                        @"The widget executable contains an unterminated LC_RPATH string.");
                    return NO;
                }
                NSString *runpath = [[NSString alloc] initWithBytes:value
                                                             length:length
                                                           encoding:NSUTF8StringEncoding];
                if (!runpath.length) {
                    if (visitorError) *visitorError = IOSSimSigningError(154,
                        @"The widget executable contains an invalid LC_RPATH string.");
                    return NO;
                }
                if (![seenRunpaths containsObject:runpath]) {
                    [seenRunpaths addObject:runpath];
                    return YES;
                }

                NSString *replacement = nil;
                do {
                    replacement = [NSString stringWithFormat:@"@loader_path/.v%lu",
                        (unsigned long)duplicateIndex++];
                } while ([seenRunpaths containsObject:replacement]);
                NSData *bytes = [replacement dataUsingEncoding:NSUTF8StringEncoding];
                if (bytes.length + 1 > capacity) {
                    if (visitorError) *visitorError = IOSSimSigningError(155,
                        @"A duplicate widget runpath has no room for an isolated replacement.");
                    return NO;
                }
                memset(value, 0, capacity);
                memcpy(value, bytes.bytes, bytes.length);
                [seenRunpaths addObject:replacement];
                NSLog(@"[WidgetModule] Replaced duplicate runpath %@ with %@.",
                      runpath, replacement);
                return YES;
            }, error);
    }
    if (rewriteCountOut) *rewriteCountOut = rewriteCount;
    return valid;
}

static NSError *IOSSimPatchWidgetMainForRuntime(NSString *path) {
    __block NSError *patchError;
    __block NSUInteger arm64SliceCount = 0;
    __block NSUInteger rewrittenPathCount = 0;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, false,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (patchError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            arm64SliceCount++;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                patchError = IOSSimSigningError(90,
                    @"The widget executable's arm64 slice extends beyond the file.");
                return;
            }
            if (!IOSSimWidgetSliceTargetsIOS(header, sliceLength, &patchError)) return;
            if (LCIsMachOEncrypted(header)) {
                patchError = IOSSimSigningError(91,
                    @"The widget executable is encrypted. The in-process renderer requires a decrypted widget binary.");
                return;
            }
            if (header->filetype == MH_EXECUTE) {
                struct load_command *first = (struct load_command *)(header + 1);
                if (header->ncmds == 0
                    || (first->cmd != LC_SEGMENT_64 && first->cmd != LC_ID_DYLIB)) {
                    patchError = IOSSimSigningError(92,
                        @"The widget executable has an unsupported first load command for MH_EXECUTE-to-MH_DYLIB conversion.");
                    return;
                }
                int patchResult = LCPatchExecSlice(path.fileSystemRepresentation,
                                                   header, false);
                if (patchResult & PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH) {
                    patchError = IOSSimSigningError(93,
                        @"The widget executable's chained-fixup segment count cannot be converted safely.");
                    return;
                }
                if (patchResult & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER) {
                    // No loader is injected on this path, so this bit only says
                    // there was no room for LiveContainer's disabled placeholder.
                    NSLog(@"[WidgetModule] No spare load-command room in %@; continuing without injection.",
                          path.lastPathComponent);
                }
            } else if (header->filetype != MH_DYLIB) {
                patchError = IOSSimSigningError(94, [NSString stringWithFormat:
                    @"The widget entry image has Mach-O file type %u, not MH_EXECUTE or MH_DYLIB.",
                    header->filetype]);
                return;
            }
            NSUInteger sliceRewrites = 0;
            if (!IOSSimRewriteExecutablePathCommands(header, sliceLength, YES,
                                                     @"@loader_path",
                                                     NO,
                                                     &sliceRewrites, &patchError)) return;
            rewrittenPathCount += sliceRewrites;
            LCChangeMachOUUID(header);

            __block BOOL hasIDDylib = NO;
            if (!IOSSimForEachLoadCommand(header, sliceLength,
                ^BOOL(struct load_command *command, NSError **unusedError) {
                    if (command->cmd == LC_ID_DYLIB) hasIDDylib = YES;
                    return YES;
                }, &patchError)) return;
            if (header->filetype != MH_DYLIB || !hasIDDylib) {
                patchError = IOSSimSigningError(95,
                    @"The widget entry image could not be completed as a loadable MH_DYLIB with LC_ID_DYLIB.");
            }
        });
    if (patchError) return patchError;
    if (parseError.length) {
        return IOSSimSigningError(96, [NSString stringWithFormat:
            @"The widget executable could not be mapped for dylib conversion: %@", parseError]);
    }
    if (arm64SliceCount == 0) {
        return IOSSimSigningError(97,
            @"The widget executable contains no physical-device arm64 slice.");
    }
    NSLog(@"[WidgetModule] Converted %@ (%lu arm64 slice(s), %lu @executable_path rewrite(s)).",
          path.lastPathComponent, (unsigned long)arm64SliceCount,
          (unsigned long)rewrittenPathCount);
    return nil;
}

static NSString *IOSSimWidgetModuleLoaderPrefix(NSString *imagePath,
                                                NSString *moduleRoot,
                                                NSError **error) {
    NSString *root = IOSSimCanonicalPath(moduleRoot);
    NSString *directory = IOSSimCanonicalPath(imagePath.stringByDeletingLastPathComponent);
    if ([directory isEqualToString:root]) return @"@loader_path";
    NSString *relative = IOSSimRelativePath(directory, root);
    if (!relative.length) {
        if (error) *error = IOSSimSigningError(117, [NSString stringWithFormat:
            @"Nested widget image '%@' escaped its isolated module root.",
            imagePath.lastPathComponent]);
        return nil;
    }
    NSArray<NSString *> *components = [relative pathComponents];
    NSMutableString *prefix = [@"@loader_path" mutableCopy];
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"] || [component isEqualToString:@"."]
            || component.length == 0) continue;
        [prefix appendString:@"/.."];
    }
    return prefix;
}

static NSError *IOSSimRewriteWidgetModuleImagePaths(NSString *path,
                                                    NSString *moduleRoot) {
    NSError *prefixError = nil;
    NSString *replacementPrefix = IOSSimWidgetModuleLoaderPrefix(
        path, moduleRoot, &prefixError);
    if (!replacementPrefix) return prefixError;
    NSString *relativeDirectory = IOSSimRelativePath(
        path.stringByDeletingLastPathComponent, moduleRoot);
    NSArray<NSString *> *directoryComponents = relativeDirectory.pathComponents;
    BOOL directoryIsInFrameworks = directoryComponents.count > 0
        && [directoryComponents.firstObject isEqualToString:@"Frameworks"];
    __block NSError *rewriteError;
    __block NSUInteger arm64SliceCount = 0;
    __block NSUInteger rewrittenPathCount = 0;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, false,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (rewriteError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            arm64SliceCount++;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                rewriteError = IOSSimSigningError(118,
                    @"A nested widget image has an out-of-range arm64 slice.");
                return;
            }
            NSUInteger sliceCount = 0;
            if (!IOSSimRewriteExecutablePathCommands(
                    header, sliceLength, YES, replacementPrefix,
                    directoryIsInFrameworks,
                    &sliceCount, &rewriteError)) return;
            rewrittenPathCount += sliceCount;
        });
    if (rewriteError) return rewriteError;
    if (parseError.length) {
        return IOSSimSigningError(119, [NSString stringWithFormat:
            @"Could not rewrite nested widget image '%@': %@",
            path.lastPathComponent, parseError]);
    }
    if (arm64SliceCount == 0) {
        return IOSSimSigningError(120, [NSString stringWithFormat:
            @"Nested widget image '%@' has no arm64 slice.", path.lastPathComponent]);
    }
    if (rewrittenPathCount > 0) {
        NSLog(@"[WidgetModule] Rewrote %lu executable-relative path(s) in %@ using %@.",
              (unsigned long)rewrittenPathCount,
              IOSSimRelativePath(path, moduleRoot) ?: path.lastPathComponent,
              replacementPrefix);
    }
    return nil;
}

static NSError *IOSSimValidateNoExecutablePaths(NSString *path) {
    __block NSError *validationError;
    __block NSUInteger arm64SliceCount = 0;
    __block NSUInteger executablePathCount = 0;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (validationError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            arm64SliceCount++;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                validationError = IOSSimSigningError(121,
                    @"A widget dependency has an out-of-range arm64 slice.");
                return;
            }
            NSUInteger sliceCount = 0;
            if (!IOSSimRewriteExecutablePathCommands(
                    header, sliceLength, NO, nil, NO, &sliceCount,
                    &validationError)) return;
            executablePathCount += sliceCount;
        });
    if (validationError) return validationError;
    if (parseError.length) {
        return IOSSimSigningError(122, [NSString stringWithFormat:
            @"Could not inspect widget dependency '%@': %@",
            path.lastPathComponent, parseError]);
    }
    if (arm64SliceCount == 0) {
        return IOSSimSigningError(123, [NSString stringWithFormat:
            @"Widget dependency '%@' has no arm64 slice.", path.lastPathComponent]);
    }
    if (executablePathCount != 0) {
        return IOSSimSigningError(124, [NSString stringWithFormat:
            @"Widget dependency '%@' still contains %lu @executable_path load command(s); loading it inside VibeContainers would resolve against the wrong process executable.",
            path.lastPathComponent, (unsigned long)executablePathCount]);
    }
    return nil;
}

static NSDictionary *IOSSimWidgetImageLoadMetadata(NSString *path, NSError **error) {
    __block NSError *metadataError;
    __block NSUInteger arm64SliceCount = 0;
    NSMutableOrderedSet<NSString *> *rpaths = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSDictionary *> *dependencies = [NSMutableArray array];
    NSMutableSet<NSString *> *dependencyKeys = [NSMutableSet set];
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (metadataError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            arm64SliceCount++;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                metadataError = IOSSimSigningError(125,
                    @"A widget dependency has an out-of-range arm64 slice.");
                return;
            }
            IOSSimForEachLoadCommand(header, sliceLength,
                ^BOOL(struct load_command *command, NSError **visitorError) {
                    uint32_t stringOffset = 0;
                    BOOL isRPath = command->cmd == LC_RPATH;
                    BOOL isDependency = command->cmd == LC_LOAD_DYLIB
                        || command->cmd == LC_LOAD_WEAK_DYLIB
                        || command->cmd == LC_REEXPORT_DYLIB
                        || command->cmd == LC_LOAD_UPWARD_DYLIB
                        || command->cmd == LC_LAZY_LOAD_DYLIB;
                    if (!isRPath && !isDependency) return YES;
                    if (isRPath) {
                        if (command->cmdsize < sizeof(struct rpath_command)) {
                            if (visitorError) *visitorError = IOSSimSigningError(126,
                                @"A widget dependency has a truncated LC_RPATH command.");
                            return NO;
                        }
                        stringOffset = ((struct rpath_command *)command)->path.offset;
                    } else {
                        if (command->cmdsize < sizeof(struct dylib_command)) {
                            if (visitorError) *visitorError = IOSSimSigningError(127,
                                @"A widget dependency has a truncated dylib command.");
                            return NO;
                        }
                        stringOffset = ((struct dylib_command *)command)->dylib.name.offset;
                    }
                    if (stringOffset >= command->cmdsize) {
                        if (visitorError) *visitorError = IOSSimSigningError(128,
                            @"A widget dependency contains an out-of-range load path.");
                        return NO;
                    }
                    const char *bytes = (const char *)command + stringOffset;
                    size_t capacity = command->cmdsize - stringOffset;
                    size_t length = strnlen(bytes, capacity);
                    if (length == capacity) {
                        if (visitorError) *visitorError = IOSSimSigningError(129,
                            @"A widget dependency contains an unterminated load path.");
                        return NO;
                    }
                    NSString *value = [[NSString alloc] initWithBytes:bytes
                                                               length:length
                                                             encoding:NSUTF8StringEncoding];
                    if (!value.length) {
                        if (visitorError) *visitorError = IOSSimSigningError(130,
                            @"A widget dependency contains a non-UTF-8 load path.");
                        return NO;
                    }
                    if (isRPath) {
                        [rpaths addObject:value];
                    } else {
                        BOOL weak = command->cmd == LC_LOAD_WEAK_DYLIB;
                        NSString *key = [NSString stringWithFormat:@"%@|%d", value, weak];
                        if (![dependencyKeys containsObject:key]) {
                            [dependencyKeys addObject:key];
                            [dependencies addObject:@{ @"path": value, @"weak": @(weak) }];
                        }
                    }
                    return YES;
                }, &metadataError);
        });
    if (metadataError) {
        if (error) *error = metadataError;
        return nil;
    }
    if (parseError.length || arm64SliceCount == 0) {
        if (error) *error = IOSSimSigningError(131, [NSString stringWithFormat:
            @"Could not read widget dependency metadata from '%@': %@",
            path.lastPathComponent,
            parseError.length ? parseError : @"no arm64 slice"]);
        return nil;
    }
    return @{ @"rpaths": rpaths.array, @"dependencies": dependencies };
}

static BOOL IOSSimIsSystemWidgetDependency(NSString *path) {
    return [path hasPrefix:@"/System/Library/"]
        || [path hasPrefix:@"/usr/lib/"]
        || [path hasPrefix:@"/private/preboot/Cryptexes/OS/System/Library/"];
}

static NSString *IOSSimExpandWidgetDependencyToken(NSString *value,
                                                  NSString *imageDirectory,
                                                  NSError **error) {
    for (NSString *token in @[ @"@loader_path", @"@executable_path" ]) {
        if ([value isEqualToString:token]
            || [value hasPrefix:[token stringByAppendingString:@"/"]]) {
            if ([token isEqualToString:@"@executable_path"]) {
                if (error) *error = IOSSimSigningError(132, [NSString stringWithFormat:
                    @"External widget dependency path '%@' still depends on the process executable directory.",
                    value]);
                return nil;
            }
            NSString *suffix = [value substringFromIndex:token.length];
            return IOSSimCanonicalPath([imageDirectory stringByAppendingString:suffix]);
        }
    }
    if ([value hasPrefix:@"/"]) return IOSSimCanonicalPath(value);
    if (error) *error = IOSSimSigningError(133, [NSString stringWithFormat:
        @"Widget dependency path '%@' is neither absolute nor loader-relative.", value]);
    return nil;
}

static NSString *IOSSimExpandWidgetDependencyTokenForStaging(
    NSString *value,
    NSString *imageDirectory,
    NSString *executableDirectory,
    NSError **error
) {
    for (NSString *token in @[ @"@loader_path", @"@executable_path" ]) {
        if (![value isEqualToString:token]
            && ![value hasPrefix:[token stringByAppendingString:@"/"]]) continue;
        NSString *base = [token isEqualToString:@"@loader_path"]
            ? imageDirectory : executableDirectory;
        NSString *suffix = [value substringFromIndex:token.length];
        return IOSSimCanonicalPath([base stringByAppendingString:suffix]);
    }
    if ([value hasPrefix:@"/"]) return IOSSimCanonicalPath(value);
    if (error) *error = IOSSimSigningError(142, [NSString stringWithFormat:
        @"Widget dependency path '%@' is not resolvable while staging its isolated closure.",
        value]);
    return nil;
}

/// Copies only the app-level Frameworks entries reachable from the staged
/// widget. Framework bundles are copied as units so their resources and nested
/// loader-relative code remain available; loose dylibs are copied as files.
/// The installed app is read-only input and is never re-signed or patched.
static NSError *IOSSimStageWidgetDependencyClosure(NSString *appRoot,
                                                    NSString *moduleRoot,
                                                    NSString *mainExecutablePath) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *canonicalApp = IOSSimCanonicalPath(appRoot);
    NSString *canonicalModule = IOSSimCanonicalPath(moduleRoot);
    NSString *canonicalAppFrameworks = IOSSimCanonicalPath(
        [canonicalApp stringByAppendingPathComponent:@"Frameworks"]);
    NSString *modulePrefix = [canonicalModule stringByAppendingString:@"/"];
    NSString *appPrefix = [canonicalApp stringByAppendingString:@"/"];
    NSString *appFrameworkPrefix = [canonicalAppFrameworks stringByAppendingString:@"/"];
    BOOL appFrameworksIsDirectory = NO;
    [manager fileExistsAtPath:canonicalAppFrameworks
                  isDirectory:&appFrameworksIsDirectory];

    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *copiedFrameworkRoots =
        [NSMutableDictionary dictionary];
    __block NSUInteger copiedRootCount = 0;
    NSString *executableDirectory = IOSSimCanonicalPath(
        mainExecutablePath.stringByDeletingLastPathComponent);

    __block __weak NSError *(^weakVisit)(NSString *, NSArray<NSString *> *);
    NSError *(^visit)(NSString *, NSArray<NSString *> *) =
    ^NSError *(NSString *imagePath, NSArray<NSString *> *inheritedRunpaths) {
        NSString *canonicalImage = IOSSimCanonicalPath(imagePath);
        if ([visited containsObject:canonicalImage]) return nil;
        [visited addObject:canonicalImage];
        NSError *metadataError = nil;
        NSDictionary *metadata = IOSSimWidgetImageLoadMetadata(canonicalImage,
                                                               &metadataError);
        if (!metadata) return metadataError;
        NSString *imageDirectory = canonicalImage.stringByDeletingLastPathComponent;
        NSMutableOrderedSet<NSString *> *runpaths = [NSMutableOrderedSet orderedSet];
        for (NSString *rawRunpath in metadata[@"rpaths"]) {
            NSError *expandError = nil;
            NSString *expanded = IOSSimExpandWidgetDependencyTokenForStaging(
                rawRunpath, imageDirectory, executableDirectory, &expandError);
            if (!expanded) return expandError;
            [runpaths addObject:expanded];
        }
        [runpaths addObjectsFromArray:inheritedRunpaths ?: @[]];

        for (NSDictionary *dependency in metadata[@"dependencies"]) {
            NSString *loadPath = dependency[@"path"];
            BOOL weak = [dependency[@"weak"] boolValue];
            if (IOSSimIsSystemWidgetDependency(loadPath)) continue;
            NSString *resolved = nil;
            BOOL hasSystemRunpathCandidate = NO;
            if ([loadPath hasPrefix:@"@rpath/"]) {
                NSString *suffix = [loadPath substringFromIndex:@"@rpath/".length];
                for (NSString *runpath in runpaths) {
                    NSString *candidate = IOSSimCanonicalPath(
                        [runpath stringByAppendingPathComponent:suffix]);
                    if (IOSSimIsSystemWidgetDependency(candidate)) {
                        hasSystemRunpathCandidate = YES;
                        continue;
                    }
                    if ([manager fileExistsAtPath:candidate]) {
                        resolved = candidate;
                        break;
                    }
                }
                if (!resolved && hasSystemRunpathCandidate
                    && [suffix.lastPathComponent hasPrefix:@"libswift"]) continue;
            } else {
                NSError *expandError = nil;
                resolved = IOSSimExpandWidgetDependencyTokenForStaging(
                    loadPath, imageDirectory, executableDirectory, &expandError);
                if (!resolved) return expandError;
                if (IOSSimIsSystemWidgetDependency(resolved)) continue;
                if (![manager fileExistsAtPath:resolved]) resolved = nil;
            }
            if (!resolved) {
                if (weak) {
                    NSLog(@"[WidgetModule] Optional dependency %@ was not present while staging.",
                          loadPath);
                    continue;
                }
                return IOSSimSigningError(143, [NSString stringWithFormat:
                    @"Required widget dependency '%@' could not be resolved while staging %@. Searched runpaths: %@",
                    loadPath, canonicalImage.lastPathComponent,
                    [runpaths.array componentsJoinedByString:@", "]]);
            }
            if (!IOSSimIsMachOAtPath(resolved)) {
                return IOSSimSigningError(144, [NSString stringWithFormat:
                    @"Resolved widget dependency '%@' is not a Mach-O image at %@.",
                    loadPath, resolved]);
            }

            BOOL insideModule = [resolved hasPrefix:modulePrefix];
            BOOL insideApp = [resolved hasPrefix:appPrefix];
            if (!insideModule) {
                if (!insideApp || !appFrameworksIsDirectory
                    || ![resolved hasPrefix:appFrameworkPrefix]) {
                    return IOSSimSigningError(145, [NSString stringWithFormat:
                        @"Widget dependency '%@' resolves outside the isolated extension and its containing app Frameworks directory: %@",
                        loadPath, resolved]);
                }
                NSString *relative = IOSSimRelativePath(resolved,
                                                        canonicalAppFrameworks);
                NSString *topComponent = relative.pathComponents.firstObject;
                if (!topComponent.length || [topComponent isEqualToString:@"/"]
                    || [topComponent isEqualToString:@"."]
                    || [topComponent isEqualToString:@".."]) {
                    return IOSSimSigningError(146, [NSString stringWithFormat:
                        @"Could not derive an isolated Frameworks entry for %@.", resolved]);
                }
                NSString *sourceRoot = IOSSimCanonicalPath(
                    [canonicalAppFrameworks stringByAppendingPathComponent:topComponent]);
                NSString *destinationFrameworks =
                    [canonicalModule stringByAppendingPathComponent:@"Frameworks"];
                NSString *destinationRoot =
                    [destinationFrameworks stringByAppendingPathComponent:topComponent];
                NSString *previousSource = copiedFrameworkRoots[topComponent];
                if (previousSource && ![previousSource isEqualToString:sourceRoot]) {
                    return IOSSimSigningError(147, [NSString stringWithFormat:
                        @"Two external widget dependencies collide at Frameworks/%@.",
                        topComponent]);
                }
                if (!previousSource) {
                    if ([manager fileExistsAtPath:destinationRoot]) {
                        return IOSSimSigningError(148, [NSString stringWithFormat:
                            @"The widget's embedded Frameworks/%@ conflicts with the containing app dependency of the same name.",
                            topComponent]);
                    }
                    NSError *fileError = nil;
                    if (![manager createDirectoryAtPath:destinationFrameworks
                            withIntermediateDirectories:YES attributes:nil
                                                   error:&fileError]
                        || ![manager copyItemAtPath:sourceRoot
                                             toPath:destinationRoot
                                              error:&fileError]) {
                        return IOSSimSigningError(149, [NSString stringWithFormat:
                            @"Could not copy external widget dependency Frameworks/%@ into its isolated module: %@",
                            topComponent,
                            fileError.localizedDescription ?: @"unknown file error"]);
                    }
                    copiedFrameworkRoots[topComponent] = sourceRoot;
                    copiedRootCount++;
                    NSLog(@"[WidgetModule] Isolated external dependency Frameworks/%@.",
                          topComponent);
                }
            }
            NSError *(^recurse)(NSString *, NSArray<NSString *> *) = weakVisit;
            if (!recurse) {
                return IOSSimSigningError(150,
                    @"The widget dependency stager lost its recursive traversal context.");
            }
            NSError *childError = recurse(resolved, runpaths.array);
            if (childError) return childError;
        }
        return nil;
    };
    weakVisit = visit;
    NSError *result = visit(mainExecutablePath, @[]);
    weakVisit = nil;
    if (!result) {
        NSLog(@"[WidgetModule] Isolated dependency closure: %lu external Frameworks entr%@, %lu inspected image(s).",
              (unsigned long)copiedRootCount,
              copiedRootCount == 1 ? @"y" : @"ies",
              (unsigned long)visited.count);
    }
    return result;
#endif
}

static NSError *IOSSimValidateWidgetDependencyGraph(NSString *appRoot,
                                                    NSString *moduleRoot,
                                                    NSString *mainExecutablePath) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSString *canonicalApp = IOSSimCanonicalPath(appRoot);
    NSString *canonicalModule = IOSSimCanonicalPath(moduleRoot);
    NSString *appPrefix = [canonicalApp stringByAppendingString:@"/"];
    NSString *modulePrefix = [canonicalModule stringByAppendingString:@"/"];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    __block __weak NSError *(^weakVisit)(NSString *, NSArray<NSString *> *);
    NSError *(^visit)(NSString *, NSArray<NSString *> *) =
    ^NSError *(NSString *imagePath, NSArray<NSString *> *inheritedRunpaths) {
        NSString *canonicalImage = IOSSimCanonicalPath(imagePath);
        if ([visited containsObject:canonicalImage]) return nil;
        [visited addObject:canonicalImage];
        NSError *metadataError = nil;
        NSDictionary *metadata = IOSSimWidgetImageLoadMetadata(canonicalImage,
                                                               &metadataError);
        if (!metadata) return metadataError;
        NSString *imageDirectory = canonicalImage.stringByDeletingLastPathComponent;
        NSMutableOrderedSet<NSString *> *runpaths = [NSMutableOrderedSet orderedSet];
        for (NSString *rawRunpath in metadata[@"rpaths"]) {
            NSError *expandError = nil;
            NSString *expanded = IOSSimExpandWidgetDependencyToken(
                rawRunpath, imageDirectory, &expandError);
            if (!expanded) return expandError;
            [runpaths addObject:expanded];
        }
        [runpaths addObjectsFromArray:inheritedRunpaths ?: @[]];

        for (NSDictionary *dependency in metadata[@"dependencies"]) {
            NSString *loadPath = dependency[@"path"];
            BOOL weak = [dependency[@"weak"] boolValue];
            if (IOSSimIsSystemWidgetDependency(loadPath)) continue;
            NSString *resolved = nil;
            BOOL hasSystemRunpathCandidate = NO;
            if ([loadPath hasPrefix:@"@rpath/"]) {
                NSString *suffix = [loadPath substringFromIndex:@"@rpath/".length];
                for (NSString *runpath in runpaths) {
                    NSString *candidate = IOSSimCanonicalPath(
                        [runpath stringByAppendingPathComponent:suffix]);
                    if (IOSSimIsSystemWidgetDependency(candidate)) {
                        hasSystemRunpathCandidate = YES;
                        continue;
                    }
                    if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
                        resolved = candidate;
                        break;
                    }
                }
                if (!resolved && hasSystemRunpathCandidate
                    && [suffix.lastPathComponent hasPrefix:@"libswift"]) continue;
            } else {
                NSError *expandError = nil;
                resolved = IOSSimExpandWidgetDependencyToken(
                    loadPath, imageDirectory, &expandError);
                if (!resolved) return expandError;
                if (IOSSimIsSystemWidgetDependency(resolved)) continue;
                if (![NSFileManager.defaultManager fileExistsAtPath:resolved]) {
                    resolved = nil;
                }
            }
            if (!resolved) {
                if (weak) {
                    NSLog(@"[WidgetModule] Optional dependency %@ was not present; dyld may omit it.",
                          loadPath);
                    continue;
                }
                return IOSSimSigningError(134, [NSString stringWithFormat:
                    @"Required widget dependency '%@' could not be resolved from %@. Searched runpaths: %@",
                    loadPath, canonicalImage.lastPathComponent,
                    [runpaths.array componentsJoinedByString:@", "]]);
            }
            BOOL insideModule = [resolved hasPrefix:modulePrefix];
            BOOL insideApp = [resolved hasPrefix:appPrefix];
            if (!insideModule && !insideApp) {
                return IOSSimSigningError(135, [NSString stringWithFormat:
                    @"Widget dependency '%@' resolved outside both its isolated module and installed guest app: %@",
                    loadPath, resolved]);
            }
            if (!IOSSimIsMachOAtPath(resolved)) {
                return IOSSimSigningError(136, [NSString stringWithFormat:
                    @"Resolved widget dependency '%@' is not a Mach-O image at %@.",
                    loadPath, resolved]);
            }
            if (!insideModule) {
                return IOSSimSigningError(137, [NSString stringWithFormat:
                    @"External guest dependency '%@' still resolves into the installed app instead of the isolated widget module: %@",
                    IOSSimRelativePath(resolved, canonicalApp) ?: resolved.lastPathComponent,
                    loadPath]);
            }
            NSError *(^recurse)(NSString *, NSArray<NSString *> *) = weakVisit;
            if (!recurse) {
                return IOSSimSigningError(140,
                    @"The widget dependency validator lost its recursive traversal context.");
            }
            NSError *childError = recurse(resolved, runpaths.array);
            if (childError) return childError;
        }
        return nil;
    };
    weakVisit = visit;
    NSError *result = visit(mainExecutablePath, @[]);
    weakVisit = nil;
    if (!result) {
        NSLog(@"[WidgetModule] Dependency graph validated: %lu non-system image(s), module=%@.",
              (unsigned long)visited.count, canonicalModule);
    }
    return result;
#endif
}

static NSError *IOSSimValidateWidgetModuleImage(NSString *path) {
    __block NSError *validationError;
    __block NSUInteger arm64SliceCount = 0;
    NSString *parseError = LCParseMachO(path.fileSystemRepresentation, true,
        ^(const char *unusedPath, struct mach_header_64 *header, int fd, void *fileBase) {
            if (validationError || header->magic != MH_MAGIC_64
                || header->cputype != CPU_TYPE_ARM64) return;
            arm64SliceCount++;
            uint64_t sliceLength = 0;
            if (!IOSSimMachOSliceBounds(header, fileBase, fd, &sliceLength)) {
                validationError = IOSSimSigningError(98,
                    @"The staged widget module's arm64 slice is out of range.");
                return;
            }
            if (header->filetype != MH_DYLIB) {
                validationError = IOSSimSigningError(99, [NSString stringWithFormat:
                    @"The staged widget module still has Mach-O type %u instead of MH_DYLIB.",
                    header->filetype]);
                return;
            }
            NSUInteger rewrites = 0;
            if (!IOSSimRewriteExecutablePathCommands(header, sliceLength, NO, nil,
                                                     NO,
                                                     &rewrites, &validationError)) return;
            if (rewrites != 0) {
                validationError = IOSSimSigningError(100,
                    @"The staged widget module still contained executable-relative paths after conversion.");
            }
        });
    if (validationError) return validationError;
    if (parseError.length) {
        return IOSSimSigningError(101, [NSString stringWithFormat:
            @"The staged widget module cannot be inspected: %@", parseError]);
    }
    return arm64SliceCount > 0 ? nil : IOSSimSigningError(102,
        @"The staged widget module contains no arm64 image.");
}

static NSError *IOSSimValidateWidgetModuleSignatures(NSString *modulePath,
                                                     NSString *mainExecutablePath) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    NSMutableArray<NSString *> *machOs = [IOSSimMachOPathsUnderRoot(modulePath) mutableCopy];
    BOOL containsMain = NO;
    for (NSString *path in machOs) {
        if (IOSSimPathsReferToSameFile(path, mainExecutablePath)) {
            containsMain = YES;
            break;
        }
    }
    if (!containsMain && IOSSimIsMachOAtPath(mainExecutablePath)) {
        [machOs addObject:mainExecutablePath];
        containsMain = YES;
    }
    if (!containsMain) {
        return IOSSimSigningError(103,
            @"The staged widget module does not contain its declared main image.");
    }
    for (NSString *path in machOs) {
        NSError *pathError = IOSSimValidateNoExecutablePaths(path);
        if (pathError) return pathError;
        NSError *kernelError = IOSSimAttachKernelSignature(path);
        if (kernelError) return kernelError;
        if (!checkCodeSignature(path.fileSystemRepresentation)) {
            NSString *relative = IOSSimRelativePath(path, modulePath) ?: path.lastPathComponent;
            return IOSSimSigningError(104, [NSString stringWithFormat:
                @"The kernel attached module image '%@', but current-process library validation rejected it. Re-sign the guest with the exact VibeContainers development identity.",
                relative]);
        }
    }
    return nil;
#endif
}

static NSError *IOSSimValidatePreparedWidgetModule(NSString *appRoot,
                                                   NSString *sourceExtensionPath,
                                                   NSURL *moduleURL,
                                                   NSString **mainPathOut) {
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:moduleURL.path
                                            isDirectory:&directory] || !directory) {
        return IOSSimSigningError(105,
            @"The in-process widget module has not been prepared yet.");
    }
    NSError *matchError = nil;
    if (!IOSSimWidgetModuleMatchesSource(appRoot, sourceExtensionPath,
                                         moduleURL, &matchError)) return matchError;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
        [moduleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *executable = info[@"CFBundleExecutable"];
    if (!executable.length) {
        return IOSSimSigningError(106,
            @"The staged widget module has no CFBundleExecutable.");
    }
    NSString *mainPath = [moduleURL URLByAppendingPathComponent:executable].path;
    NSError *imageError = IOSSimValidateWidgetModuleImage(mainPath);
    if (imageError) return imageError;
    NSError *signatureError = IOSSimValidateWidgetModuleSignatures(moduleURL.path, mainPath);
    if (signatureError) return signatureError;
    NSError *dependencyError = IOSSimValidateWidgetDependencyGraph(
        appRoot, moduleURL.path, mainPath);
    if (dependencyError) return dependencyError;
    if (mainPathOut) *mainPathOut = mainPath;
    return nil;
}

static void IOSSimRemoveStaleWidgetModuleStages(NSURL *parentURL) {
    NSArray<NSURL *> *siblings = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:parentURL
      includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                         options:0 error:nil];
    for (NSURL *sibling in siblings) {
        NSString *name = sibling.lastPathComponent;
        BOOL generatedStage = ([name hasPrefix:IOSSimWidgetModuleStagePrefix]
                               || [name hasPrefix:IOSSimWidgetModuleBackupPrefix])
            && [name hasSuffix:@".appex"];
        if (!generatedStage) continue;
        NSNumber *directory = nil;
        if ([sibling getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil]
            && directory.boolValue) {
            [NSFileManager.defaultManager removeItemAtURL:sibling error:nil];
        }
    }
}

static NSError *IOSSimStageWidgetRuntimeModule(Class signerClass,
                                               NSString *appRoot,
                                               NSString *sourceExtensionPath,
                                               NSData *certificate,
                                               NSString *password,
                                               NSString **mainPathOut) {
    NSError *metadataError = nil;
    NSDictionary *sourceMetadata = IOSSimWidgetSourceMetadata(
        appRoot, sourceExtensionPath, &metadataError);
    if (!sourceMetadata) return metadataError;
    NSURL *moduleURL = IOSSimWidgetModuleURL(sourceExtensionPath, sourceMetadata);

    IOSSimInitializeLoadedWidgetModuleRegistry();
    NSString *canonicalModulePrefix = [IOSSimCanonicalPath(moduleURL.path)
        stringByAppendingString:@"/"];
    IOSSimLoadedWidgetModuleRecord *loadedModule = nil;
    os_unfair_lock_lock(&IOSSimLoadedWidgetModuleLock);
    for (IOSSimLoadedWidgetModuleRecord *candidate in
            IOSSimLoadedWidgetModulesByExecutablePath.objectEnumerator) {
        if ([candidate.executablePath hasPrefix:canonicalModulePrefix]) {
            loadedModule = candidate;
            break;
        }
    }
    os_unfair_lock_unlock(&IOSSimLoadedWidgetModuleLock);
    BOOL moduleAlreadyLoaded = loadedModule != nil;
    if (moduleAlreadyLoaded) {
        if (mainPathOut) *mainPathOut = loadedModule.executablePath;
        return nil;
    }

    NSString *preparedMainPath = nil;
    NSError *existingError = IOSSimValidatePreparedWidgetModule(
        appRoot, sourceExtensionPath, moduleURL, &preparedMainPath);
    if (!existingError) {
        if (mainPathOut) *mainPathOut = preparedMainPath;
        NSLog(@"[WidgetModule] Reusing validated module %@.", moduleURL.path);
        return nil;
    }
    NSLog(@"[WidgetModule] Staging replacement for %@ after validation code %ld: %@",
          sourceMetadata[IOSSimWidgetSourceIdentifierKey], (long)existingError.code,
          existingError.localizedDescription);

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *parentURL = moduleURL.URLByDeletingLastPathComponent;
    NSError *fileError = nil;
    if (![manager createDirectoryAtURL:parentURL withIntermediateDirectories:YES
                             attributes:nil error:&fileError]) {
        return IOSSimSigningError(107, [NSString stringWithFormat:
            @"Could not create the widget module staging directory: %@",
            fileError.localizedDescription]);
    }
    IOSSimRemoveStaleWidgetModuleStages(parentURL);
    NSURL *temporaryURL = [parentURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@%@.appex", IOSSimWidgetModuleStagePrefix,
                                   NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *backupURL = [parentURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@%@.appex", IOSSimWidgetModuleBackupPrefix,
                                   NSUUID.UUID.UUIDString] isDirectory:YES];
    if (![manager copyItemAtURL:[NSURL fileURLWithPath:sourceExtensionPath isDirectory:YES]
                          toURL:temporaryURL error:&fileError]) {
        return IOSSimSigningError(108, [NSString stringWithFormat:
            @"Could not isolate the source widget for dylib conversion: %@",
            fileError.localizedDescription]);
    }
    NSError *(^failAndClean)(NSInteger, NSString *) = ^NSError *(NSInteger code,
                                                                  NSString *message) {
        [manager removeItemAtURL:temporaryURL error:nil];
        return IOSSimSigningError(code, message);
    };

    for (NSString *relative in @[ @"_CodeSignature", @"embedded.mobileprovision" ]) {
        NSURL *staleURL = [temporaryURL URLByAppendingPathComponent:relative];
        if ([manager fileExistsAtPath:staleURL.path]
            && ![manager removeItemAtURL:staleURL error:&fileError]) {
            return failAndClean(109, [NSString stringWithFormat:
                @"Could not remove stale %@ from the isolated widget module: %@",
                relative, fileError.localizedDescription]);
        }
    }

    NSMutableDictionary *moduleInfo = [IOSSimWidgetInfo(sourceExtensionPath) mutableCopy];
    [moduleInfo addEntriesFromDictionary:sourceMetadata];
    NSError *serializationError = nil;
    NSData *infoData = [NSPropertyListSerialization dataWithPropertyList:moduleInfo
                                                                  format:NSPropertyListBinaryFormat_v1_0
                                                                 options:0 error:&serializationError];
    NSURL *infoURL = [temporaryURL URLByAppendingPathComponent:@"Info.plist"];
    if (!infoData || ![infoData writeToURL:infoURL options:NSDataWritingAtomic
                                      error:&fileError]) {
        return failAndClean(110, [NSString stringWithFormat:
            @"Could not write widget module metadata: %@",
            serializationError.localizedDescription
                ?: fileError.localizedDescription ?: @"unknown error"]);
    }
    NSString *executable = moduleInfo[@"CFBundleExecutable"];
    NSString *temporaryMainPath = [temporaryURL URLByAppendingPathComponent:
        executable ?: @""].path;
    if (!executable.length || !IOSSimIsMachOAtPath(temporaryMainPath)) {
        return failAndClean(111,
            @"The isolated widget module has no signable CFBundleExecutable.");
    }
    NSError *closureError = IOSSimStageWidgetDependencyClosure(
        appRoot, temporaryURL.path, temporaryMainPath);
    if (closureError) {
        return failAndClean(closureError.code,
                            closureError.localizedDescription);
    }
    NSError *modeError = IOSSimRepairExecutableModes(temporaryURL.path);
    if (modeError) return failAndClean(modeError.code, modeError.localizedDescription);
    NSError *patchError = IOSSimPatchWidgetMainForRuntime(temporaryMainPath);
    if (patchError) return failAndClean(patchError.code, patchError.localizedDescription);
    LCPatchAppBundleFixupARM64eSlice(temporaryURL);

    NSMutableArray<NSString *> *machOs = [IOSSimMachOPathsUnderRoot(temporaryURL.path) mutableCopy];
    BOOL containsMain = NO;
    NSMutableArray<NSString *> *nestedMachOs = [NSMutableArray array];
    for (NSString *path in machOs) {
        if (IOSSimPathsReferToSameFile(path, temporaryMainPath)) containsMain = YES;
        else [nestedMachOs addObject:path];
    }
    if (!containsMain) {
        if (!IOSSimIsMachOAtPath(temporaryMainPath)) {
            return failAndClean(112,
                @"The converted widget module main image disappeared before signing.");
        }
        [machOs addObject:temporaryMainPath];
    }
    for (NSString *path in machOs) {
        NSError *rewriteError = IOSSimRewriteWidgetModuleImagePaths(
            path, temporaryURL.path);
        if (rewriteError) {
            return failAndClean(rewriteError.code,
                                rewriteError.localizedDescription);
        }
    }
    NSString *hostIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!hostIdentifier.length) {
        return failAndClean(113,
            @"VibeContainers has no bundle identifier for widget module signing.");
    }
    NSError *signingError = IOSSimSignPaths(signerClass, nestedMachOs,
                                             hostIdentifier, certificate, password);
    if (!signingError) {
        signingError = IOSSimSignPaths(signerClass, @[ temporaryMainPath ],
                                       hostIdentifier, certificate, password);
    }
    if (signingError) {
        return failAndClean(114, [NSString stringWithFormat:
            @"ZSign could not sign the converted widget module: %@",
            signingError.localizedDescription]);
    }
    modeError = IOSSimRepairExecutableModes(temporaryURL.path);
    if (modeError) return failAndClean(modeError.code, modeError.localizedDescription);
    NSError *imageError = IOSSimValidateWidgetModuleImage(temporaryMainPath);
    if (imageError) return failAndClean(imageError.code, imageError.localizedDescription);
    NSError *signatureError = IOSSimValidateWidgetModuleSignatures(
        temporaryURL.path, temporaryMainPath);
    if (signatureError) {
        return failAndClean(signatureError.code, signatureError.localizedDescription);
    }
    NSError *dependencyError = IOSSimValidateWidgetDependencyGraph(
        appRoot, temporaryURL.path, temporaryMainPath);
    if (dependencyError) {
        return failAndClean(dependencyError.code,
                            dependencyError.localizedDescription);
    }

    BOOL hadPrevious = [manager fileExistsAtPath:moduleURL.path];
    if (hadPrevious && ![manager moveItemAtURL:moduleURL toURL:backupURL error:&fileError]) {
        return failAndClean(115, [NSString stringWithFormat:
            @"Could not preserve the previous widget module for rollback: %@",
            fileError.localizedDescription]);
    }
    if (![manager moveItemAtURL:temporaryURL toURL:moduleURL error:&fileError]) {
        NSError *rollbackError = nil;
        if (hadPrevious) [manager moveItemAtURL:backupURL toURL:moduleURL error:&rollbackError];
        return IOSSimSigningError(116, [NSString stringWithFormat:
            @"Could not activate the converted widget module: %@%@",
            fileError.localizedDescription,
            rollbackError ? [NSString stringWithFormat:@"; rollback failed: %@",
                             rollbackError.localizedDescription] : @""]);
    }
    if (hadPrevious) [manager removeItemAtURL:backupURL error:nil];
    NSString *finalMainPath = [moduleURL URLByAppendingPathComponent:executable].path;
    if (mainPathOut) *mainPathOut = finalMainPath;
    NSLog(@"[WidgetModule] Prepared source %@ at %@; original .appex remains untouched.",
          sourceMetadata[IOSSimWidgetSourceIdentifierKey], finalMainPath);
    return nil;
}

static NSError *IOSSimValidatePreparedRunner(NSString *appRoot,
                                             NSString *sourceExtensionPath,
                                             NSURL *runnerURL,
                                             BOOL registerPlugin) {
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:runnerURL.path
                                            isDirectory:&directory] || !directory) {
        return IOSSimSigningError(58,
            @"The provisioned widget runner has not been prepared yet.");
    }
    NSError *sourceError = nil;
    if (!IOSSimRunnerMatchesSource(appRoot, sourceExtensionPath, runnerURL, &sourceError)) {
        return sourceError;
    }
    NSError *validationError = IOSSimValidateWidgetBundle(appRoot, runnerURL.path);
    if (validationError) return validationError;

    NSError *profileError = nil;
    NSData *currentProfile = IOSSimWidgetRunnerProfile(&profileError);
    if (!currentProfile) return profileError;
    NSData *stagedProfile = [NSData dataWithContentsOfURL:
        [runnerURL URLByAppendingPathComponent:@"embedded.mobileprovision"]];
    if (![stagedProfile isEqualToData:currentProfile]) {
        return IOSSimSigningError(59,
            @"The staged widget runner uses an older provisioning profile than this VibeContainers build.");
    }

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
        [runnerURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *executable = info[@"CFBundleExecutable"];
    NSString *mainPath = [runnerURL URLByAppendingPathComponent:executable].path;
    NSError *modeError = IOSSimRepairExecutableModes(runnerURL.path);
    if (modeError) return modeError;

    NSError *sealError = nil;
    NSData *expectedSeal = IOSSimCreateCodeResources(runnerURL, executable, &sealError);
    if (!expectedSeal) return sealError;
    NSData *stagedSeal = [NSData dataWithContentsOfURL:
        [[runnerURL URLByAppendingPathComponent:@"_CodeSignature" isDirectory:YES]
            URLByAppendingPathComponent:@"CodeResources"]];
    if (![stagedSeal isEqualToData:expectedSeal]) {
        return IOSSimSigningError(60,
            @"The staged widget runner's resource seal is missing or no longer matches its files.");
    }
    NSError *signatureError = IOSSimValidateRunnerSignatures(runnerURL.path, mainPath);
    if (signatureError) return signatureError;
    return registerPlugin ? IOSSimRegisterWidgetRunner(runnerURL) : nil;
}

static NSError *IOSSimStageWidgetRunner(Class signerClass,
                                        NSString *appRoot,
                                        NSString *sourceExtensionPath,
                                        NSData *certificate,
                                        NSString *password,
                                        NSURL **runnerURLResult) {
    NSError *profileError = nil;
    NSData *profile = IOSSimWidgetRunnerProfile(&profileError);
    if (!profile) return profileError;

    NSError *metadataError = nil;
    NSDictionary *sourceMetadata = IOSSimWidgetSourceMetadata(appRoot,
                                                               sourceExtensionPath,
                                                               &metadataError);
    if (!sourceMetadata) return metadataError;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *runnerURL = IOSSimWidgetRunnerURL(appRoot);
    NSURL *pluginsURL = [runnerURL URLByDeletingLastPathComponent];
    NSError *fileError = nil;
    if (![manager createDirectoryAtURL:pluginsURL
            withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        return IOSSimSigningError(61, [NSString stringWithFormat:
            @"Could not create the widget-runner staging directory: %@",
            fileError.localizedDescription]);
    }

    NSString *temporaryName = [NSString stringWithFormat:@".IOSSimWidgetRunner-%@.appex",
                                NSUUID.UUID.UUIDString];
    NSURL *temporaryURL = [pluginsURL URLByAppendingPathComponent:temporaryName
                                                      isDirectory:YES];
    NSURL *backupURL = [pluginsURL URLByAppendingPathComponent:
        @".IOSSimWidgetRunner-backup.appex" isDirectory:YES];
    NSURL *sourceURL = [NSURL fileURLWithPath:sourceExtensionPath isDirectory:YES];
    NSError *enumerationError = nil;
    NSArray<NSURL *> *stagingEntries = [manager contentsOfDirectoryAtURL:pluginsURL
                                             includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                                                options:0
                                                                  error:&enumerationError];
    if (!stagingEntries) {
        return IOSSimSigningError(76, [NSString stringWithFormat:
            @"Could not inspect stale widget-runner stages: %@",
            enumerationError.localizedDescription]);
    }
    for (NSURL *entryURL in stagingEntries) {
        NSString *name = entryURL.lastPathComponent;
        BOOL isStaleStageName = [name hasPrefix:@".IOSSimWidgetRunner-"]
            && [name hasSuffix:@".appex"];
        if (!isStaleStageName
            || [name isEqualToString:temporaryName]
            || [name isEqualToString:backupURL.lastPathComponent]
            || [name isEqualToString:IOSSimWidgetRunnerBundleName]
            || IOSSimPathsReferToSameFile(entryURL.path, sourceURL.path)) {
            continue;
        }
        NSNumber *isDirectory = nil;
        if (![entryURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil]
            || !isDirectory.boolValue) {
            continue;
        }
        NSError *cleanupError = nil;
        if (![manager removeItemAtURL:entryURL error:&cleanupError]) {
            return IOSSimSigningError(77, [NSString stringWithFormat:
                @"Could not remove stale widget-runner stage '%@': %@",
                name, cleanupError.localizedDescription]);
        }
        NSLog(@"[WidgetRunner] Removed stale interrupted stage %@", name);
    }
    if ([manager fileExistsAtPath:backupURL.path]
        && ![manager removeItemAtURL:backupURL error:&fileError]) {
        return IOSSimSigningError(62, [NSString stringWithFormat:
            @"Could not clear the previous widget-runner rollback bundle: %@",
            fileError.localizedDescription]);
    }
    if (![manager copyItemAtURL:sourceURL toURL:temporaryURL error:&fileError]) {
        return IOSSimSigningError(63, [NSString stringWithFormat:
            @"Could not copy the source widget into its isolated runner stage: %@",
            fileError.localizedDescription]);
    }

    NSError *(^failAndClean)(NSInteger, NSString *) = ^NSError *(NSInteger code,
                                                                 NSString *message) {
        [manager removeItemAtURL:temporaryURL error:nil];
        return IOSSimSigningError(code, message);
    };
    NSURL *oldSignatureURL = [temporaryURL URLByAppendingPathComponent:@"_CodeSignature"
                                                            isDirectory:YES];
    if ([manager fileExistsAtPath:oldSignatureURL.path]
        && ![manager removeItemAtURL:oldSignatureURL error:&fileError]) {
        return failAndClean(64, [NSString stringWithFormat:
            @"Could not remove the source widget's stale resource seal: %@",
            fileError.localizedDescription]);
    }

    NSMutableDictionary *runnerInfo = [IOSSimWidgetInfo(sourceExtensionPath) mutableCopy];
    runnerInfo[@"CFBundleIdentifier"] = IOSSimWidgetRunnerBundleIdentifier;
    [runnerInfo addEntriesFromDictionary:sourceMetadata];
    NSError *serializationError = nil;
    NSData *infoData = [NSPropertyListSerialization dataWithPropertyList:runnerInfo
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&serializationError];
    NSURL *infoURL = [temporaryURL URLByAppendingPathComponent:@"Info.plist"];
    if (!infoData || ![infoData writeToURL:infoURL options:NSDataWritingAtomic
                                      error:&fileError]) {
        return failAndClean(65, [NSString stringWithFormat:
            @"Could not write the widget runner's provisioned Info.plist: %@",
            serializationError.localizedDescription
                ?: fileError.localizedDescription ?: @"unknown error"]);
    }
    NSURL *embeddedProfileURL = [temporaryURL
        URLByAppendingPathComponent:@"embedded.mobileprovision"];
    if (![profile writeToURL:embeddedProfileURL options:NSDataWritingAtomic error:&fileError]) {
        return failAndClean(66, [NSString stringWithFormat:
            @"Could not install the widget runner's provisioning profile: %@",
            fileError.localizedDescription]);
    }

    NSError *modeError = IOSSimRepairExecutableModes(temporaryURL.path);
    if (modeError) return failAndClean(modeError.code, modeError.localizedDescription);
    NSString *executable = runnerInfo[@"CFBundleExecutable"];
    NSString *mainPath = [temporaryURL URLByAppendingPathComponent:executable].path;
    NSArray<NSString *> *machOs = IOSSimMachOPathsUnderRoot(temporaryURL.path);
    if (!IOSSimIsMachOAtPath(mainPath)) {
        NSLog(@"[WidgetRunner] Main executable is not Mach-O: path=%@ canonical=%@ enumerated=%@",
              mainPath, IOSSimCanonicalPath(mainPath), machOs);
        return failAndClean(67,
            @"The staged widget runner's CFBundleExecutable is not a signable arm64 Mach-O.");
    }
    NSMutableArray<NSString *> *nestedMachOs = [NSMutableArray array];
    for (NSString *path in machOs) {
        if (!IOSSimPathsReferToSameFile(path, mainPath)) {
            [nestedMachOs addObject:path];
        }
    }
    NSString *hostIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSError *signingError = IOSSimSignPaths(signerClass, nestedMachOs, hostIdentifier,
                                             certificate, password);
    if (signingError) {
        return failAndClean(68, [NSString stringWithFormat:
            @"ZSign could not sign a nested widget-runner dependency: %@",
            signingError.localizedDescription]);
    }

    NSError *sealError = nil;
    NSData *codeResources = IOSSimCreateCodeResources(temporaryURL, executable, &sealError);
    if (!codeResources) return failAndClean(sealError.code, sealError.localizedDescription);
    NSURL *signatureDirectory = [temporaryURL URLByAppendingPathComponent:@"_CodeSignature"
                                                               isDirectory:YES];
    if (![manager createDirectoryAtURL:signatureDirectory
            withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        return failAndClean(69, [NSString stringWithFormat:
            @"Could not create the widget runner's resource-seal directory: %@",
            fileError.localizedDescription]);
    }
    NSURL *codeResourcesURL = [signatureDirectory URLByAppendingPathComponent:@"CodeResources"];
    if (![codeResources writeToURL:codeResourcesURL options:NSDataWritingAtomic error:&fileError]) {
        return failAndClean(70, [NSString stringWithFormat:
            @"Could not write the widget runner's resource seal: %@",
            fileError.localizedDescription]);
    }
    signingError = IOSSimSignProvisionedMain(signerClass, mainPath,
                                              IOSSimWidgetRunnerBundleIdentifier,
                                              certificate, password, profile,
                                              infoData, codeResources);
    if (signingError) {
        return failAndClean(71, [NSString stringWithFormat:
            @"ZSign could not sign the provisioned widget-runner executable last: %@",
            signingError.localizedDescription]);
    }
    modeError = IOSSimRepairExecutableModes(temporaryURL.path);
    if (modeError) return failAndClean(modeError.code, modeError.localizedDescription);
    NSError *signatureError = IOSSimValidateRunnerSignatures(temporaryURL.path, mainPath);
    if (signatureError) {
        return failAndClean(signatureError.code, signatureError.localizedDescription);
    }

    BOOL hadPreviousRunner = [manager fileExistsAtPath:runnerURL.path];
    if (hadPreviousRunner && ![manager moveItemAtURL:runnerURL toURL:backupURL error:&fileError]) {
        return failAndClean(72, [NSString stringWithFormat:
            @"Could not preserve the previous widget runner for rollback: %@",
            fileError.localizedDescription]);
    }
    if (![manager moveItemAtURL:temporaryURL toURL:runnerURL error:&fileError]) {
        NSError *restoreError = nil;
        if (hadPreviousRunner) [manager moveItemAtURL:backupURL toURL:runnerURL error:&restoreError];
        return IOSSimSigningError(73, [NSString stringWithFormat:
            @"Could not activate the staged widget runner: %@%@",
            fileError.localizedDescription,
            restoreError ? [NSString stringWithFormat:@"; rollback also failed: %@",
                            restoreError.localizedDescription] : @""]);
    }

    NSError *registrationError = IOSSimRegisterWidgetRunner(runnerURL);
    if (registrationError) {
        [manager removeItemAtURL:runnerURL error:nil];
        NSError *rollbackError = nil;
        if (hadPreviousRunner) {
            if (![manager moveItemAtURL:backupURL toURL:runnerURL error:&rollbackError]) {
                rollbackError = rollbackError ?: IOSSimSigningError(74,
                    @"The previous widget runner could not be restored.");
            } else {
                NSError *reregisterError = IOSSimRegisterWidgetRunner(runnerURL);
                if (reregisterError) rollbackError = reregisterError;
            }
        }
        return IOSSimSigningError(75, [NSString stringWithFormat:
            @"%@%@",
            registrationError.localizedDescription,
            rollbackError ? [NSString stringWithFormat:
                @" Rollback failed: %@", rollbackError.localizedDescription]
                : (hadPreviousRunner ? @" The previous runner was restored." : @"")]);
    }
    if (hadPreviousRunner) [manager removeItemAtURL:backupURL error:nil];
    if (runnerURLResult) *runnerURLResult = runnerURL;
    return nil;
}

bool IOSSimJITLessSigningConfigured(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *certificate = [defaults dataForKey:IOSSimCertificateDataKey];
    // An empty password is valid for an exported PKCS#12 identity. Test for the
    // presence of the defaults value instead of testing string length.
    if (certificate.length == 0 ||
        [defaults objectForKey:IOSSimCertificatePasswordKey] == nil) return false;

#if !TARGET_OS_SIMULATOR
    // A reinstall can preserve Documents/defaults while changing the signing
    // team. Never select the JIT-less bootstrap with a stale identity.
    NSString *storedTeamID = [defaults stringForKey:IOSSimCertificateTeamIDKey];
    NSString *hostTeamID = [LCSharedUtils teamIdentifier];
    if (!storedTeamID.length) return false;
    if (hostTeamID.length && ![storedTeamID isEqualToString:hostTeamID]) return false;
#endif
    return true;
}

/// Validates and stores the PKCS#12 identity used to sign iOSSim itself.
/// The caller owns the returned error string, if any.
char *IOSSimConfigureJITLessSigning(const void *certificateBytes,
                                    size_t certificateLength,
                                    const char *passwordBytes) {
    if (!certificateBytes || certificateLength == 0) {
        return IOSSimSignerError(@"The selected certificate file is empty.");
    }

    NSError *loadError = nil;
    Class signerClass = IOSSimLoadZSigner(&loadError);
    if (!signerClass) return IOSSimSignerError(loadError.localizedDescription);

    NSData *certificate = [NSData dataWithBytes:certificateBytes length:certificateLength];
    NSString *password = passwordBytes ? [NSString stringWithUTF8String:passwordBytes] : @"";
    NSString *teamID = [(id)signerClass getTeamIdWithCert:certificate pass:password];
    if (!teamID.length) {
        return IOSSimSignerError(@"ZSign could not open this PKCS#12 identity. Check its password.");
    }

#if !TARGET_OS_SIMULATOR
    NSString *hostTeamID = [LCSharedUtils teamIdentifier];
    if (hostTeamID.length && ![hostTeamID isEqualToString:teamID]) {
        return IOSSimSignerError([NSString stringWithFormat:
            @"This identity belongs to team %@, but VibeContainers is signed by team %@. Import the same identity used to install VibeContainers.",
            teamID, hostTeamID]);
    }

    // Match LiveContainer's JIT-less diagnostic: sign a disposable dylib and
    // ask the kernel whether it satisfies this process's library validation.
    NSString *source = [NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"ZSign.dylib"];
    NSString *testPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"IOSSimJITLess-%@.dylib", NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    [NSFileManager.defaultManager copyItemAtPath:source toPath:testPath error:&copyError];
    if (copyError) return IOSSimSignerError(copyError.localizedDescription);

    NSError *testError = IOSSimSignPaths(signerClass, @[testPath],
                                         NSBundle.mainBundle.bundleIdentifier,
                                         certificate, password);
    BOOL accepted = !testError && checkCodeSignature(testPath.fileSystemRepresentation);
    [NSFileManager.defaultManager removeItemAtPath:testPath error:nil];
    if (testError) return IOSSimSignerError(testError.localizedDescription);
    if (!accepted) {
        return IOSSimSignerError(
            @"iOS rejected a test library signed with this identity. Import the exact development certificate used to install VibeContainers."
        );
    }
#endif

    IOSSimWriteSigningValue(certificate, IOSSimCertificateDataKey);
    IOSSimWriteSigningValue(password, IOSSimCertificatePasswordKey);
    IOSSimWriteSigningValue(teamID, IOSSimCertificateTeamIDKey);
    IOSSimWriteSigningValue(NSDate.now, IOSSimCertificateUpdateDateKey);
    return NULL;
}

void IOSSimRemoveJITLessSigning(void) {
    IOSSimWriteSigningValue(nil, IOSSimCertificateDataKey);
    IOSSimWriteSigningValue(nil, IOSSimCertificatePasswordKey);
    IOSSimWriteSigningValue(nil, IOSSimCertificateTeamIDKey);
    IOSSimWriteSigningValue(nil, IOSSimCertificateUpdateDateKey);
}

/// Creates a hidden, source-fingerprinted copy beside the immutable widget
/// extension, converts only that copy's entry image from MH_EXECUTE to
/// MH_DYLIB, rewrites executable-relative paths to loader-relative paths, then
/// signs and kernel-validates every image with the host identity. The caller
/// owns both the returned error and `preparedExecutablePathOut`, when present.
char *IOSSimPrepareWidgetRuntimeModule(const char *appBundlePath,
                                       const char *extensionBundlePath,
                                       char **preparedExecutablePathOut) {
    if (preparedExecutablePathOut) *preparedExecutablePathOut = NULL;
#if TARGET_OS_SIMULATOR
    return IOSSimSignerError(
        @"The in-process widget module loader currently supports physical iOS only. Simulator Mach-O platform routing remains on the existing host path."
    );
#else
    @synchronized (IOSSimWidgetModuleStageLock()) {
        if (!appBundlePath || !extensionBundlePath || !preparedExecutablePathOut) {
            return IOSSimSignerError(
                @"The widget module app, extension, or output path is missing.");
        }
        NSString *appPath = [NSString stringWithUTF8String:appBundlePath];
        NSString *extensionPath = [NSString stringWithUTF8String:extensionBundlePath];
        if (!appPath.length || !extensionPath.length) {
            return IOSSimSignerError(
                @"The widget module app or extension path is not valid UTF-8.");
        }
        NSError *validationError = IOSSimValidateWidgetBundle(appPath, extensionPath);
        if (validationError) return IOSSimSignerError(validationError.localizedDescription);
        if (!IOSSimJITLessSigningConfigured()) {
            return IOSSimSignerError(
                @"The in-process widget module needs the same JIT-less development identity used to install VibeContainers."
            );
        }
        NSError *loadError = nil;
        Class signerClass = IOSSimLoadZSigner(&loadError);
        if (!signerClass) return IOSSimSignerError(loadError.localizedDescription);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSData *certificate = [defaults dataForKey:IOSSimCertificateDataKey];
        NSString *password = [defaults stringForKey:IOSSimCertificatePasswordKey] ?: @"";
        NSString *preparedPath = nil;
        NSError *stageError = IOSSimStageWidgetRuntimeModule(
            signerClass, appPath, extensionPath, certificate, password, &preparedPath);
        if (stageError) {
            NSLog(@"[WidgetModule] Prepare failed for %@ (code %ld): %@",
                  IOSSimWidgetInfo(extensionPath)[@"CFBundleIdentifier"] ?: extensionPath,
                  (long)stageError.code, stageError.localizedDescription);
            return IOSSimSignerError(stageError.localizedDescription);
        }
        if (!preparedPath.length) {
            return IOSSimSignerError(
                @"The widget module signer completed without returning an executable path.");
        }
        *preparedExecutablePathOut = strdup(preparedPath.fileSystemRepresentation);
        if (!*preparedExecutablePathOut) {
            return IOSSimSignerError(
                @"The widget module loader could not allocate its prepared path.");
        }
        return NULL;
    }
#endif
}

#if !TARGET_OS_SIMULATOR

enum { IOSSimWidgetMaximumStubSections = 8 };

typedef struct {
    uintptr_t runtimeStart;
    uintptr_t runtimeEnd;
    uint64_t fileStart;
    uint64_t fileEnd;
    uint32_t stride;
} IOSSimWidgetStubSection;

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    uintptr_t textStart;
    uintptr_t textEnd;
    const uint8_t *functionStarts;
    size_t functionStartsSize;
    uint64_t mainEntryOffset;
    IOSSimWidgetStubSection stubSections[IOSSimWidgetMaximumStubSections];
    NSUInteger stubSectionCount;
} IOSSimWidgetLoadedImageLayout;

static BOOL IOSSimWidgetAddSlide(uint64_t address,
                                 intptr_t slide,
                                 uintptr_t *resultOut) {
    if (address > UINTPTR_MAX) return NO;
    uintptr_t value = (uintptr_t)address;
    if (slide >= 0) {
        uintptr_t amount = (uintptr_t)slide;
        if (value > UINTPTR_MAX - amount) return NO;
        value += amount;
    } else {
        uintptr_t amount = (uintptr_t)(-(slide + 1)) + 1;
        if (value < amount) return NO;
        value -= amount;
    }
    if (resultOut) *resultOut = value;
    return YES;
}

static BOOL IOSSimWidgetRuntimeRange(uint64_t address,
                                     uint64_t length,
                                     intptr_t slide,
                                     uintptr_t *startOut,
                                     uintptr_t *endOut) {
    uintptr_t start = 0;
    if (length == 0 || length > UINTPTR_MAX
        || !IOSSimWidgetAddSlide(address, slide, &start)
        || (uintptr_t)length > UINTPTR_MAX - start) return NO;
    if (startOut) *startOut = start;
    if (endOut) *endOut = start + (uintptr_t)length;
    return YES;
}

static BOOL IOSSimWidgetMemoryHasProtection(uintptr_t start,
                                            size_t length,
                                            vm_prot_t required) {
    if (start == 0 || length == 0 || length > UINTPTR_MAX - start) return NO;
    uintptr_t cursor = start;
    uintptr_t end = start + length;
    while (cursor < end) {
        vm_address_t regionAddress = (vm_address_t)cursor;
        vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(
            mach_task_self(), &regionAddress, &regionSize,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object
        );
        if (object != MACH_PORT_NULL) {
            mach_port_deallocate(mach_task_self(), object);
        }
        if (result != KERN_SUCCESS || (uintptr_t)regionAddress > cursor
            || (info.protection & required) != required || regionSize == 0
            || (uintptr_t)regionAddress > UINTPTR_MAX - (uintptr_t)regionSize) {
            return NO;
        }
        uintptr_t regionEnd = (uintptr_t)regionAddress + (uintptr_t)regionSize;
        if (regionEnd <= cursor) return NO;
        cursor = MIN(regionEnd, end);
    }
    return YES;
}

static uintptr_t IOSSimWidgetStrippedCodeAddress(const void *pointer) {
    return (uintptr_t)ptrauth_strip((void *)pointer,
                                    ptrauth_key_function_pointer);
}

static NSError *IOSSimFindLoadedWidgetImage(NSString *path,
                                             const struct mach_header_64 **headerOut,
                                             intptr_t *slideOut) {
    NSString *canonicalPath = IOSSimCanonicalPath(path);
    const struct mach_header_64 *matchedHeader = NULL;
    intptr_t matchedSlide = 0;
    NSUInteger matchCount = 0;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name) continue;
        NSString *imagePath = [NSString stringWithUTF8String:name];
        if (!imagePath.length
            || ![IOSSimCanonicalPath(imagePath) isEqualToString:canonicalPath]) continue;
        const struct mach_header *candidate = _dyld_get_image_header(index);
        if (!candidate) continue;
        matchedHeader = (const struct mach_header_64 *)candidate;
        matchedSlide = _dyld_get_image_vmaddr_slide(index);
        matchCount++;
    }
    if (matchCount != 1 || !matchedHeader) {
        return IOSSimSigningError(241, [NSString stringWithFormat:
            @"dyld reported %lu exact loaded-image matches for the staged widget path %@; one was required.",
            (unsigned long)matchCount, canonicalPath]);
    }
    if (matchedHeader->magic != MH_MAGIC_64
        || matchedHeader->cputype != CPU_TYPE_ARM64
        || (matchedHeader->filetype != MH_DYLIB
            && matchedHeader->filetype != MH_BUNDLE)) {
        return IOSSimSigningError(242,
            @"The exact loaded widget image is not a compatible arm64 dylib or bundle.");
    }
    if (headerOut) *headerOut = matchedHeader;
    if (slideOut) *slideOut = matchedSlide;
    return nil;
}

static NSError *IOSSimBuildLoadedWidgetLayout(
    const struct mach_header_64 *header,
    intptr_t slide,
    IOSSimWidgetLoadedImageLayout *layoutOut
) {
    if (!header || !layoutOut || header->magic != MH_MAGIC_64
        || header->cputype != CPU_TYPE_ARM64
        || header->sizeofcmds > (16U * 1024U * 1024U)) {
        return IOSSimSigningError(243,
            @"The loaded widget has an unsupported or oversized Mach-O header.");
    }
    size_t commandBytes = sizeof(*header) + (size_t)header->sizeofcmds;
    if (commandBytes < sizeof(*header)
        || !IOSSimWidgetMemoryHasProtection((uintptr_t)header, commandBytes,
                                             VM_PROT_READ)) {
        return IOSSimSigningError(244,
            @"The loaded widget's Mach-O commands are not entirely readable.");
    }

    IOSSimWidgetLoadedImageLayout layout = {0};
    layout.header = header;
    layout.slide = slide;
    const struct linkedit_data_command *functionStartsCommand = NULL;
    const struct segment_command_64 *linkeditSegment = NULL;
    uintptr_t textSegmentStart = 0;
    uintptr_t textSegmentEnd = 0;
    NSUInteger textSegmentCount = 0;
    NSUInteger textSectionCount = 0;
    NSUInteger mainCommandCount = 0;

    const uint8_t *commandsStart = (const uint8_t *)(header + 1);
    const uint8_t *commandsEnd = commandsStart + header->sizeofcmds;
    const struct load_command *command = (const struct load_command *)commandsStart;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const uint8_t *address = (const uint8_t *)command;
        if (address > commandsEnd
            || (size_t)(commandsEnd - address) < sizeof(*command)
            || command->cmdsize < sizeof(*command)
            || command->cmdsize > (size_t)(commandsEnd - address)) {
            return IOSSimSigningError(245, [NSString stringWithFormat:
                @"The loaded widget has a malformed load command at index %u.", index]);
        }
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) {
                return IOSSimSigningError(246,
                    @"The loaded widget has a truncated segment command.");
            }
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            size_t availableSections =
                (command->cmdsize - sizeof(*segment)) / sizeof(struct section_64);
            if (segment->nsects > availableSections) {
                return IOSSimSigningError(247,
                    @"The loaded widget has an out-of-range section table.");
            }
            if (strncmp(segment->segname, SEG_LINKEDIT,
                        sizeof(segment->segname)) == 0) {
                if (linkeditSegment) {
                    return IOSSimSigningError(274,
                        @"The loaded widget contains multiple __LINKEDIT segments.");
                }
                linkeditSegment = segment;
            }
            if (strncmp(segment->segname, SEG_TEXT,
                        sizeof(segment->segname)) == 0) {
                if (segment->fileoff != 0 || segment->filesize < commandBytes
                    || !IOSSimWidgetRuntimeRange(segment->vmaddr, segment->vmsize,
                                                  slide, &textSegmentStart,
                                                  &textSegmentEnd)
                    || textSegmentStart != (uintptr_t)header) {
                    return IOSSimSigningError(248,
                        @"The loaded widget's __TEXT segment does not map its Mach-O header at the dyld image base.");
                }
                textSegmentCount++;
            }
            const struct section_64 *sections =
                (const struct section_64 *)(segment + 1);
            for (uint32_t sectionIndex = 0;
                 sectionIndex < segment->nsects; sectionIndex++) {
                const struct section_64 *section = &sections[sectionIndex];
                uintptr_t runtimeStart = 0;
                uintptr_t runtimeEnd = 0;
                if (strncmp(section->segname, SEG_TEXT,
                            sizeof(section->segname)) == 0
                    && strncmp(section->sectname, SECT_TEXT,
                               sizeof(section->sectname)) == 0) {
                    if (!IOSSimWidgetRuntimeRange(section->addr, section->size, slide,
                                                  &runtimeStart, &runtimeEnd)) {
                        return IOSSimSigningError(249,
                            @"The widget's __text section has an invalid runtime range.");
                    }
                    layout.textStart = runtimeStart;
                    layout.textEnd = runtimeEnd;
                    textSectionCount++;
                }
                if ((section->flags & SECTION_TYPE) != S_SYMBOL_STUBS) continue;
                if (layout.stubSectionCount >= IOSSimWidgetMaximumStubSections
                    || section->reserved2 < 8 || (section->reserved2 & 3) != 0
                    || section->size < section->reserved2
                    || section->size % section->reserved2 != 0
                    || section->offset > UINT64_MAX - section->size
                    || !IOSSimWidgetRuntimeRange(section->addr, section->size, slide,
                                                  &runtimeStart, &runtimeEnd)) {
                    return IOSSimSigningError(250,
                        @"The loaded widget has an unsupported symbol-stub section.");
                }
                IOSSimWidgetStubSection *stub =
                    &layout.stubSections[layout.stubSectionCount++];
                if ((runtimeStart & 3) != 0) {
                    return IOSSimSigningError(275,
                        @"A loaded widget symbol-stub section is not instruction-aligned.");
                }
                stub->runtimeStart = runtimeStart;
                stub->runtimeEnd = runtimeEnd;
                stub->fileStart = section->offset;
                stub->fileEnd = section->offset + section->size;
                stub->stride = section->reserved2;
            }
        } else if (command->cmd == LC_FUNCTION_STARTS) {
            if (command->cmdsize < sizeof(struct linkedit_data_command)
                || functionStartsCommand) {
                return IOSSimSigningError(251,
                    @"The loaded widget has an invalid LC_FUNCTION_STARTS command.");
            }
            functionStartsCommand =
                (const struct linkedit_data_command *)command;
        } else if (command->cmd == LC_MAIN) {
            if (command->cmdsize < sizeof(struct entry_point_command)) {
                return IOSSimSigningError(252,
                    @"The loaded widget has a truncated LC_MAIN command.");
            }
            layout.mainEntryOffset =
                ((const struct entry_point_command *)command)->entryoff;
            mainCommandCount++;
        }
        command = (const struct load_command *)(address + command->cmdsize);
    }

    if (textSegmentCount != 1 || textSectionCount != 1
        || textSegmentEnd <= textSegmentStart
        || layout.textStart < textSegmentStart
        || layout.textEnd > textSegmentEnd
        || layout.textEnd <= layout.textStart
        || (layout.textStart & 3) != 0
        || layout.stubSectionCount == 0 || !functionStartsCommand
        || !linkeditSegment || mainCommandCount != 1
        || layout.mainEntryOffset == 0) {
        return IOSSimSigningError(253,
            @"The loaded widget is missing a unique __text, symbol-stub, LC_FUNCTION_STARTS, __LINKEDIT, or LC_MAIN layout component.");
    }
    uint64_t functionOffset = functionStartsCommand->dataoff;
    uint64_t functionSize = functionStartsCommand->datasize;
    if (functionSize == 0 || functionSize > SIZE_MAX
        || functionOffset < linkeditSegment->fileoff
        || functionOffset > UINT64_MAX - functionSize
        || linkeditSegment->fileoff > UINT64_MAX - linkeditSegment->filesize
        || functionOffset + functionSize
            > linkeditSegment->fileoff + linkeditSegment->filesize) {
        return IOSSimSigningError(254,
            @"The widget's LC_FUNCTION_STARTS payload escapes __LINKEDIT.");
    }
    uintptr_t linkeditStart = 0;
    if (!IOSSimWidgetAddSlide(linkeditSegment->vmaddr, slide, &linkeditStart)) {
        return IOSSimSigningError(255,
            @"The loaded widget's __LINKEDIT runtime address overflowed.");
    }
    uint64_t relativeOffset = functionOffset - linkeditSegment->fileoff;
    if (relativeOffset > UINTPTR_MAX - linkeditStart) {
        return IOSSimSigningError(256,
            @"The loaded widget's function-start table address overflowed.");
    }
    layout.functionStarts =
        (const uint8_t *)(linkeditStart + (uintptr_t)relativeOffset);
    layout.functionStartsSize = (size_t)functionSize;
    if (!IOSSimWidgetMemoryHasProtection((uintptr_t)layout.functionStarts,
                                         layout.functionStartsSize,
                                         VM_PROT_READ)
        || !IOSSimWidgetMemoryHasProtection(layout.textStart,
                                            layout.textEnd - layout.textStart,
                                            VM_PROT_READ | VM_PROT_EXECUTE)) {
        return IOSSimSigningError(257,
            @"The loaded widget's code or function-start table has unexpected memory protection.");
    }
    *layoutOut = layout;
    return nil;
}

static BOOL IOSSimWidgetStubBoundTarget(
    const IOSSimWidgetLoadedImageLayout *layout,
    uintptr_t stubAddress,
    void **targetOut
) {
    const IOSSimWidgetStubSection *matched = NULL;
    for (NSUInteger index = 0; index < layout->stubSectionCount; index++) {
        const IOSSimWidgetStubSection *stub = &layout->stubSections[index];
        if (stubAddress >= stub->runtimeStart && stubAddress < stub->runtimeEnd
            && (stubAddress - stub->runtimeStart) % stub->stride == 0
            && stub->runtimeEnd - stubAddress >= 8) {
            matched = stub;
            break;
        }
    }
    if (!matched
        || !IOSSimWidgetMemoryHasProtection(stubAddress, 8,
                                            VM_PROT_READ | VM_PROT_EXECUTE)) return NO;

    const uint32_t *instructions = (const uint32_t *)stubAddress;
    uint32_t pageInstruction = instructions[0];
    uint32_t loadInstruction = instructions[1];
    if ((pageInstruction & 0x9f000000U) != 0x90000000U
        || (loadInstruction & 0xffc00000U) != 0xf9400000U) return NO;
    uint32_t pageRegister = pageInstruction & 0x1fU;
    uint32_t loadRegister = loadInstruction & 0x1fU;
    uint32_t baseRegister = (loadInstruction >> 5) & 0x1fU;
    if (pageRegister != baseRegister || loadRegister != pageRegister) return NO;

    uint64_t immediateBits =
        (((uint64_t)(pageInstruction >> 5) & 0x7ffffULL) << 2)
        | ((pageInstruction >> 29) & 0x3U);
    int64_t pageDelta = (int64_t)(immediateBits << 43) >> 31;
    uintptr_t page = stubAddress & ~(uintptr_t)0xfff;
    uintptr_t slotPage = 0;
    if (pageDelta >= 0) {
        if ((uint64_t)pageDelta > UINTPTR_MAX - page) return NO;
        slotPage = page + (uintptr_t)pageDelta;
    } else {
        uintptr_t magnitude = (uintptr_t)(-(pageDelta + 1)) + 1;
        if (page < magnitude) return NO;
        slotPage = page - magnitude;
    }
    uintptr_t loadOffset = ((loadInstruction >> 10) & 0xfffU) * sizeof(void *);
    if (loadOffset > UINTPTR_MAX - slotPage) return NO;
    uintptr_t slotAddress = slotPage + loadOffset;
    if (!IOSSimWidgetMemoryHasProtection(slotAddress, sizeof(void *),
                                         VM_PROT_READ)) return NO;
    void *boundTarget = __atomic_load_n((void *const *)slotAddress,
                                        __ATOMIC_ACQUIRE);
    if (!boundTarget) return NO;
    if (targetOut) *targetOut = boundTarget;
    return YES;
}

static NSError *IOSSimValidateWidgetLCMainIsExtensionMain(
    const IOSSimWidgetLoadedImageLayout *layout
) {
    uintptr_t mainStub = 0;
    for (NSUInteger index = 0; index < layout->stubSectionCount; index++) {
        const IOSSimWidgetStubSection *stub = &layout->stubSections[index];
        if (layout->mainEntryOffset < stub->fileStart
            || layout->mainEntryOffset >= stub->fileEnd) continue;
        uint64_t delta = layout->mainEntryOffset - stub->fileStart;
        if (delta % stub->stride != 0 || delta > UINTPTR_MAX - stub->runtimeStart) {
            return IOSSimSigningError(258,
                @"The widget's LC_MAIN does not identify a complete symbol stub.");
        }
        if (mainStub != 0) {
            return IOSSimSigningError(259,
                @"The widget's LC_MAIN maps to multiple symbol-stub sections.");
        }
        mainStub = stub->runtimeStart + (uintptr_t)delta;
    }
    if (mainStub == 0) {
        return IOSSimSigningError(260,
            @"The widget's LC_MAIN is not an import stub; invoking it in the host process was refused.");
    }
    void *boundTarget = NULL;
    if (!IOSSimWidgetStubBoundTarget(layout, mainStub, &boundTarget)) {
        return IOSSimSigningError(261,
            @"The widget's LC_MAIN import stub could not be decoded safely.");
    }
    dlerror();
    void *extensionMain = dlsym(RTLD_DEFAULT, "NSExtensionMain");
    const char *symbolError = dlerror();
    if (!extensionMain || symbolError
        || IOSSimWidgetStrippedCodeAddress(boundTarget)
            != IOSSimWidgetStrippedCodeAddress(extensionMain)) {
        return IOSSimSigningError(262,
            @"The widget's LC_MAIN does not resolve exactly to NSExtensionMain; process-takeover entrypoints are never invoked by the compatible renderer.");
    }
    return nil;
}

static BOOL IOSSimDecodeWidgetFunctionDelta(const uint8_t **cursor,
                                            const uint8_t *end,
                                            uint64_t *valueOut) {
    uint64_t value = 0;
    unsigned shift = 0;
    for (unsigned index = 0; index < 10 && *cursor < end; index++) {
        uint8_t byte = *(*cursor)++;
        uint64_t payload = byte & 0x7fU;
        if (shift >= 64 || payload > (UINT64_MAX >> shift)) return NO;
        value |= payload << shift;
        if ((byte & 0x80U) == 0) {
            if (valueOut) *valueOut = value;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

static BOOL IOSSimWidgetBranchTarget(uintptr_t instructionAddress,
                                     uint32_t instruction,
                                     uintptr_t *targetOut) {
    if ((instruction & 0xfc000000U) != 0x94000000U) return NO;
    int64_t immediate = (int64_t)((uint64_t)(instruction & 0x03ffffffU) << 38) >> 38;
    int64_t displacement = immediate * 4;
    uintptr_t target = 0;
    if (displacement >= 0) {
        if ((uint64_t)displacement > UINTPTR_MAX - instructionAddress) return NO;
        target = instructionAddress + (uintptr_t)displacement;
    } else {
        uintptr_t magnitude = (uintptr_t)(-(displacement + 1)) + 1;
        if (instructionAddress < magnitude) return NO;
        target = instructionAddress - magnitude;
    }
    if (targetOut) *targetOut = target;
    return YES;
}

static NSError *IOSSimResolveWidgetBundleEntryThunk(
    const IOSSimWidgetLoadedImageLayout *layout,
    void **entryOut
) {
    NSMutableArray<NSNumber *> *functionStarts = [NSMutableArray array];
    const uint8_t *cursor = layout->functionStarts;
    const uint8_t *end = cursor + layout->functionStartsSize;
    uint64_t cumulativeOffset = 0;
    BOOL terminated = NO;
    while (cursor < end) {
        uint64_t delta = 0;
        if (!IOSSimDecodeWidgetFunctionDelta(&cursor, end, &delta)) {
            return IOSSimSigningError(263,
                @"The widget's LC_FUNCTION_STARTS table contains malformed ULEB128 data.");
        }
        if (delta == 0) {
            terminated = YES;
            break;
        }
        if (cumulativeOffset > UINT64_MAX - delta) {
            return IOSSimSigningError(264,
                @"The widget's function-start offsets overflowed.");
        }
        cumulativeOffset += delta;
        if (cumulativeOffset > UINTPTR_MAX - (uintptr_t)layout->header) {
            return IOSSimSigningError(265,
                @"A widget function-start runtime address overflowed.");
        }
        uintptr_t function = (uintptr_t)layout->header
            + (uintptr_t)cumulativeOffset;
        if (function >= layout->textStart && function < layout->textEnd) {
            [functionStarts addObject:@(function)];
        }
    }
    if (!terminated || functionStarts.count == 0) {
        return IOSSimSigningError(266,
            @"The widget's LC_FUNCTION_STARTS table is empty or unterminated.");
    }

    uintptr_t replacement = IOSSimWidgetStrippedCodeAddress(
        IOSSimWidgetBundleMainReplacementAddress());
    if (replacement == 0) {
        return IOSSimSigningError(267,
            @"The compatible WidgetBundle.main replacement has no callable address.");
    }
    NSMutableSet<NSNumber *> *replacementStubs = [NSMutableSet set];
    for (NSUInteger sectionIndex = 0;
         sectionIndex < layout->stubSectionCount; sectionIndex++) {
        const IOSSimWidgetStubSection *section =
            &layout->stubSections[sectionIndex];
        for (uintptr_t stub = section->runtimeStart;
             stub < section->runtimeEnd; stub += section->stride) {
            void *boundTarget = NULL;
            if (IOSSimWidgetStubBoundTarget(layout, stub, &boundTarget)
                && IOSSimWidgetStrippedCodeAddress(boundTarget) == replacement) {
                [replacementStubs addObject:@(stub)];
            }
        }
    }
    if (replacementStubs.count == 0) {
        return IOSSimSigningError(268,
            @"No image-local import stub was rebound to the compatible WidgetBundle.main replacement.");
    }
    uintptr_t candidate = 0;
    BOOL sawUnmappedCall = NO;
    const uint32_t *instructions = (const uint32_t *)layout->textStart;
    size_t instructionCount =
        (layout->textEnd - layout->textStart) / sizeof(uint32_t);
    for (size_t index = 0; index < instructionCount; index++) {
        uintptr_t callAddress = layout->textStart + index * sizeof(uint32_t);
        uintptr_t stubAddress = 0;
        if (!IOSSimWidgetBranchTarget(callAddress, instructions[index],
                                      &stubAddress)) continue;
        if (![replacementStubs containsObject:@(stubAddress)]) continue;

        uintptr_t containingFunction = 0;
        for (NSNumber *functionNumber in functionStarts) {
            uintptr_t function = functionNumber.unsignedLongLongValue;
            if (function > callAddress) break;
            containingFunction = function;
        }
        if (containingFunction == 0) {
            sawUnmappedCall = YES;
            continue;
        }
        if (candidate != 0 && candidate != containingFunction) {
            return IOSSimSigningError(269,
                @"Multiple hidden functions call the rebound WidgetBundle.main import; selecting one would be unsafe.");
        }
        candidate = containingFunction;
    }
    if (sawUnmappedCall) {
        return IOSSimSigningError(270,
            @"A WidgetBundle.main callsite was not owned by LC_FUNCTION_STARTS.");
    }
    if (candidate == 0) {
        return IOSSimSigningError(271,
            @"No hidden image-local function calls the rebound WidgetBundle.main import.");
    }
    if ((candidate & 3) != 0
        || !IOSSimWidgetMemoryHasProtection(candidate, sizeof(uint32_t),
                                         VM_PROT_READ | VM_PROT_EXECUTE)) {
        return IOSSimSigningError(272,
            @"The resolved WidgetBundle entry thunk is not executable memory.");
    }
    Dl_info candidateImage = {0};
    if (dladdr((const void *)candidate, &candidateImage) == 0
        || candidateImage.dli_fbase != layout->header) {
        return IOSSimSigningError(273,
            @"The resolved WidgetBundle entry thunk escaped the staged dyld image.");
    }
    void *callable = ptrauth_sign_unauthenticated(
        (void *)candidate, ptrauth_key_function_pointer, 0);
    if (entryOut) *entryOut = callable;
    return nil;
}

#endif

/// Loads one prepared widget module into this process and captures its real
/// WidgetBundle value. This must run on the main thread because evaluating the
/// SwiftUI/WidgetKit bundle ABI is MainActor-bound. The hidden Swift entry
/// thunk is called only after image-local interposition; LC_MAIN and
/// NSExtensionMain are inspected but never invoked.
char *IOSSimLoadAndCaptureWidgetRuntimeModule(const char *preparedExecutablePath,
                                              const char *requestIdentifier,
                                              const char *extensionBundleIdentifier) {
#if TARGET_OS_SIMULATOR
    return IOSSimSignerError(
        @"The in-process widget module loader currently supports physical iOS only."
    );
#else
    if (!preparedExecutablePath || !requestIdentifier || !extensionBundleIdentifier) {
        return IOSSimSignerError(@"Widget runtime capture metadata is incomplete.");
    }
    if (!NSThread.isMainThread) {
        return IOSSimSignerError(
            @"Widget runtime loading and WidgetBundle capture must run on the main thread.");
    }
    NSString *path = [NSString stringWithUTF8String:preparedExecutablePath];
    NSString *request = [NSString stringWithUTF8String:requestIdentifier];
    NSString *extensionIdentifier = [NSString stringWithUTF8String:
        extensionBundleIdentifier];
    if (!path.length || !request.length || !extensionIdentifier.length) {
        return IOSSimSignerError(@"Widget runtime capture metadata is not valid UTF-8.");
    }
    path = IOSSimCanonicalPath(path);
    NSURL *executableURL = [NSURL fileURLWithPath:path];
    NSURL *moduleURL = executableURL.URLByDeletingLastPathComponent;
    NSString *moduleName = moduleURL.lastPathComponent;
    BOOL generatedModule = [moduleName hasPrefix:@".IOSSimWidgetModule-"]
        && ![moduleName hasPrefix:IOSSimWidgetModuleStagePrefix]
        && ![moduleName hasPrefix:IOSSimWidgetModuleBackupPrefix]
        && [moduleName hasSuffix:@".appex"];
    if (!generatedModule) {
        return IOSSimSignerError(
            @"The runtime loader refused a path outside an isolated, finalized widget module."
        );
    }
    NSDictionary *moduleInfo = [NSDictionary dictionaryWithContentsOfURL:
        [moduleURL URLByAppendingPathComponent:@"Info.plist"]];
    NSString *declaredExecutable = moduleInfo[@"CFBundleExecutable"];
    NSString *sourceIdentifier = moduleInfo[IOSSimWidgetSourceIdentifierKey];
    if (![declaredExecutable isEqualToString:executableURL.lastPathComponent]
        || ![sourceIdentifier isEqualToString:extensionIdentifier]) {
        return IOSSimSignerError(
            @"The prepared widget module path or source identifier no longer matches its metadata."
        );
    }
    NSError *imageError = IOSSimValidateWidgetModuleImage(path);
    if (imageError) return IOSSimSignerError(imageError.localizedDescription);

    IOSSimInitializeLoadedWidgetModuleRegistry();
    os_unfair_lock_lock(&IOSSimLoadedWidgetModuleLock);
    IOSSimLoadedWidgetModuleRecord *loadedModule =
        IOSSimLoadedWidgetModulesByExecutablePath[path];
    os_unfair_lock_unlock(&IOSSimLoadedWidgetModuleLock);
    if (loadedModule
        && ![loadedModule.sourceIdentifier isEqualToString:extensionIdentifier]) {
        return IOSSimSignerError([NSString stringWithFormat:
            @"The loaded widget module at %@ belongs to '%@', not '%@'. The process-lifetime module cache will not reuse an image under a different extension identity.",
            path, loadedModule.sourceIdentifier ?: @"unknown", extensionIdentifier]);
    }
    void *handle = loadedModule.handle;
    if (!handle) {
        NSError *classIsolationError =
            IOSSimValidateWidgetObjectiveCClassIsolation(moduleURL.path, path);
        if (classIsolationError) {
            NSLog(@"[WidgetModule] Refused %@ before dlopen: %@",
                  extensionIdentifier, classIsolationError.localizedDescription);
            return IOSSimSignerError(classIsolationError.localizedDescription);
        }
        dlerror();
        handle = dlopen(path.fileSystemRepresentation,
                        RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
        if (!handle) {
            const char *detail = dlerror();
            NSString *message = [NSString stringWithFormat:
                @"dyld could not load the signed widget module at %@: %s. Its parent app frameworks must also be present and host-signed.",
                path, detail ?: "unknown loader error"];
            NSLog(@"[WidgetModule] %@", message);
            return IOSSimSignerError(message);
        }
        // Never dlclose a module after Swift metadata or Objective-C classes
        // may have escaped it. The renderer retains the real bundle/provider,
        // so the handle intentionally lives for the remainder of the process.
        IOSSimLoadedWidgetModuleRecord *newModule =
            [IOSSimLoadedWidgetModuleRecord new];
        newModule.handle = handle;
        newModule.executablePath = path;
        newModule.sourceIdentifier = extensionIdentifier;
        os_unfair_lock_lock(&IOSSimLoadedWidgetModuleLock);
        IOSSimLoadedWidgetModuleRecord *winner =
            IOSSimLoadedWidgetModulesByExecutablePath[path];
        if (!winner) {
            IOSSimLoadedWidgetModulesByExecutablePath[path] = newModule;
            winner = newModule;
        }
        os_unfair_lock_unlock(&IOSSimLoadedWidgetModuleLock);
        if (![winner.sourceIdentifier isEqualToString:extensionIdentifier]) {
            return IOSSimSignerError([NSString stringWithFormat:
                @"A concurrent load registered widget module %@ for '%@', not '%@'. The newly acquired dyld reference remains intentionally retained.",
                path, winner.sourceIdentifier ?: @"unknown", extensionIdentifier]);
        }
        handle = winner.handle;
        NSLog(@"[WidgetModule] dyld loaded %@ for source %@.", path,
              extensionIdentifier);
    }

    NSError *defaultsCategoryError =
        IOSSimInitializeLateLoadedWidgetDefaultsCategory(moduleURL.path);
    if (defaultsCategoryError) {
        return IOSSimSignerError(defaultsCategoryError.localizedDescription);
    }

    const struct mach_header_64 *entryHeader = NULL;
    intptr_t entrySlide = 0;
    NSError *loadedImageError = IOSSimFindLoadedWidgetImage(
        path, &entryHeader, &entrySlide);
    if (loadedImageError) {
        return IOSSimSignerError(loadedImageError.localizedDescription);
    }
    IOSSimWidgetLoadedImageLayout entryLayout = {0};
    NSError *layoutError = IOSSimBuildLoadedWidgetLayout(
        entryHeader, entrySlide, &entryLayout);
    if (layoutError) return IOSSimSignerError(layoutError.localizedDescription);

    // App-extension LC_MAIN conventionally names NSExtensionMain. Calling it
    // would take over the host process, so require that exact, decoded import
    // stub only as a safety invariant and deliberately never branch to it.
    NSError *mainSafetyError = IOSSimValidateWidgetLCMainIsExtensionMain(
        &entryLayout);
    if (mainSafetyError) {
        return IOSSimSignerError(mainSafetyError.localizedDescription);
    }

    // `dlopen` has now finished loading the entry image and dependencies. Bind
    // Foundation resource/default lookups only in those guest images before
    // evaluating the hidden entry thunk, WidgetBundle.body, providers, or
    // generated views.
    // Module initializers necessarily ran during dlopen and remain outside the
    // scoped compatibility contract.
    char *environmentError = IOSSimPrepareWidgetGuestEnvironment(
        preparedExecutablePath, extensionBundleIdentifier);
    if (environmentError) return environmentError;
    if (!IOSSimWidgetGuestEnvironmentOwnsImage(
            entryHeader)) {
        return IOSSimSignerError(
            @"The widget guest environment refused the loaded entry image path.");
    }

    char *armError = IOSSimArmWidgetRuntimeCapture(
        entryHeader,
        requestIdentifier, extensionBundleIdentifier, preparedExecutablePath);
    if (armError) return armError;

    void *entryAddress = NULL;
    NSError *entryError = IOSSimResolveWidgetBundleEntryThunk(
        &entryLayout, &entryAddress);
    if (entryError) {
        IOSSimFinishWidgetRuntimeCapture(
            requestIdentifier, entryError.localizedDescription.UTF8String);
        return IOSSimSignerError(entryError.localizedDescription);
    }

    typedef int (*IOSSimWidgetModuleEntry)(void);
    IOSSimWidgetModuleEntry widgetEntry = (IOSSimWidgetModuleEntry)entryAddress;
    NSString *exceptionMessage = nil;
    @try {
        (void)widgetEntry();
    } @catch (NSException *exception) {
        exceptionMessage = [NSString stringWithFormat:
            @"The widget module's hidden WidgetBundle entry thunk raised %@: %@",
            exception.name, exception.reason ?: @"no reason"];
    }
    IOSSimFinishWidgetRuntimeCapture(requestIdentifier,
        exceptionMessage ? exceptionMessage.UTF8String : NULL);
    if (exceptionMessage) {
        NSLog(@"[WidgetModule] Capture failed for %@: %@", extensionIdentifier,
              exceptionMessage);
        return IOSSimSignerError(exceptionMessage);
    }
    NSLog(@"[WidgetModule] Invoked image-local WidgetBundle entry capture for %@ (%@).",
          extensionIdentifier, request);
    return NULL;
#endif
}

/// Signs the guest bundle and the global tweak tree with iOSSim's bundle ID.
/// The guest's Info.plist identifier is intentionally not changed; only each
/// Mach-O CodeDirectory identifier is made equal to the host identifier, which
/// is the JIT-less library-validation contract used by LiveContainer.
char *IOSSimSignGuestForJITLess(const char *appBundlePath,
                               const char *tweaksPath) {
    if (!IOSSimJITLessSigningConfigured()) {
        return IOSSimSignerError(@"No JIT-less signing identity is configured.");
    }
    if (!appBundlePath) return IOSSimSignerError(@"The guest bundle path is missing.");

    NSError *loadError = nil;
    Class signerClass = IOSSimLoadZSigner(&loadError);
    if (!signerClass) return IOSSimSignerError(loadError.localizedDescription);

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *certificate = [defaults dataForKey:IOSSimCertificateDataKey];
    NSString *password = [defaults stringForKey:IOSSimCertificatePasswordKey] ?: @"";
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleIdentifier.length) return IOSSimSignerError(@"VibeContainers has no bundle identifier.");

    NSString *appPath = [NSString stringWithUTF8String:appBundlePath];
    NSError *signingError = IOSSimSignTree(signerClass, appPath, bundleIdentifier,
                                           certificate, password);
    if (signingError) return IOSSimSignerError(signingError.localizedDescription);

    if (tweaksPath) {
        NSString *tweakRoot = [NSString stringWithUTF8String:tweaksPath];
        signingError = IOSSimSignTree(signerClass, tweakRoot, bundleIdentifier,
                                      certificate, password);
        if (signingError) return IOSSimSignerError(signingError.localizedDescription);
    }

    return NULL;
}

/// Non-signing preflight used when a widget first becomes visible. The source
/// .appex is treated as immutable. On device, only the isolated provisioned
/// runner is repaired, kernel-checked, re-registered, and matched to its exact
/// LaunchServices record.
char *IOSSimPreflightWidgetExtensionForHosting(const char *appBundlePath,
                                               const char *extensionBundlePath) {
    @synchronized (IOSSimWidgetRunnerLock()) {
    if (!appBundlePath || !extensionBundlePath) {
        return IOSSimSignerError(@"The widget app or extension path is missing.");
    }
    NSString *appPath = [NSString stringWithUTF8String:appBundlePath];
    NSString *extensionPath = [NSString stringWithUTF8String:extensionBundlePath];
    if (!appPath.length || !extensionPath.length) {
        return IOSSimSignerError(@"The widget app or extension path is not valid UTF-8.");
    }

    NSError *validationError = IOSSimValidateWidgetBundle(appPath, extensionPath);
    if (validationError) return IOSSimSignerError(validationError.localizedDescription);

#if TARGET_OS_SIMULATOR
    NSDictionary *info = IOSSimWidgetInfo(extensionPath);
    NSError *modeError = IOSSimMakeExecutable(
        [extensionPath stringByAppendingPathComponent:info[@"CFBundleExecutable"]],
        @"simulator widget binary");
    if (modeError) return IOSSimSignerError(modeError.localizedDescription);
#else
    if (!IOSSimJITLessSigningConfigured()) {
        return IOSSimSignerError(
            @"The widget source is intact, but no matching JIT-less identity is configured for its provisioned runner."
        );
    }
    NSURL *runnerURL = IOSSimWidgetRunnerURL(appPath);
    NSError *runnerError = IOSSimValidatePreparedRunner(appPath, extensionPath,
                                                         runnerURL, YES);
    if (runnerError) {
        return IOSSimSignerError([@"SIGNING_REQUIRED:" stringByAppendingString:
            runnerError.localizedDescription]);
    }
#endif
    return NULL;
    }
}

/// Atomically stages an immutable copy of the source widget under a dedicated
/// profile-backed runner identity. Nested code is signed first, the resource
/// seal and provisioned main executable are signed last, and activation is
/// rolled back unless PlugInKit resolves the exact final bundle URL.
char *IOSSimPrepareWidgetExtensionForHosting(const char *appBundlePath,
                                             const char *extensionBundlePath) {
    @synchronized (IOSSimWidgetRunnerLock()) {
    if (!appBundlePath || !extensionBundlePath) {
        return IOSSimSignerError(@"The widget app or extension path is missing.");
    }

    NSString *appPath = [NSString stringWithUTF8String:appBundlePath];
    NSString *extensionPath = [NSString stringWithUTF8String:extensionBundlePath];
    if (!appPath.length || !extensionPath.length) {
        return IOSSimSignerError(@"The widget app or extension path is not valid UTF-8.");
    }

    NSError *validationError = IOSSimValidateWidgetBundle(appPath, extensionPath);
    if (validationError) return IOSSimSignerError(validationError.localizedDescription);

#if TARGET_OS_SIMULATOR
    NSDictionary *info = IOSSimWidgetInfo(extensionPath);
    NSError *modeError = IOSSimMakeExecutable(
        [extensionPath stringByAppendingPathComponent:info[@"CFBundleExecutable"]],
        @"simulator widget binary");
    if (modeError) return IOSSimSignerError(modeError.localizedDescription);
#else
    if (!IOSSimJITLessSigningConfigured()) {
        return IOSSimSignerError(
            @"The widget source is intact, but no matching JIT-less signing identity is configured. Import the development identity used to install VibeContainers."
        );
    }

    NSURL *existingRunnerURL = IOSSimWidgetRunnerURL(appPath);
    NSError *existingRunnerError = IOSSimValidatePreparedRunner(
        appPath, extensionPath, existingRunnerURL, YES);
    if (!existingRunnerError) {
        NSLog(@"[WidgetRunner] Reusing registered %@ for source %@ at %@",
              IOSSimWidgetRunnerBundleIdentifier,
              IOSSimWidgetInfo(extensionPath)[@"CFBundleIdentifier"] ?: @"unknown",
              existingRunnerURL.path);
        return NULL;
    }
    NSLog(@"[WidgetRunner] Existing runner requires replacement (code %ld): %@",
          (long)existingRunnerError.code, existingRunnerError.localizedDescription);

    NSError *loadError = nil;
    Class signerClass = IOSSimLoadZSigner(&loadError);
    if (!signerClass) return IOSSimSignerError(loadError.localizedDescription);

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *certificate = [defaults dataForKey:IOSSimCertificateDataKey];
    NSString *password = [defaults stringForKey:IOSSimCertificatePasswordKey] ?: @"";
    if (!NSBundle.mainBundle.bundleIdentifier.length) {
        return IOSSimSignerError(@"VibeContainers has no bundle identifier for widget signing.");
    }

    NSURL *runnerURL = nil;
    NSError *stageError = IOSSimStageWidgetRunner(signerClass, appPath, extensionPath,
                                                   certificate, password, &runnerURL);
    if (stageError) {
        NSLog(@"[WidgetRunner] Prepare failed while staging %@ (code %ld): %@",
              IOSSimWidgetInfo(extensionPath)[@"CFBundleIdentifier"] ?: extensionPath,
              (long)stageError.code, stageError.localizedDescription);
        return IOSSimSignerError(stageError.localizedDescription);
    }
    NSError *runnerError = IOSSimValidatePreparedRunner(appPath, extensionPath,
                                                         runnerURL, YES);
    if (runnerError) {
        NSLog(@"[WidgetRunner] Prepared runner validation failed at %@ (code %ld): %@",
              runnerURL.path, (long)runnerError.code, runnerError.localizedDescription);
        return IOSSimSignerError(runnerError.localizedDescription);
    }
    NSLog(@"[WidgetRunner] Prepared and registered %@ for source %@ at %@",
          IOSSimWidgetRunnerBundleIdentifier,
          IOSSimWidgetInfo(extensionPath)[@"CFBundleIdentifier"] ?: @"unknown",
          runnerURL.path);
#endif
    return NULL;
    }
}
