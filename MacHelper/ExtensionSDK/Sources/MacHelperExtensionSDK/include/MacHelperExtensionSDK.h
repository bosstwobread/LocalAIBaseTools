#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The version-one interface deliberately uses Objective-C/Foundation/AppKit
/// types, so an extension does not depend on MacHelper's private Swift ABI.
@protocol MacHelperExtensionContext <NSObject>
@property(nonatomic, readonly, copy) NSString *helperExecutablePath;
@property(nonatomic, readonly, copy) NSString *settingsDirectory;
@property(nonatomic, readonly, copy) NSString *hostVersion;
- (void)openAISettings;
- (void)hideSettings;
@end

@protocol MacHelperExtension <NSObject>
+ (id<MacHelperExtension>)makeExtension NS_SWIFT_NAME(makeExtension());
- (void)startWithContext:(id<MacHelperExtensionContext>)context NS_SWIFT_NAME(start(context:));
- (void)stop;
- (NSViewController *)makeSettingsViewController NS_SWIFT_NAME(makeSettingsViewController());
@end

NS_ASSUME_NONNULL_END
