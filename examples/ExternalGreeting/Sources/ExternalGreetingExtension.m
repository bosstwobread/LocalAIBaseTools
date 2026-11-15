#import "MacHelperExtensionSDK.h"

@class ExternalGreetingSettingsController;

@interface ExternalGreetingExtension : NSObject <MacHelperExtension>
@property(nonatomic, strong, nullable) id<MacHelperExtensionContext> context;
@property(nonatomic, readonly) NSUInteger greetingCount;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
- (BOOL)recordGreeting:(NSError **)error;
@end

@interface ExternalGreetingSettingsController : NSViewController
@property(nonatomic, weak) ExternalGreetingExtension *extension;
@property(nonatomic, strong) NSTextField *countLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@end

@implementation ExternalGreetingExtension {
    NSUInteger _greetingCount;
    BOOL _running;
}

+ (id<MacHelperExtension>)makeExtension { return [[self alloc] init]; }

- (void)startWithContext:(id<MacHelperExtensionContext>)context {
    if (_running) { return; }
    self.context = context;
    NSString *file = [context.settingsDirectory stringByAppendingPathComponent:@"greeting.json"];
    NSData *data = [NSData dataWithContentsOfFile:file];
    NSDictionary *preferences = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSNumber *count = [preferences isKindOfClass:NSDictionary.class] ? preferences[@"count"] : nil;
    _greetingCount = [count isKindOfClass:NSNumber.class] && count.unsignedLongLongValue <= 1000000
        ? count.unsignedIntegerValue : 0;
    _running = YES;
}

- (void)stop {
    _running = NO;
    self.context = nil;
}

- (NSViewController *)makeSettingsViewController {
    ExternalGreetingSettingsController *controller = [[ExternalGreetingSettingsController alloc] init];
    controller.extension = self;
    return controller;
}

- (NSUInteger)greetingCount { return _greetingCount; }
- (BOOL)isRunning { return _running; }

- (BOOL)recordGreeting:(NSError **)error {
    if (!_running || self.context == nil) {
        if (error) { *error = [NSError errorWithDomain:@"ExternalGreeting" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Enable External Greeting before using it."
        }]; }
        return NO;
    }
    NSUInteger nextCount = MIN(_greetingCount + 1, 1000000);
    NSString *directory = self.context.settingsDirectory;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions: @0700} error:error]) { return NO; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"count": @(nextCount)} options:0 error:error];
    NSString *file = [directory stringByAppendingPathComponent:@"greeting.json"];
    if (!data || ![data writeToFile:file options:NSDataWritingAtomic error:error]) { return NO; }
    if (![files setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:file error:error]) { return NO; }
    _greetingCount = nextCount;
    return YES;
}
@end

@implementation ExternalGreetingSettingsController
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 240)];
    NSTextField *title = [NSTextField labelWithString:@"External Greeting"];
    title.font = [NSFont systemFontOfSize:19 weight:NSFontWeightSemibold];
    NSTextField *description = [NSTextField wrappingLabelWithString:
        @"This extension was built separately. Its settings appear here without installing another app."];
    description.textColor = NSColor.secondaryLabelColor;
    self.countLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"Greetings saved: %lu", (unsigned long)self.extension.greetingCount]];
    NSButton *greet = [NSButton buttonWithTitle:@"Add Greeting" target:self action:@selector(addGreeting:)];
    NSButton *aiSettings = [NSButton buttonWithTitle:@"AI Settings…" target:self action:@selector(openAISettings:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[greet, aiSettings]];
    buttons.spacing = 10;
    self.statusLabel = [NSTextField wrappingLabelWithString:@"No network or AI requests are made by this example."];
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *stack = [NSStackView stackViewWithViews:@[title, description, self.countLabel, buttons, self.statusLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:24],
        [description.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.statusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
}

- (void)addGreeting:(id)sender {
    NSError *error = nil;
    if ([self.extension recordGreeting:&error]) {
        self.countLabel.stringValue = [NSString stringWithFormat:@"Greetings saved: %lu", (unsigned long)self.extension.greetingCount];
        self.statusLabel.stringValue = @"Saved in this extension’s settings folder.";
        self.statusLabel.textColor = NSColor.secondaryLabelColor;
    } else {
        self.statusLabel.stringValue = error.localizedDescription ?: @"The greeting could not be saved.";
        self.statusLabel.textColor = NSColor.systemRedColor;
    }
}

- (void)openAISettings:(id)sender { [self.extension.context openAISettings]; }
@end
