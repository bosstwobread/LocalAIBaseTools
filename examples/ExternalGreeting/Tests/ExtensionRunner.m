#import "MacHelperExtensionSDK.h"

// The runner's context keeps every setting in the temporary fixture directory.
@interface FixtureContext : NSObject <MacHelperExtensionContext>
@property(nonatomic, copy) NSString *helperExecutablePath;
@property(nonatomic, copy) NSString *settingsDirectory;
@property(nonatomic, copy) NSString *hostVersion;
@property(nonatomic) NSUInteger aiSettingsRequests;
@property(nonatomic) NSUInteger hideSettingsRequests;
@end
@implementation FixtureContext
- (void)openAISettings { self.aiSettingsRequests += 1; }
- (void)hideSettings { self.hideSettingsRequests += 1; }
@end

// These methods belong to this example, not the public extension protocol.
@protocol GreetingFixtureControls
@property(nonatomic, readonly) NSUInteger greetingCount;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
- (BOOL)recordGreeting:(NSError **)error;
@end

static void require(BOOL value, NSString *message) {
    if (!value) { [NSException raise:@"FixtureFailure" format:@"%@", message]; }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { return 2; }
        @try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
            NSError *error = nil;
            require(bundle && [bundle loadAndReturnError:&error], error.localizedDescription ?: @"Bundle could not load.");
            Class principal = bundle.principalClass;
            require(principal && [principal conformsToProtocol:@protocol(MacHelperExtension)], @"Principal does not implement the SDK protocol.");
            id<MacHelperExtension> extension = [principal makeExtension];
            id<GreetingFixtureControls> greeting = (id<GreetingFixtureControls>)extension;
            require(!greeting.isRunning, @"Factory unexpectedly started the extension.");

            FixtureContext *context = [[FixtureContext alloc] init];
            context.helperExecutablePath = @"/not-used-by-this-example/mac-helper-host";
            context.settingsDirectory = [NSString stringWithUTF8String:argv[2]];
            context.hostVersion = @"fixture-host-v1";
            [extension startWithContext:context];
            require(greeting.isRunning && greeting.greetingCount == 0, @"Start did not initialize isolated settings.");
            NSViewController *settings = [extension makeSettingsViewController];
            require(settings != nil && settings.view != nil, @"The extension did not provide an embeddable settings view.");

            // Invoke the example's business action on its offscreen controller;
            // no event is synthesized and no external app or UI is controlled.
            [settings performSelector:NSSelectorFromString(@"addGreeting:") withObject:nil];
            require(greeting.greetingCount == 1, @"The settings action did not update the extension.");
            [settings performSelector:NSSelectorFromString(@"openAISettings:") withObject:nil];
            require(context.aiSettingsRequests == 1, @"The context callback was not routed to the host.");
            [extension stop];
            require(!greeting.isRunning, @"Stop did not release the running state.");
            require(![greeting recordGreeting:&error], @"A stopped extension still accepts work.");
            [extension startWithContext:context];
            require(greeting.greetingCount == 1, @"Preferences did not survive stop/start.");
            [extension stop];
            puts("{\"factory\":true,\"lifecycle\":true,\"settingsView\":true,\"persistence\":true,\"hostCallback\":true}");
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "External extension test failed: %s\n", exception.reason.UTF8String);
            return 1;
        }
    }
}
