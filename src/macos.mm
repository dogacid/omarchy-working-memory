#include "macos.h"

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>

namespace {
std::function<void()> g_onOpen;
std::function<void()> g_onQuit;
EventHotKeyRef g_hotKey = nullptr;

OSStatus onHotKey(EventHandlerCallRef, EventRef, void *) {
    if (g_onOpen)
        g_onOpen();
    return noErr;
}
} // namespace

@interface WMMenuTarget : NSObject <NSMenuDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenuItem *loginItem;
@end

@implementation WMMenuTarget

- (void)open:(id)sender {
    if (g_onOpen)
        g_onOpen();
}

- (void)quit:(id)sender {
    if (g_onQuit)
        g_onQuit();
}

// Registering the bundle itself as a login item: no helper app needed on
// macOS 13+. Only works from a real .app bundle (not a bare binary), which
// is how this always runs on macOS.
- (void)toggleLogin:(id)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled
        ? [service unregisterAndReturnError:&error]
        : [service registerAndReturnError:&error];
    if (!ok) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Couldn't change Open at Login";
        alert.informativeText = error.localizedDescription ?: @"Unknown error";
        [alert runModal];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    self.loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled
        ? NSControlStateValueOn : NSControlStateValueOff;
}

@end

namespace MacOS {

static WMMenuTarget *g_target = nil;

void install(std::function<void()> onOpen, std::function<void()> onQuit) {
    g_onOpen = std::move(onOpen);
    g_onQuit = std::move(onQuit);

    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&onHotKey, 1, &spec, nullptr, nullptr);
    EventHotKeyID id = {'wmem', 1};
    RegisterEventHotKey(kVK_ANSI_N, controlKey | optionKey, id, GetApplicationEventTarget(), 0, &g_hotKey);

    g_target = [[WMMenuTarget alloc] init];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = g_target;
    NSMenuItem *open = [menu addItemWithTitle:@"Open Working Memory" action:@selector(open:) keyEquivalent:@"n"];
    open.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    open.target = g_target;
    [menu addItem:[NSMenuItem separatorItem]];
    g_target.loginItem = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    g_target.loginItem.target = g_target;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Working Memory" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = g_target;

    g_target.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"note.text" accessibilityDescription:@"Working Memory"];
    [icon setTemplate:YES]; // not icon.template: a C++ keyword in Objective-C++
    g_target.statusItem.button.image = icon;
    g_target.statusItem.menu = menu;
}

void activate() {
    if (@available(macOS 14, *))
        [NSApp activate];
    else
        [NSApp activateIgnoringOtherApps:YES];
}

} // namespace MacOS
