#include <TargetConditionals.h>

.text
.p2align 2

#if defined(__arm64__) && !TARGET_OS_SIMULATOR

// These are private SwiftUI entry points. Mark them weak so older systems can
// launch VibeContainers and take the public/Chrono fallback without dyld
// requiring this ABI at process start.
.weak_reference "_$s7SwiftUI16WidgetBundleHostCN"
.weak_reference "_$s7SwiftUI16WidgetBundleHostC6bundleACx_tcAA0cD0RzlufC"
.weak_reference "_$s7SwiftUI16WidgetBundleHostC14readPreferencey5ValueQzxmAA0G3KeyRzlF"
.weak_reference "_$s7SwiftUI4ViewMp"
.weak_reference "_$s7SwiftUI7AnyViewVyACxcAA0D0RzlufC"

.globl _VibeWidgetBundleHostCreate
_VibeWidgetBundleHostCreate:
    sub sp, sp, #64
    stp x29, x30, [sp, #48]
    add x29, sp, #48
    str x20, [sp, #40]
    stp x0, x1, [sp, #0]
    str x2, [sp, #16]

    // WidgetBundleHost's allocating initializer expects the class metadata
    // base in x20 in addition to the generic bundle value/type/witness words.
    adrp x20, "_$s7SwiftUI16WidgetBundleHostCN"@GOTPAGE
    ldr x20, [x20, "_$s7SwiftUI16WidgetBundleHostCN"@GOTPAGEOFF]
    ldp x0, x1, [sp, #0]
    ldr x2, [sp, #16]
    bl "_$s7SwiftUI16WidgetBundleHostC6bundleACx_tcAA0cD0RzlufC"

    mov x9, x0
    ldr x20, [sp, #40]
    mov x0, x9
    ldp x29, x30, [sp, #48]
    add sp, sp, #64
    ret

.p2align 2
.globl _VibeWidgetBundleHostReadPreference
_VibeWidgetBundleHostReadPreference:
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    add x29, sp, #16
    str x20, [sp, #8]

    // Swift calls this shim with host/key metatype/key metadata/key witness in
    // x0...x3 and the generic result buffer in x8. The instance method uses
    // x20=self, x0=key metatype, x1=key metadata, x2=key witness.
    mov x20, x0
    mov x2, x3
    mov x0, x1
    bl "_$s7SwiftUI16WidgetBundleHostC14readPreferencey5ValueQzxmAA0G3KeyRzlF"

    ldr x20, [sp, #8]
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret

.p2align 2
.globl _VibeInvokeOneArgViewClosure
_VibeInvokeOneArgViewClosure:
    sub sp, sp, #48
    stp x29, x30, [sp, #32]
    add x29, sp, #32
    stp x20, x19, [sp, #16]

    mov x19, x0
    mov x8, x3
    mov x20, x1
    mov x0, x2
    blr x19

    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp, #32]
    add sp, sp, #48
    ret

.p2align 2
.globl _VibeViewWitness
_VibeViewWitness:
    adrp x1, "_$s7SwiftUI4ViewMp"@GOTPAGE
    ldr x1, [x1, "_$s7SwiftUI4ViewMp"@GOTPAGEOFF]
    b _swift_conformsToProtocol

.p2align 2
.globl _VibeMakeAnyView
_VibeMakeAnyView:
    b "_$s7SwiftUI7AnyViewVyACxcAA0D0RzlufC"

.p2align 2
.globl _VibeWidgetRuntimeInstructionPointerIsUnsigned
_VibeWidgetRuntimeInstructionPointerIsUnsigned:
    // This target and the staged guest slice both use the arm64 ABI, whose
    // compiler-generated thick-closure calls use plain BLR. Loaded-image
    // executable-segment validation rejects data pointers before this returns true.
    mov w0, #1
    ret

.p2align 2
.globl _VibeWidgetRuntimeStripInstructionPointer
_VibeWidgetRuntimeStripInstructionPointer:
    // Guest Swift closure contexts can carry an authenticated code pointer on
    // arm64e hardware even when this compatibility shim is an arm64 image.
    // The shim invokes it with plain BLR, so canonicalize the address first.
    // `xpaci x0` encoded directly so this arm64 compatibility object does not
    // advertise an arm64e deployment requirement to the linker.
    .long 0xdac143e0
    ret

#elif defined(__arm64__)

// Linkable stubs for Simulator and non-arm64 builds. The Swift gate rejects
// these platforms before any value-returning ABI shim can be called.
.globl _VibeWidgetBundleHostCreate
_VibeWidgetBundleHostCreate:
    mov x0, #0
    ret

.globl _VibeWidgetBundleHostReadPreference
_VibeWidgetBundleHostReadPreference:
    ret

.globl _VibeInvokeOneArgViewClosure
_VibeInvokeOneArgViewClosure:
    ret

.globl _VibeViewWitness
_VibeViewWitness:
    mov x0, #0
    ret

.globl _VibeMakeAnyView
_VibeMakeAnyView:
    ret

.globl _VibeWidgetRuntimeInstructionPointerIsUnsigned
_VibeWidgetRuntimeInstructionPointerIsUnsigned:
    mov w0, #0
    ret

.globl _VibeWidgetRuntimeStripInstructionPointer
_VibeWidgetRuntimeStripInstructionPointer:
    ret

#elif defined(__x86_64__)

.globl _VibeWidgetBundleHostCreate
_VibeWidgetBundleHostCreate:
    xorl %eax, %eax
    retq

.globl _VibeWidgetBundleHostReadPreference
_VibeWidgetBundleHostReadPreference:
    retq

.globl _VibeInvokeOneArgViewClosure
_VibeInvokeOneArgViewClosure:
    retq

.globl _VibeViewWitness
_VibeViewWitness:
    xorl %eax, %eax
    retq

.globl _VibeMakeAnyView
_VibeMakeAnyView:
    retq

.globl _VibeWidgetRuntimeInstructionPointerIsUnsigned
_VibeWidgetRuntimeInstructionPointerIsUnsigned:
    xorl %eax, %eax
    retq

.globl _VibeWidgetRuntimeStripInstructionPointer
_VibeWidgetRuntimeStripInstructionPointer:
    movq %rdi, %rax
    retq

#endif
