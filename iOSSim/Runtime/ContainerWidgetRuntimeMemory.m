#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

bool VibeWidgetRuntimeReadableMemory(const void *pointer, size_t length) {
    if (!pointer || length == 0) return false;

    vm_address_t regionAddress = (vm_address_t)pointer;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(
        mach_task_self(), &regionAddress, &regionSize, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object
    );
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || !(info.protection & VM_PROT_READ)) return false;

    vm_address_t value = (vm_address_t)pointer;
    vm_address_t end = value + length;
    vm_address_t regionEnd = regionAddress + regionSize;
    return end >= value && regionEnd >= regionAddress
        && value >= regionAddress && end <= regionEnd;
}

bool VibeWidgetRuntimeExecutableAddress(const void *pointer) {
    if (!pointer) return false;

    Dl_info image = {0};
    if (dladdr(pointer, &image) == 0 || !image.dli_fbase) return false;

    vm_address_t regionAddress = (vm_address_t)pointer;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(
        mach_task_self(), &regionAddress, &regionSize, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object
    );
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result == KERN_SUCCESS && (info.protection & VM_PROT_EXECUTE)) {
        return true;
    }

    // iOS 27 can report the dyld shared cache as one coarse read-only VM
    // region even though its individual Mach-O __TEXT_EXEC segments are
    // executable. Validate the address against the loaded image's own segment
    // map instead of weakening the gate for every shared-cache address.
    const struct mach_header_64 *header = image.dli_fbase;
    if (!VibeWidgetRuntimeReadableMemory(header, sizeof(*header))
        || header->magic != MH_MAGIC_64
        || header->ncmds == 0
        || header->ncmds > 16 * 1024
        || header->sizeofcmds > 64 * 1024 * 1024) return false;
    const uint8_t *commands = (const uint8_t *)(header + 1);
    if (!VibeWidgetRuntimeReadableMemory(commands, header->sizeofcmds)) return false;
    const uint8_t *commandsEnd = commands + header->sizeofcmds;

    intptr_t imageSlide = 0;
    bool foundImage = false;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        if (_dyld_get_image_header(index) == (const struct mach_header *)header) {
            imageSlide = _dyld_get_image_vmaddr_slide(index);
            foundImage = true;
            break;
        }
    }
    if (!foundImage) {
        NSLog(@"[WidgetRuntime] dyld did not publish a VM slide for %p in %s.",
              pointer, image.dli_fname ?: "unknown");
        return false;
    }

    uintptr_t target = (uintptr_t)pointer;
    const struct load_command *command = (const struct load_command *)commands;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const uint8_t *address = (const uint8_t *)command;
        if (address > commandsEnd
            || (uint64_t)(commandsEnd - address) < sizeof(*command)
            || command->cmdsize < sizeof(*command)
            || command->cmdsize > (uint64_t)(commandsEnd - address)) return false;
        if (command->cmd == LC_SEGMENT_64
            && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if ((segment->initprot & VM_PROT_EXECUTE) && segment->vmsize != 0) {
                __int128 runtimeStart = (__int128)segment->vmaddr
                    + (__int128)imageSlide;
                __int128 runtimeEnd = runtimeStart + (__int128)segment->vmsize;
                if (runtimeStart >= 0 && runtimeEnd > runtimeStart
                    && runtimeEnd <= (__int128)UINTPTR_MAX
                    && (__int128)target >= runtimeStart
                    && (__int128)target < runtimeEnd) return true;
            }
        }
        command = (const struct load_command *)(address + command->cmdsize);
    }
    NSLog(@"[WidgetRuntime] Loaded-image executable segments rejected %p in %s "
          "(slide=%lld).",
          pointer,
          image.dli_fname ?: "unknown",
          (long long)imageSlide);
    return false;
}

bool VibeWidgetRuntimeSymbolAvailable(const char *symbol) {
    if (!symbol || !symbol[0]) return false;
    dlerror();
    void *address = dlsym(RTLD_DEFAULT, symbol);
    const char *error = dlerror();
    return address != NULL && error == NULL;
}
