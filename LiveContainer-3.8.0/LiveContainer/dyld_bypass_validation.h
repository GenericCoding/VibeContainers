// Based on: https://blog.xpnsec.com/restoring-dyld-memory-loading
// https://github.com/xpn/DyldDeNeuralyzer/blob/main/DyldDeNeuralyzer/DyldPatch/dyldpatch.m

#define ASM(...) __asm__(#__VA_ARGS__)

// Signatures to search for
static const char mmapSig[] = {0xB0, 0x18, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const char fcntlSig[] = {0x90, 0x0B, 0x80, 0xD2, 0x01, 0x10, 0x00, 0xD4};
static const char syscallSig[] = {0x01, 0x10, 0x00, 0xD4};
int (*orig_dyld_fcntl)(int fildes, int cmd, void *param);
int (*orig_dyld_mmap)(int fildes, int cmd, void *param);

extern void* __mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset);
extern int __fcntl(int fildes, int cmd, void* param);

void searchDyldFunctions(void);
char *searchDyldFunction(char *base, char *signature, int length);
