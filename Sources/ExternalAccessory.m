#import "ExternalAccessory.h"
#import <objc/message.h>
#import <objc/runtime.h>

// iOS 27 only offers a UIWindowSceneSessionRoleExternalDisplayNonInteractive scene
// after a scene accessory is registered, and only for apps built with the iOS 27
// SDK. The symbols are not in the iOS 26 SDK, so this file looks them up at
// runtime. On iOS 26 (and on iOS 27 when this app was built with an older SDK)
// the Info.plist scene manifest is enough and this returns NO.

static id VPAccessoryRegistration = nil;

BOOL VPRegisterExternalSceneAccessory(UIViewController *vc, Class sceneDelegateClass) {
    if (vc == nil || sceneDelegateClass == nil) return NO;

    Class accClass = NSClassFromString(@"UISceneAccessory");
    if (accClass == Nil) return NO;

    UISceneConfiguration *configuration = [[UISceneConfiguration alloc]
        initWithName:@"External"
        sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
    configuration.delegateClass = sceneDelegateClass;

    // Swift: UISceneAccessory.externalNonInteractive(sceneConfiguration:)
    SEL makeSel = nil;
    for (NSString *name in @[
             @"externalNonInteractiveAccessoryWithSceneConfiguration:",
             @"externalNonInteractiveWithSceneConfiguration:"
         ]) {
        SEL s = NSSelectorFromString(name);
        if ([accClass respondsToSelector:s]) { makeSel = s; break; }
    }
    if (makeSel == nil) return NO;

    id accessory = ((id (*)(id, SEL, id))objc_msgSend)((id)accClass, makeSel, configuration);
    if (accessory == nil) return NO;

    SEL regSel = NSSelectorFromString(@"registerSceneAccessory:");
    if (![vc respondsToSelector:regSel]) return NO;
    id registration = ((id (*)(id, SEL, id))objc_msgSend)(vc, regSel, accessory);
    if (registration == nil) return NO;

    SEL setEnabled = NSSelectorFromString(@"setIsEnabled:");
    if ([registration respondsToSelector:setEnabled]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(registration, setEnabled, YES);
    }
    VPAccessoryRegistration = registration;
    return YES;
}
