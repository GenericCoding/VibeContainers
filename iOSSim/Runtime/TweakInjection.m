#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <string.h>
#import "../../LiveContainer-3.8.0/LiveContainer/LCMachOUtils.h"

/// Adds and removes `LC_LOAD_DYLIB` commands on a prepared guest executable —
/// the dyld half of LiveContainer's tweak support, ported to iOSSim.
///
/// Upstream injects exactly one dylib, its own `TweakLoader.dylib`, and lets
/// that dlopen everything in the tweak folder at runtime. iOSSim has no
/// TweakLoader to build against, so it names each tweak in the executable
/// itself and leaves the loading to dyld. The command upstream writes is
/// reproduced exactly — same load path convention, same reserved-slot number —
/// so a bundle patched here still parses as one LiveContainer prepared.
///
/// The load path is always `@loader_path/../../Tweaks/<name>`, resolved against
/// the *guest* executable rather than iOSSim's own: the guest is dlopen'd, so
/// `@executable_path` would point at the host binary.

/// LiveContainer parks load commands it wants dyld to skip under this command
/// number. It has no `LC_REQ_DYLD` bit set, so dyld ignores the command instead
/// of refusing the image — which is what lets a tweak be switched off without
/// giving its load-command slot back.
#define LC_IOSSIM_DISABLED 0x114514

static uint32_t IOSSimRoundUp8(uint32_t value) { return (value + 7) & ~7u; }

/// The file offset of `__TEXT,__text`, which is where the free space after the
/// load commands ends. Offsets are relative to the slice, not the fat file.
static uint32_t IOSSimTextSectionOffset(struct mach_header_64 *header) {
    struct load_command *command = (struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)command;
            if (strcmp(segment->segname, "__TEXT") == 0) {
                struct section_64 *section =
                    (struct section_64 *)((uint8_t *)command + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < segment->nsects; j++) {
                    if (strcmp(section[j].sectname, "__text") == 0) {
                        return section[j].offset;
                    }
                }
            }
        }
        if (command->cmdsize == 0) break;
        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }
    return 0;
}

/// An existing dylib command naming `path`, enabled or disabled.
static struct dylib_command *IOSSimFindDylibCommand(struct mach_header_64 *header, const char *path) {
    struct load_command *command = (struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_IOSSIM_DISABLED) {
            struct dylib_command *dylib = (struct dylib_command *)command;
            if (dylib->dylib.name.offset < dylib->cmdsize) {
                const char *name = (const char *)dylib + dylib->dylib.name.offset;
                if (strcmp(name, path) == 0) return dylib;
            }
        }
        if (command->cmdsize == 0) break;
        command = (struct load_command *)((uint8_t *)command + command->cmdsize);
    }
    return NULL;
}

/// Appends a dylib command after the last one, in the padding that the linker
/// leaves between the load commands and `__text`.
///
/// Unlike upstream this never widens a command that is already in place: the
/// reserved slot LiveContainer leaves behind is sized for its own path, and
/// overwriting its name with a longer one would run into whatever follows.
static bool IOSSimAppendDylibCommand(struct mach_header_64 *header, const char *path) {
    uint32_t cmdsize = sizeof(struct dylib_command) + IOSSimRoundUp8((uint32_t)strlen(path) + 1);
    uint32_t used = sizeof(struct mach_header_64) + header->sizeofcmds;
    uint32_t textOffset = IOSSimTextSectionOffset(header);
    if (textOffset == 0 || used + cmdsize > textOffset) return false;

    struct dylib_command *dylib = (struct dylib_command *)((uint8_t *)header + used);
    bzero(dylib, cmdsize);
    dylib->cmd = LC_LOAD_DYLIB;
    dylib->cmdsize = cmdsize;
    dylib->dylib.name.offset = sizeof(struct dylib_command);
    dylib->dylib.timestamp = 2;
    dylib->dylib.current_version = 0x10000;
    dylib->dylib.compatibility_version = 0x10000;
    strcpy((char *)dylib + dylib->dylib.name.offset, path);

    header->ncmds++;
    header->sizeofcmds += cmdsize;
    return true;
}

/// Loads `loadPath` into every arm64 slice of `execPath`. Returns NULL on
/// success, or an error string the caller owns.
char *IOSSimInjectDylib(const char *execPath, const char *loadPath) {
    __block int injected = 0;
    __block int outOfSpace = 0;

    NSString *parseError = LCParseMachO(execPath, false, ^(const char *slicePath,
                                                           struct mach_header_64 *header,
                                                           int fd, void *mapping) {
        if (header->cputype != CPU_TYPE_ARM64) return;

        struct dylib_command *existing = IOSSimFindDylibCommand(header, loadPath);
        if (existing) {
            // Re-enabling costs nothing: the slot and its name are still there.
            existing->cmd = LC_LOAD_DYLIB;
            injected++;
        } else if (IOSSimAppendDylibCommand(header, loadPath)) {
            injected++;
        } else {
            outOfSpace++;
        }
    });

    if (parseError) return strdup(parseError.UTF8String);
    if (outOfSpace) {
        return strdup("No room left between the executable's load commands and its code. "
                      "Turn another tweak off for this app and try again.");
    }
    if (!injected) return strdup("The executable has no arm64 slice to inject into.");
    return NULL;
}

/// Switches the command off rather than deleting it, so the slot stays
/// available and the load commands after it keep their offsets.
char *IOSSimRemoveDylib(const char *execPath, const char *loadPath) {
    NSString *parseError = LCParseMachO(execPath, false, ^(const char *slicePath,
                                                           struct mach_header_64 *header,
                                                           int fd, void *mapping) {
        if (header->cputype != CPU_TYPE_ARM64) return;
        struct dylib_command *existing = IOSSimFindDylibCommand(header, loadPath);
        if (existing) existing->cmd = LC_IOSSIM_DISABLED;
    });

    if (parseError) return strdup(parseError.UTF8String);
    return NULL;
}

/// Every dylib command in the first arm64 slice, one per line, each prefixed
/// with `+` when dyld will load it and `-` when it is parked. Reading the
/// binary back is what keeps the UI honest after a reinstall replaces it.
char *IOSSimCopyInjectedDylibs(const char *execPath) {
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    __block bool inspected = false;

    NSString *parseError = LCParseMachO(execPath, true, ^(const char *slicePath,
                                                          struct mach_header_64 *header,
                                                          int fd, void *mapping) {
        if (header->cputype != CPU_TYPE_ARM64 || inspected) return;
        inspected = true;

        struct load_command *command = (struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_IOSSIM_DISABLED) {
                struct dylib_command *dylib = (struct dylib_command *)command;
                if (dylib->dylib.name.offset < dylib->cmdsize) {
                    const char *name = (const char *)dylib + dylib->dylib.name.offset;
                    [lines addObject:[NSString stringWithFormat:@"%c%s",
                                      command->cmd == LC_LOAD_DYLIB ? '+' : '-', name]];
                }
            }
            if (command->cmdsize == 0) break;
            command = (struct load_command *)((uint8_t *)command + command->cmdsize);
        }
    });

    if (parseError || !inspected) return NULL;
    return strdup([lines componentsJoinedByString:@"\n"].UTF8String);
}
