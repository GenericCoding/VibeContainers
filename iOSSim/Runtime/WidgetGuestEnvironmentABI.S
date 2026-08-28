#include <TargetConditionals.h>

.text
.p2align 2

#if defined(__arm64__) && !TARGET_OS_SIMULATOR

// `litehook` installs this entry point only into Objective-C message-send
// slots owned by the selected guest module and its guest-app dependencies.
// All unrelated selectors tail-call libobjc with the original register file.
// Sensitive handlers receive the untouched guest return address in the first
// otherwise-unused argument register so they can select the owning context.
.globl _IOSSimWidgetGuestObjCMessageSend
_IOSSimWidgetGuestObjCMessageSend:
    adrp x9, _IOSSimWidgetGuestMainBundleSelector@PAGE
    ldr x9, [x9, _IOSSimWidgetGuestMainBundleSelector@PAGEOFF]
    cmp x1, x9
    b.ne 1f
    mov x2, x30
    b _IOSSimWidgetGuestMainBundleMessage
1:

    adrp x9, _IOSSimWidgetGuestStandardDefaultsSelector@PAGE
    ldr x9, [x9, _IOSSimWidgetGuestStandardDefaultsSelector@PAGEOFF]
    cmp x1, x9
    b.ne 2f
    mov x2, x30
    b _IOSSimWidgetGuestStandardDefaultsMessage
2:

    adrp x9, _IOSSimWidgetGuestSuiteDefaultsSelector@PAGE
    ldr x9, [x9, _IOSSimWidgetGuestSuiteDefaultsSelector@PAGEOFF]
    cmp x1, x9
    b.ne 3f
    mov x3, x30
    b _IOSSimWidgetGuestSuiteDefaultsMessage
3:

    adrp x9, _IOSSimWidgetGuestAppGroupSelector@PAGE
    ldr x9, [x9, _IOSSimWidgetGuestAppGroupSelector@PAGEOFF]
    cmp x1, x9
    b.ne 4f
    mov x3, x30
    b _IOSSimWidgetGuestAppGroupMessage
4:

    b _objc_msgSend

// Apple's current linker converts modern Swift/Clang `_objc_msgSend$selector`
// references into local __objc_stubs which load x1 and branch through the one
// generic objc_msgSend GOT slot handled above. Keep dedicated replacements for
// alternate/future final-image layouts that retain selector-specific pointers;
// those entries may arrive without a usable x1 and must synthesize it here.
.p2align 2
.globl _IOSSimWidgetGuestMainBundleSelectorSend
_IOSSimWidgetGuestMainBundleSelectorSend:
    adrp x1, _IOSSimWidgetGuestMainBundleSelector@PAGE
    ldr x1, [x1, _IOSSimWidgetGuestMainBundleSelector@PAGEOFF]
    mov x2, x30
    b _IOSSimWidgetGuestMainBundleMessage

.p2align 2
.globl _IOSSimWidgetGuestStandardDefaultsSelectorSend
_IOSSimWidgetGuestStandardDefaultsSelectorSend:
    adrp x1, _IOSSimWidgetGuestStandardDefaultsSelector@PAGE
    ldr x1, [x1, _IOSSimWidgetGuestStandardDefaultsSelector@PAGEOFF]
    mov x2, x30
    b _IOSSimWidgetGuestStandardDefaultsMessage

.p2align 2
.globl _IOSSimWidgetGuestSuiteDefaultsSelectorSend
_IOSSimWidgetGuestSuiteDefaultsSelectorSend:
    adrp x1, _IOSSimWidgetGuestSuiteDefaultsSelector@PAGE
    ldr x1, [x1, _IOSSimWidgetGuestSuiteDefaultsSelector@PAGEOFF]
    mov x3, x30
    b _IOSSimWidgetGuestSuiteDefaultsMessage

.p2align 2
.globl _IOSSimWidgetGuestAppGroupSelectorSend
_IOSSimWidgetGuestAppGroupSelectorSend:
    adrp x1, _IOSSimWidgetGuestAppGroupSelector@PAGE
    ldr x1, [x1, _IOSSimWidgetGuestAppGroupSelector@PAGEOFF]
    mov x3, x30
    b _IOSSimWidgetGuestAppGroupMessage

#elif defined(__arm64__)

// Simulator uses the existing platform-routing host and never installs this
// device-only widget-module environment. Keep the symbol linkable.
.globl _IOSSimWidgetGuestObjCMessageSend
_IOSSimWidgetGuestObjCMessageSend:
    b _objc_msgSend

.globl _IOSSimWidgetGuestMainBundleSelectorSend
_IOSSimWidgetGuestMainBundleSelectorSend:
    b _objc_msgSend
.globl _IOSSimWidgetGuestStandardDefaultsSelectorSend
_IOSSimWidgetGuestStandardDefaultsSelectorSend:
    b _objc_msgSend
.globl _IOSSimWidgetGuestSuiteDefaultsSelectorSend
_IOSSimWidgetGuestSuiteDefaultsSelectorSend:
    b _objc_msgSend
.globl _IOSSimWidgetGuestAppGroupSelectorSend
_IOSSimWidgetGuestAppGroupSelectorSend:
    b _objc_msgSend

#elif defined(__x86_64__)

.globl _IOSSimWidgetGuestObjCMessageSend
_IOSSimWidgetGuestObjCMessageSend:
    jmp _objc_msgSend

.globl _IOSSimWidgetGuestMainBundleSelectorSend
_IOSSimWidgetGuestMainBundleSelectorSend:
    jmp _objc_msgSend
.globl _IOSSimWidgetGuestStandardDefaultsSelectorSend
_IOSSimWidgetGuestStandardDefaultsSelectorSend:
    jmp _objc_msgSend
.globl _IOSSimWidgetGuestSuiteDefaultsSelectorSend
_IOSSimWidgetGuestSuiteDefaultsSelectorSend:
    jmp _objc_msgSend
.globl _IOSSimWidgetGuestAppGroupSelectorSend
_IOSSimWidgetGuestAppGroupSelectorSend:
    jmp _objc_msgSend

#endif
