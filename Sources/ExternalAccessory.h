#import <UIKit/UIKit.h>

/// Registers a non-interactive external-display scene accessory on `vc` (iOS 27+).
/// Returns YES when the system accepted the registration. The registration is kept
/// for the lifetime of the process (or until a later call replaces it).
#ifdef __cplusplus
extern "C" {
#endif
BOOL VPRegisterExternalSceneAccessory(UIViewController *vc, Class sceneDelegateClass);
#ifdef __cplusplus
}
#endif
