/* 最小 substrate 头：只声明 Logos 生成的代码会调到的符号。
   theos 的 vendor/include/substrate.h 会 include CydiaSubstrate 头，CI 里不全，索性自带一份。 */
#ifndef VCAM_SUBSTRATE_H
#define VCAM_SUBSTRATE_H

#include <objc/runtime.h>
#include <objc/message.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);
void MSHookFunction(void *symbol, void *replace, void **result);
void *MSFindSymbol(void *image, const char *name);
void *MSGetImageByName(const char *path);

#ifdef __cplusplus
}
#endif

#endif
