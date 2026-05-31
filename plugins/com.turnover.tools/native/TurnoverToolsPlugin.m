#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import "SpliceKitPluginAPI.h"

static SpliceKitPluginAPI gAPIStorage;
static SpliceKitPluginAPI *gAPI = NULL;
static NSString *gPluginDataPath = nil;
static NSPanel *gPanel = nil;
static NSTextField *gStatusLabel = nil;
static NSTextField *gRunLabel = nil;

static void TTShowPanel(void);
static NSDictionary *TTRunTool(NSString *toolId);
static NSDictionary *TTRunAutoMarker(NSString *markerKind);
static NSDictionary *TTRunLuaCompatibilityScript(NSString *scriptName);
static BOOL TTFileExists(NSString *path);
static NSDictionary *TTCaptureLargestFCPWindow(NSString *outputPath);

static NSString *TTString(NSString *value) {
    return value ?: @"";
}

static NSString *TTPluginDataPath(void) {
    if (gPluginDataPath.length > 0) {
        return gPluginDataPath;
    }
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [appSupport stringByAppendingPathComponent:@"SpliceKit/plugins/com.turnover.tools/data"];
}

static NSString *TTPluginRootPath(void) {
    return [TTPluginDataPath() stringByDeletingLastPathComponent];
}

static NSString *TTMenuRootPath(void) {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [appSupport stringByAppendingPathComponent:@"SpliceKit/lua/menu"];
}

static NSString *TTOldVFXShotListStatePath(void) {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [appSupport stringByAppendingPathComponent:@"SpliceKit/VFXShotList"];
}

static NSString *TTDesktopPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
}

static void TTAppendLog(NSString *path, NSString *message) {
    if (path.length == 0) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!TTFileExists(path)) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

static BOOL TTFileExists(NSString *path) {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSString *TTTrimString(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *TTExecutablePath(NSString *path) {
    NSString *trimmed = TTTrimString(path);
    if (trimmed.length == 0) return @"";
    return [[NSFileManager defaultManager] isExecutableFileAtPath:trimmed] ? trimmed : @"";
}

static NSArray<NSString *> *TTNVMNodeCandidates(void) {
    NSString *versionsPath = [NSHomeDirectory() stringByAppendingPathComponent:@".nvm/versions/node"];
    NSArray<NSString *> *versions = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:versionsPath error:nil] ?: @[];
    NSArray<NSString *> *sorted = [versions sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSString *version in [sorted reverseObjectEnumerator]) {
        [candidates addObject:[[[versionsPath stringByAppendingPathComponent:version] stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:@"node"]];
    }
    return candidates;
}

static NSString *TTShellWhich(NSString *tool) {
    NSString *script = [NSString stringWithFormat:
        @"source /etc/zprofile >/dev/null 2>&1 || true; "
         "source ~/.zprofile >/dev/null 2>&1 || true; "
         "source ~/.zshrc >/dev/null 2>&1 || true; "
         "command -v %@ 2>/dev/null",
        tool ?: @""];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    task.arguments = @[@"-lc", script];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (__unused NSException *exception) {
        return @"";
    }

    if (task.terminationStatus != 0) return @"";
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return TTExecutablePath(output);
}

static NSString *TTWhich(NSString *tool) {
    NSMutableArray<NSString *> *commonPaths = [NSMutableArray array];
    if ([tool isEqualToString:@"node"]) {
        NSString *configured = TTExecutablePath([NSString stringWithContentsOfFile:[TTPluginDataPath() stringByAppendingPathComponent:@"node_path.txt"]
                                                                          encoding:NSUTF8StringEncoding
                                                                             error:nil]);
        if (configured.length > 0) return configured;
        configured = TTExecutablePath(NSProcessInfo.processInfo.environment[@"TURNOVER_NODE_PATH"]);
        if (configured.length > 0) return configured;
        [commonPaths addObject:[NSHomeDirectory() stringByAppendingPathComponent:@".volta/bin/node"]];
        [commonPaths addObject:[NSHomeDirectory() stringByAppendingPathComponent:@".asdf/shims/node"]];
        [commonPaths addObjectsFromArray:TTNVMNodeCandidates()];
    }

    [commonPaths addObjectsFromArray:@[
        [@"/opt/homebrew/bin" stringByAppendingPathComponent:tool],
        [@"/usr/local/bin" stringByAppendingPathComponent:tool],
        [@"/opt/local/bin" stringByAppendingPathComponent:tool],
        [@"/usr/local/opt/node/bin" stringByAppendingPathComponent:tool],
        [@"/usr/bin" stringByAppendingPathComponent:tool],
        [@"/bin" stringByAppendingPathComponent:tool],
    ]];
    for (NSString *path in commonPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }

    NSString *shellPath = TTShellWhich(tool);
    if (shellPath.length > 0) return shellPath;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/which"];
    task.arguments = @[tool];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (__unused NSException *exception) {
        return @"";
    }

    if (task.terminationStatus != 0) return @"";
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return TTExecutablePath(output);
}

static NSString *TTReadFile(NSString *path, NSError **error) {
    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
}

static BOOL TTWriteString(NSString *path, NSString *text, NSError **error) {
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static id TTOnMainSync(id (^block)(void)) {
    if ([NSThread isMainThread]) {
        return block ? block() : nil;
    }

    __block id result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = block ? block() : nil;
    });
    return result;
}

static NSString *TTChooseFolder(NSString *prompt) {
    return TTOnMainSync(^id{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = prompt ?: @"Choose Folder";
        panel.message = prompt ?: @"Choose Folder";
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = NO;
        NSInteger response = [panel runModal];
        if (response != NSModalResponseOK) return nil;
        return panel.URL.path;
    });
}

static NSString *TTTextPrompt(NSString *title, NSString *message, NSString *defaultValue) {
    return TTOnMainSync(^id{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"Turnover";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        field.stringValue = defaultValue ?: @"";
        alert.accessoryView = field;

        NSInteger response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) return nil;
        return field.stringValue ?: @"";
    });
}

static NSString *TTChoicePrompt(NSString *title, NSString *message, NSArray<NSString *> *choices, NSString *defaultValue) {
    return TTOnMainSync(^id{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"Turnover";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 26) pullsDown:NO];
        [popup addItemsWithTitles:choices ?: @[]];
        if (defaultValue.length > 0 && [choices containsObject:defaultValue]) {
            [popup selectItemWithTitle:defaultValue];
        }
        alert.accessoryView = popup;

        NSInteger response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) return nil;
        return popup.titleOfSelectedItem ?: @"";
    });
}

static NSString *TTTSVEscape(NSString *value) {
    NSMutableString *out = [NSMutableString stringWithString:value ?: @""];
    [out replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, out.length)];
    return out;
}

static BOOL TTWriteKeyValueFile(NSString *path, NSDictionary<NSString *, NSString *> *map, NSError **error) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSString *> *keys = [[map allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        [lines addObject:[NSString stringWithFormat:@"%@\t%@", key, TTTSVEscape(map[key])]];
    }
    NSString *text = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    return TTWriteString(path, text, error);
}

static NSString *TTJoinUnitSeparator(NSArray<NSString *> *values) {
    return [values componentsJoinedByString:@"\x1F"];
}

static NSArray<NSString *> *TTSortedStringsFromSet(NSMutableSet<NSString *> *set) {
    return [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary *TTCallRPC(NSString *method, NSDictionary *params) {
    if (!gAPI || !gAPI->callMethod) {
        return @{@"error": @"SpliceKit callMethod API is unavailable"};
    }
    NSDictionary *response = gAPI->callMethod(@{
        @"method": method ?: @"",
        @"params": params ?: @{}
    });
    if (![response isKindOfClass:NSDictionary.class]) {
        return @{@"error": @"Invalid SpliceKit RPC response"};
    }
    if (response[@"error"]) return response;
    NSDictionary *result = response[@"result"];
    if ([result isKindOfClass:NSDictionary.class]) return result;
    return response;
}

static NSDictionary *TTRunProcess(NSString *executable, NSArray<NSString *> *arguments) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments ?: @[];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        return @{
            @"status": @"error",
            @"message": exception.reason ?: @"Failed to launch process"
        };
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return @{
        @"status": task.terminationStatus == 0 ? @"ok" : @"error",
        @"exit_code": @(task.terminationStatus),
        @"output": output
    };
}

static NSDictionary *TTRunScreencapture(NSString *path) {
    return TTRunProcess(@"/usr/sbin/screencapture", @[@"-x", path ?: @""]);
}

static CGImageRef TTCopy16x9Crop(CGImageRef image) {
    if (!image) return nil;
    CGFloat width = CGImageGetWidth(image);
    CGFloat height = CGImageGetHeight(image);
    CGFloat lhs = width * 9.0;
    CGFloat rhs = height * 16.0;
    CGFloat diff = fabs(lhs - rhs);
    CGFloat tol = MAX(rhs / 100.0, 4.0);
    if (diff <= tol) {
        return CGImageRetain(image);
    }

    CGFloat targetW = width;
    CGFloat targetH = floor(width * 9.0 / 16.0);
    if (targetH > height) {
        targetH = height;
        targetW = floor(height * 16.0 / 9.0);
    }

    CGFloat cropX = floor((width - targetW) / 2.0);
    CGFloat safeTop = floor(height / 28.0);
    safeTop = MIN(MAX(safeTop, 24.0), 80.0);
    CGFloat usableH = height - safeTop;
    CGFloat cropY = usableH < targetH
        ? floor((height - targetH) / 2.0)
        : floor(safeTop + (usableH - targetH) / 2.0);
    cropY = MAX(0.0, MIN(cropY, height - targetH));

    CGRect rect = CGRectIntegral(CGRectMake(cropX, cropY, targetW, targetH));
    return CGImageCreateWithImageInRect(image, rect);
}

static BOOL TTWriteImage(CGImageRef image, NSString *path, CFStringRef type, CGFloat quality, NSError **error) {
    if (!image || path.length == 0) return NO;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, type, 1, nil);
    if (!destination) {
        if (error) *error = [NSError errorWithDomain:@"Turnover" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Could not create image destination"}];
        return NO;
    }
    NSDictionary *properties = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality)};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (!ok && error) {
        *error = [NSError errorWithDomain:@"Turnover" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not write image"}];
    }
    return ok;
}

static BOOL TTWindowLooksLikeCaptureTarget(NSWindow *window) {
    if (!window || !window.visible) return NO;
    if (window.isMiniaturized) return NO;
    if ([window isKindOfClass:NSPanel.class]) return NO;
    NSString *title = window.title ?: @"";
    if ([title containsString:@"Turnover"]) return NO;
    if (window.frame.size.width < 320 || window.frame.size.height < 240) return NO;
    return YES;
}

static NSWindow *TTLargestVisibleFCPWindow(void) {
    __block NSWindow *bestWindow = nil;
    __block CGFloat bestArea = 0;
    TTOnMainSync(^id{
        for (NSWindow *window in NSApp.windows) {
            if (!TTWindowLooksLikeCaptureTarget(window)) continue;
            CGFloat area = window.frame.size.width * window.frame.size.height;
            if (area > bestArea) {
                bestArea = area;
                bestWindow = window;
            }
        }
        return nil;
    });
    return bestWindow;
}

static NSDictionary *TTCaptureLargestFCPWindow(NSString *outputPath) {
    if (outputPath.length == 0) {
        return @{@"status": @"error", @"message": @"Missing output path"};
    }

    __block NSDictionary *result = nil;
    TTOnMainSync(^id{
        NSWindow *window = TTLargestVisibleFCPWindow();
        if (!window) {
            result = @{@"status": @"error", @"message": @"No visible FCP window found"};
            return nil;
        }

        CGWindowID windowID = (CGWindowID)window.windowNumber;
        CGImageRef image = CGWindowListCreateImage(
            CGRectNull,
            kCGWindowListOptionIncludingWindow,
            windowID,
            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution
        );
        if (!image) {
            result = @{@"status": @"error", @"message": @"CGWindowListCreateImage returned nil. Screen Recording permission may be needed."};
            return nil;
        }

        NSError *error = nil;
        BOOL ok = TTWriteImage(image, outputPath, CFSTR("public.png"), 1.0, &error);
        NSUInteger width = CGImageGetWidth(image);
        NSUInteger height = CGImageGetHeight(image);
        CGImageRelease(image);

        if (!ok) {
            result = @{@"status": @"error", @"message": error.localizedDescription ?: @"Failed to write capture"};
            return nil;
        }

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil] ?: @{};
        result = @{
            @"status": @"ok",
            @"path": outputPath,
            @"width": @(width),
            @"height": @(height),
            @"bytes": attrs[NSFileSize] ?: @0,
            @"window_title": window.title ?: @"",
            @"window_number": @(windowID),
        };
        return nil;
    });

    return result ?: @{@"status": @"error", @"message": @"Capture failed"};
}

static CGImageRef TTCreateThumbnail(CGImageRef image, CGFloat maxWidth) {
    if (!image) return nil;
    CGFloat sourceW = CGImageGetWidth(image);
    CGFloat sourceH = CGImageGetHeight(image);
    CGFloat scale = MIN(1.0, maxWidth / MAX(sourceW, 1.0));
    size_t destW = MAX(1, (size_t)floor(sourceW * scale));
    size_t destH = MAX(1, (size_t)floor(sourceH * scale));

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, destW, destH, 8, 0, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) return nil;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, destW, destH), image);
    CGImageRef thumb = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return thumb;
}

static BOOL TTCaptureShotListFrame(NSString *index, NSString *markerName, NSString *fullName, NSString *thumbName, NSString **message) {
    NSString *desktop = TTDesktopPath();
    NSString *rawDir = [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Raw"];
    NSString *cropDir = [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    NSString *thumbDir = [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    [[NSFileManager defaultManager] createDirectoryAtPath:rawDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:cropDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *rawPath = [rawDir stringByAppendingPathComponent:fullName ?: @"capture.png"];
    NSString *cropPath = [cropDir stringByAppendingPathComponent:fullName ?: @"capture.png"];
    NSString *thumbPath = [thumbDir stringByAppendingPathComponent:thumbName ?: @"capture.jpg"];

    NSDictionary *capture = TTRunScreencapture(rawPath);
    if (![capture[@"status"] isEqual:@"ok"] || !TTFileExists(rawPath)) {
        if (message) *message = [NSString stringWithFormat:@"Capture failed at %@ %@: %@", index ?: @"", markerName ?: @"", capture[@"output"] ?: @""];
        return NO;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:rawPath];
    CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
    if (!cgImage) {
        if (message) *message = @"Could not decode screenshot image";
        return NO;
    }

    CGImageRef cropped = TTCopy16x9Crop(cgImage);
    CGImageRef thumb = TTCreateThumbnail(cropped ?: cgImage, 960.0);
    NSError *error = nil;
    BOOL wroteCrop = TTWriteImage(cropped ?: cgImage, cropPath, CFSTR("public.png"), 1.0, &error);
    BOOL wroteThumb = TTWriteImage(thumb ?: (cropped ?: cgImage), thumbPath, CFSTR("public.jpeg"), 0.9, &error);
    if (cropped) CGImageRelease(cropped);
    if (thumb) CGImageRelease(thumb);
    [[NSFileManager defaultManager] removeItemAtPath:rawPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:cropPath error:nil];

    if (!wroteCrop || !wroteThumb) {
        if (message) *message = error.localizedDescription ?: @"Could not write thumbnail";
        return NO;
    }
    if (message) *message = [NSString stringWithFormat:@"Captured %@ %@", index ?: @"", markerName ?: @""];
    return YES;
}

static NSDictionary *TTStatus(void) {
    NSString *menuRoot = TTMenuRootPath();
    NSString *motionTitle = [NSHomeDirectory() stringByAppendingPathComponent:@"Movies/Motion Templates.localized/Titles.localized/VFX/VFX Naming/VFX NAMING.moti"];
    NSString *nodePath = TTWhich(@"node");
    NSString *dataPath = TTPluginDataPath();

    return @{
        @"plugin": @"Turnover",
        @"version": @"1.1.0",
        @"data_path": TTString(dataPath),
        @"screen_recording_granted": @(CGPreflightScreenCaptureAccess()),
        @"accessibility_granted": @(AXIsProcessTrusted()),
        @"node_path": TTString(nodePath),
        @"node_available": @(nodePath.length > 0),
        @"lua_menu_root": TTString(menuRoot),
        @"motion_title_installed": @(TTFileExists(motionTitle))
    };
}

static NSString *TTStatusText(void) {
    NSDictionary *status = TTStatus();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Turnover %@", status[@"version"] ?: @""]];
    [lines addObject:[NSString stringWithFormat:@"Screen Recording: %@", [status[@"screen_recording_granted"] boolValue] ? @"OK" : @"Needs permission"]];
    [lines addObject:[NSString stringWithFormat:@"Accessibility: %@", [status[@"accessibility_granted"] boolValue] ? @"OK" : @"Needs permission"]];
    [lines addObject:[NSString stringWithFormat:@"Node.js: %@", [status[@"node_available"] boolValue] ? status[@"node_path"] : @"Not found"]];
    [lines addObject:[NSString stringWithFormat:@"VFX Naming Motion title: %@", [status[@"motion_title_installed"] boolValue] ? @"Installed" : @"Missing"]];
    [lines addObject:[NSString stringWithFormat:@"Data: %@", status[@"data_path"]]];
    return [lines componentsJoinedByString:@"\n"];
}

static void TTSetRunMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gRunLabel) {
            gRunLabel.stringValue = message ?: @"";
        }
    });
}

static NSDictionary *TTRunConformPrep(void) {
    NSString *dataPath = TTPluginDataPath();
    NSString *sourceXML = [dataPath stringByAppendingPathComponent:@"Conform_Prep_Source.fcpxml"];
    NSString *patchedXML = [dataPath stringByAppendingPathComponent:@"Conform_Prep_Patched.fcpxml"];
    NSString *reportPath = [dataPath stringByAppendingPathComponent:@"Conform_Prep_Report.txt"];
    NSString *plannerPath = [TTPluginRootPath() stringByAppendingPathComponent:@"scripts/build_conform_prep_fcpxml.mjs"];
    NSString *nodePath = TTWhich(@"node");

    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:sourceXML error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:patchedXML error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:reportPath error:nil];

    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(plannerPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing planner: %@", plannerPath]};
    }

    TTSetRunMessage(@"Conform Prep: exporting current project...");
    NSDictionary *exportResult = TTCallRPC(@"fcpxml.export", @{@"path": sourceXML});
    if (exportResult[@"error"]) {
        return @{@"status": @"error", @"stage": @"export", @"message": [exportResult[@"error"] description]};
    }
    if (!TTFileExists(sourceXML)) {
        return @{@"status": @"error", @"stage": @"export", @"message": @"Export did not create source FCPXML"};
    }

    TTSetRunMessage(@"Conform Prep: running planner...");
    NSDictionary *plannerResult = TTRunProcess(nodePath, @[
        plannerPath,
        @"--source-xml", sourceXML,
        @"--output-xml", patchedXML,
        @"--report", reportPath
    ]);
    if (![plannerResult[@"status"] isEqual:@"ok"] || !TTFileExists(patchedXML)) {
        NSString *output = plannerResult[@"output"] ?: @"";
        return @{
            @"status": @"error",
            @"stage": @"planner",
            @"message": output.length > 0 ? output : @"Planner failed or did not create patched FCPXML",
            @"report_path": reportPath
        };
    }

    NSError *readError = nil;
    NSString *xml = TTReadFile(patchedXML, &readError);
    if (xml.length == 0) {
        return @{
            @"status": @"error",
            @"stage": @"read_patched_xml",
            @"message": readError.localizedDescription ?: @"Patched FCPXML is empty",
            @"report_path": reportPath
        };
    }

    TTSetRunMessage(@"Conform Prep: importing patched project...");
    NSDictionary *importResult = TTCallRPC(@"fcpxml.import", @{@"xml": xml, @"internal": @NO});
    if (importResult[@"error"]) {
        return @{
            @"status": @"error",
            @"stage": @"import",
            @"message": [importResult[@"error"] description],
            @"report_path": reportPath
        };
    }

    NSString *report = @"";
    if (TTFileExists(reportPath)) {
        report = TTReadFile(reportPath, nil) ?: @"";
    }

    TTSetRunMessage(@"Conform Prep: complete");
    return @{
        @"status": @"ok",
        @"source_xml_path": sourceXML,
        @"patched_xml_path": patchedXML,
        @"report_path": reportPath,
        @"report": report
    };
}

static NSDictionary *TTRunVFXTimeline(void) {
    NSString *dataPath = TTPluginDataPath();
    NSString *sourceXML = [dataPath stringByAppendingPathComponent:@"VFX_Deliveries_Source.fcpxml"];
    NSString *patchedXML = [dataPath stringByAppendingPathComponent:@"VFX_Deliveries_Patched.fcpxml"];
    NSString *reportPath = [dataPath stringByAppendingPathComponent:@"VFX_Deliveries_Report.txt"];
    NSString *configPath = [dataPath stringByAppendingPathComponent:@"VFX_Deliveries_Config.tsv"];
    NSString *plannerPath = [TTPluginRootPath() stringByAppendingPathComponent:@"scripts/build_vfx_deliveries_fcpxml.mjs"];
    NSString *nodePath = TTWhich(@"node");

    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *path in @[sourceXML, patchedXML, reportPath, configPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }

    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(plannerPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing planner: %@", plannerPath]};
    }

    TTSetRunMessage(@"VFX Timeline: choose delivery folder...");
    NSString *deliveryFolder = TTChooseFolder(@"Choose the VFX deliveries folder");
    if (deliveryFolder.length == 0) {
        return @{@"status": @"cancelled", @"message": @"Folder selection cancelled"};
    }

    NSString *handleFrames = TTTextPrompt(@"VFX Timeline", @"Handle frames to trim from both head and tail. Example: 8 trims 8 frames at the head and 8 frames at the tail.", @"0");
    if (!handleFrames) return @{@"status": @"cancelled", @"message": @"Handle frame prompt cancelled"};
    NSString *slateFrames = TTTextPrompt(@"VFX Timeline", @"Slate frames to trim from the head:", @"0");
    if (!slateFrames) return @{@"status": @"cancelled", @"message": @"Slate frame prompt cancelled"};
    NSString *placementMode = TTChoicePrompt(@"VFX Timeline", @"Choose placement mode:", @[@"connected", @"replace", @"audition"], @"connected");
    if (!placementMode) return @{@"status": @"cancelled", @"message": @"Placement mode prompt cancelled"};
    NSString *targetEventName = TTTextPrompt(@"VFX Timeline", @"Target event name:", @"VFX Deliveries");
    if (!targetEventName) return @{@"status": @"cancelled", @"message": @"Target event prompt cancelled"};

    NSMutableSet<NSString *> *eventNames = [NSMutableSet set];
    NSMutableArray<NSString *> *projectNames = [NSMutableArray array];
    NSDictionary *browser = TTCallRPC(@"browser.listClips", @{});
    NSArray *clips = [browser[@"clips"] isKindOfClass:NSArray.class] ? browser[@"clips"] : @[];
    for (NSDictionary *clip in clips) {
        if (![clip isKindOfClass:NSDictionary.class]) continue;
        NSString *eventName = [clip[@"event"] isKindOfClass:NSString.class] ? clip[@"event"] : @"";
        if (eventName.length > 0) [eventNames addObject:eventName];
        NSString *className = [clip[@"class"] isKindOfClass:NSString.class] ? clip[@"class"] : @"";
        NSString *clipName = [clip[@"name"] isKindOfClass:NSString.class] ? clip[@"name"] : @"";
        if (clipName.length > 0 && [className containsString:@"Sequence"]) {
            [projectNames addObject:clipName];
        }
    }
    [projectNames sortUsingSelector:@selector(compare:)];

    NSError *configError = nil;
    BOOL wroteConfig = TTWriteKeyValueFile(configPath, @{
        @"status": @"ok",
        @"delivery_folder": deliveryFolder,
        @"delivery_batch_name": deliveryFolder.lastPathComponent ?: @"",
        @"target_event_name": targetEventName.length > 0 ? targetEventName : @"VFX Deliveries",
        @"handle_frames": handleFrames.length > 0 ? handleFrames : @"0",
        @"total_handle_frames": handleFrames.length > 0 ? handleFrames : @"0",
        @"slate_frames": slateFrames.length > 0 ? slateFrames : @"0",
        @"placement_mode": placementMode.length > 0 ? placementMode : @"connected",
        @"lane": @"10",
        @"existing_event_names": TTJoinUnitSeparator(TTSortedStringsFromSet(eventNames)),
        @"existing_project_names": TTJoinUnitSeparator(projectNames),
    }, &configError);
    if (!wroteConfig) {
        return @{@"status": @"error", @"stage": @"write_config", @"message": configError.localizedDescription ?: @"Could not write config"};
    }

    TTSetRunMessage(@"VFX Timeline: exporting current project...");
    NSDictionary *exportResult = TTCallRPC(@"fcpxml.export", @{@"path": sourceXML});
    if (exportResult[@"error"]) {
        return @{@"status": @"error", @"stage": @"export", @"message": [exportResult[@"error"] description]};
    }
    if (!TTFileExists(sourceXML)) {
        return @{@"status": @"error", @"stage": @"export", @"message": @"Export did not create source FCPXML"};
    }

    TTSetRunMessage(@"VFX Timeline: running planner...");
    NSDictionary *plannerResult = TTRunProcess(nodePath, @[
        plannerPath,
        @"--source-xml", sourceXML,
        @"--config", configPath,
        @"--output-xml", patchedXML,
        @"--report", reportPath
    ]);
    if (![plannerResult[@"status"] isEqual:@"ok"] || !TTFileExists(patchedXML)) {
        NSString *output = plannerResult[@"output"] ?: @"";
        return @{
            @"status": @"error",
            @"stage": @"planner",
            @"message": output.length > 0 ? output : @"Planner failed or did not create patched FCPXML",
            @"report_path": reportPath
        };
    }

    NSError *readError = nil;
    NSString *xml = TTReadFile(patchedXML, &readError);
    if (xml.length == 0) {
        return @{
            @"status": @"error",
            @"stage": @"read_patched_xml",
            @"message": readError.localizedDescription ?: @"Patched FCPXML is empty",
            @"report_path": reportPath
        };
    }

    TTSetRunMessage(@"VFX Timeline: importing patched project...");
    NSDictionary *importResult = TTCallRPC(@"fcpxml.import", @{@"xml": xml, @"internal": @NO});
    if (importResult[@"error"]) {
        return @{
            @"status": @"error",
            @"stage": @"import",
            @"message": [importResult[@"error"] description],
            @"report_path": reportPath
        };
    }

    TTSetRunMessage(@"VFX Timeline: complete");
    return @{
        @"status": @"ok",
        @"source_xml_path": sourceXML,
        @"patched_xml_path": patchedXML,
        @"config_path": configPath,
        @"report_path": reportPath
    };
}

static NSDictionary *TTRunLuaFile(NSString *path) {
    if (!TTFileExists(path)) {
        return @{
            @"status": @"error",
            @"message": [NSString stringWithFormat:@"Missing Lua script: %@", path]
        };
    }

    NSDictionary *result = TTCallRPC(@"lua.executeFile", @{@"path": path});
    if (result[@"error"]) {
        return @{
            @"status": @"error",
            @"message": [result[@"error"] description],
            @"script_path": path
        };
    }
    return @{
        @"status": @"ok",
        @"script_path": path,
        @"result": result
    };
}

static NSDictionary *TTRunLuaCompatibilityScript(NSString *scriptName) {
    NSString *path = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:scriptName ?: @""];
    if (!TTFileExists(path)) {
        path = [TTMenuRootPath() stringByAppendingPathComponent:scriptName ?: @""];
    }
    return TTRunLuaFile(path);
}

static NSDictionary *TTRunAutoMarker(NSString *markerKind) {
    NSDictionary<NSString *, NSString *> *scripts = @{
        @"standard": @"VFX Auto Marker - Standard.lua",
        @"todo": @"VFX Auto Marker - To Do.lua",
        @"chapter": @"VFX Auto Marker - Chapter.lua",
    };
    NSString *scriptName = scripts[markerKind ?: @""];
    if (scriptName.length == 0) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Unknown marker kind: %@", markerKind ?: @""]};
    }
    NSString *path = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua/scripts"] stringByAppendingPathComponent:scriptName];
    return TTRunLuaFile(path);
}

static NSDictionary *TTRunVFXPullEDL(void) {
    NSString *handleText = TTTextPrompt(
        @"VFX Pull EDL",
        @"Handle frames to extend source TC in/out on both sides. Example: 8 extends 8 frames at the head and 8 frames at the tail.",
        @"0"
    );
    if (!handleText) {
        return @{@"status": @"cancelled", @"message": @"Handle frame prompt cancelled"};
    }

    NSInteger totalHandleFrames = handleText.integerValue;
    if (totalHandleFrames < 0) {
        return @{@"status": @"error", @"message": @"Handle frames must be 0 or greater."};
    }

    NSString *stateDir = TTOldVFXShotListStatePath();
    NSString *configPath = [stateDir stringByAppendingPathComponent:@"VFX_Pull_EDL_Config.tsv"];
    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    BOOL ok = TTWriteKeyValueFile(configPath, @{
        @"handle_frames": [NSString stringWithFormat:@"%ld", (long)totalHandleFrames],
        @"total_handle_frames": [NSString stringWithFormat:@"%ld", (long)totalHandleFrames],
    }, &error);
    if (!ok) {
        return @{@"status": @"error", @"message": error.localizedDescription ?: @"Could not write VFX Pull EDL config"};
    }

    return TTRunLuaCompatibilityScript(@"VFX Pull EDL.lua");
}

static BOOL TTEnsureArtifactToolLink(NSString **message) {
    NSString *scriptDir = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"scripts"];
    NSString *linkPath = [[scriptDir stringByAppendingPathComponent:@"node_modules/@oai"] stringByAppendingPathComponent:@"artifact-tool"];
    NSString *targetPath = [[[[NSHomeDirectory() stringByAppendingPathComponent:@".cache/codex-runtimes/codex-primary-runtime/dependencies/node"]
        stringByAppendingPathComponent:@"node_modules"]
        stringByAppendingPathComponent:@"@oai"]
        stringByAppendingPathComponent:@"artifact-tool"].stringByStandardizingPath;

    if (TTFileExists(linkPath)) return YES;
    if (!TTFileExists(targetPath)) {
        if (message) *message = [NSString stringWithFormat:@"Missing @oai/artifact-tool runtime: %@", targetPath];
        return NO;
    }

    NSString *parent = [linkPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createSymbolicLinkAtPath:linkPath withDestinationPath:targetPath error:&error];
    if (!ok && message) *message = error.localizedDescription ?: @"Could not link artifact-tool";
    return ok;
}

static NSURL *TTNewestWorkbookURL(void) {
    NSArray<NSURL *> *candidates = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:TTDesktopPath()]
                                                                includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                     error:nil] ?: @[];
    NSURL *best = nil;
    NSDate *bestDate = NSDate.distantPast;
    for (NSURL *url in candidates) {
        NSString *name = url.lastPathComponent ?: @"";
        if (![name hasPrefix:@"VFX Shot List"] || ![[url.pathExtension lowercaseString] isEqualToString:@"xlsx"]) continue;
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        if (!best || [date ?: NSDate.distantPast compare:bestDate] == NSOrderedDescending) {
            best = url;
            bestDate = date ?: NSDate.distantPast;
        }
    }
    return best;
}

static NSURL *TTOrganizeShotListOutputs(NSURL *workbookURL) {
    if (!workbookURL) return nil;
    NSString *stem = workbookURL.URLByDeletingPathExtension.lastPathComponent ?: @"VFX Shot List";
    NSString *outputDir = [TTDesktopPath() stringByAppendingPathComponent:stem];
    NSString *finalWorkbook = [outputDir stringByAppendingPathComponent:workbookURL.lastPathComponent];
    NSString *thumbDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    NSString *finalThumbDir = [outputDir stringByAppendingPathComponent:@"Thumbnails"];

    [[NSFileManager defaultManager] createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalWorkbook error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalThumbDir error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:workbookURL.path toPath:finalWorkbook error:nil];
    if (TTFileExists(thumbDir)) {
        [[NSFileManager defaultManager] moveItemAtPath:thumbDir toPath:finalThumbDir error:nil];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:finalThumbDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    for (NSString *dirName in @[@"VFX_Shot_List_Captures_Raw", @"VFX_Shot_List_Captures_16x9"]) {
        [[NSFileManager defaultManager] removeItemAtPath:[TTDesktopPath() stringByAppendingPathComponent:dirName] error:nil];
    }
    return [NSURL fileURLWithPath:outputDir];
}

static NSUInteger TTCountFilesWithExtension(NSString *dir, NSString *ext) {
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSUInteger count = 0;
    NSString *wanted = [ext lowercaseString] ?: @"";
    for (NSString *item in items) {
        if ([[item.pathExtension lowercaseString] isEqualToString:wanted]) {
            count++;
        }
    }
    return count;
}

static NSDictionary *TTPostProcessShotListCaptures(void) {
    NSString *desktop = TTDesktopPath();
    NSString *captureDir = [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    NSString *thumbDir = [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    [[NSFileManager defaultManager] createDirectoryAtPath:captureDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:captureDir error:nil] ?: @[];
    NSUInteger processed = 0;
    NSUInteger failed = 0;
    NSMutableArray<NSString *> *messages = [NSMutableArray array];

    for (NSString *item in items) {
        if (![[item.pathExtension lowercaseString] isEqualToString:@"png"]) continue;
        NSString *capturePath = [captureDir stringByAppendingPathComponent:item];
        NSString *thumbName = [[item stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        NSString *thumbPath = [thumbDir stringByAppendingPathComponent:thumbName];

        NSImage *image = [[NSImage alloc] initWithContentsOfFile:capturePath];
        CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
        if (!cgImage) {
            failed++;
            [messages addObject:[NSString stringWithFormat:@"Could not decode %@", item]];
            continue;
        }

        CGImageRef cropped = TTCopy16x9Crop(cgImage);
        CGImageRef thumb = TTCreateThumbnail(cropped ?: cgImage, 960.0);
        NSError *error = nil;
        BOOL wroteCapture = TTWriteImage(cropped ?: cgImage, capturePath, CFSTR("public.png"), 1.0, &error);
        BOOL wroteThumb = TTWriteImage(thumb ?: (cropped ?: cgImage), thumbPath, CFSTR("public.jpeg"), 0.9, &error);
        if (cropped) CGImageRelease(cropped);
        if (thumb) CGImageRelease(thumb);

        if (wroteCapture && wroteThumb) {
            processed++;
        } else {
            failed++;
            [messages addObject:[NSString stringWithFormat:@"%@: %@", item, error.localizedDescription ?: @"write failed"]];
        }
    }

    return @{
        @"status": failed == 0 ? @"ok" : @"partial",
        @"processed": @(processed),
        @"failed": @(failed),
        @"message": [messages componentsJoinedByString:@"\n"]
    };
}

static NSDictionary *TTGenerateShotListExcel(NSString *manifestPath) {
    NSString *nodePath = TTWhich(@"node");
    NSString *generatorPath = [[[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"scripts"] stringByAppendingPathComponent:@"generate_vfx_shot_list_excel.mjs"];
    NSString *thumbDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    NSString *captureDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(generatorPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing generator: %@", generatorPath]};
    }
    NSString *artifactMessage = nil;
    if (!TTEnsureArtifactToolLink(&artifactMessage)) {
        return @{@"status": @"error", @"message": artifactMessage ?: @"Missing artifact-tool runtime"};
    }

    NSDictionary *result = TTRunProcess(nodePath, @[
        generatorPath,
        @"--manifest", manifestPath ?: @"",
        @"--captures", captureDir,
        @"--thumbs", thumbDir
    ]);
    if (![result[@"status"] isEqual:@"ok"]) {
        return @{@"status": @"error", @"message": result[@"output"] ?: @"Excel generator failed"};
    }

    NSURL *workbookURL = TTNewestWorkbookURL();
    NSURL *outputDir = TTOrganizeShotListOutputs(workbookURL);
    if (outputDir) {
        [[NSWorkspace sharedWorkspace] openURL:outputDir];
    }
    return @{
        @"status": @"ok",
        @"workbook_path": workbookURL.path ?: @"",
        @"output_folder": outputDir.path ?: @"",
        @"output": result[@"output"] ?: @""
    };
}

static void TTSendEscapeToFinalCut(void) {
    NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.FinalCut"];
    [[apps firstObject] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    for (NSUInteger i = 0; i < 3; i++) {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        if (!source) continue;
        CGEventRef down = CGEventCreateKeyboardEvent(source, 53, true);
        CGEventRef up = CGEventCreateKeyboardEvent(source, 53, false);
        if (down) CGEventPost(kCGHIDEventTap, down);
        if (up) CGEventPost(kCGHIDEventTap, up);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        CFRelease(source);
    }
}

static NSDictionary *TTRunVFXShotList(void) {
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        return @{
            @"status": @"error",
            @"message": @"Screen Recording permission is not granted for Final Cut Pro/Turnover yet. macOS may show a permission prompt; enable it, restart FCP, then run VFX Shot List again."
        };
    }

    NSString *stateDir = TTOldVFXShotListStatePath();
    NSString *readyPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Worker_Ready.flag"];
    NSString *progressPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Progress.tsv"];
    NSString *manifestPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Manifest.tsv"];
    NSString *reportPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Report.txt"];
    NSString *nativeLogPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Native_Capture.log"];
    NSString *scriptPath = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"VFX Shot List.lua"];

    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *path in @[progressPath, manifestPath, reportPath, nativeLogPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    TTWriteString(readyPath, [[NSDate date] description], nil);
    TTAppendLog(nativeLogPath, @"native shot list run");

    NSString *desktop = TTDesktopPath();
    for (NSString *dirName in @[@"VFX_Shot_List_Captures_Raw", @"VFX_Shot_List_Captures_16x9", @"VFX_Shot_List_Captures_Thumb"]) {
        [[NSFileManager defaultManager] removeItemAtPath:[desktop stringByAppendingPathComponent:dirName] error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:[desktop stringByAppendingPathComponent:dirName]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    TTSetRunMessage(@"VFX Shot List: capturing viewer frames...");
    NSDictionary *luaResult = TTRunLuaFile(scriptPath);
    [[NSFileManager defaultManager] removeItemAtPath:readyPath error:nil];
    TTSendEscapeToFinalCut();
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"lua status=%@", luaResult[@"status"] ?: @""]);
    if (![luaResult[@"status"] isEqual:@"ok"]) {
        return luaResult;
    }

    NSUInteger directCaptureCount = TTCountFilesWithExtension([TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"], @"png");
    if (directCaptureCount == 0) {
        return @{@"status": @"error", @"message": @"No screenshots captured", @"report_path": reportPath, @"native_log_path": nativeLogPath};
    }

    TTSetRunMessage(@"VFX Shot List: cropping and building thumbnails...");
    NSDictionary *postProcess = TTPostProcessShotListCaptures();
    NSUInteger thumbCount = TTCountFilesWithExtension([TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"], @"jpg");
    if (thumbCount == 0) {
        return @{
            @"status": @"error",
            @"stage": @"thumbnail",
            @"message": postProcess[@"message"] ?: @"No thumbnails created",
            @"captures": @(directCaptureCount),
            @"report_path": reportPath,
            @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"VFX Shot List: generating Excel...");
    NSDictionary *excel = TTGenerateShotListExcel(manifestPath);
    if (![excel[@"status"] isEqual:@"ok"]) {
        return @{
            @"status": @"error",
            @"stage": @"excel",
            @"message": excel[@"message"] ?: @"Excel generation failed",
            @"captures": @(directCaptureCount),
            @"report_path": reportPath
            , @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"VFX Shot List: complete");
    return @{
        @"status": @"ok",
        @"captures": @(directCaptureCount),
        @"thumbnails": @(thumbCount),
        @"failures": postProcess[@"failed"] ?: @0,
        @"manifest_path": manifestPath,
        @"report_path": reportPath,
        @"native_log_path": nativeLogPath,
        @"output_folder": excel[@"output_folder"] ?: @""
    };
}

static NSDictionary *TTRunTool(NSString *toolId) {
    if ([toolId isEqualToString:@"conform_prep"]) return TTRunConformPrep();
    if ([toolId isEqualToString:@"vfx_timeline"]) return TTRunVFXTimeline();
    if ([toolId isEqualToString:@"vfx_shot_list"]) return TTRunVFXShotList();
    if ([toolId isEqualToString:@"vfx_pull_edl"]) return TTRunVFXPullEDL();
    if ([toolId isEqualToString:@"vfx_auto_marker"]) {
        NSString *kind = TTChoicePrompt(@"VFX Auto Marker", @"Choose the marker type:", @[@"standard", @"todo", @"chapter"], @"standard");
        if (!kind) return @{@"status": @"cancelled", @"message": @"Marker selection cancelled"};
        return TTRunAutoMarker(kind);
    }
    if ([toolId isEqualToString:@"vfx_auto_marker_standard"]) return TTRunAutoMarker(@"standard");
    if ([toolId isEqualToString:@"vfx_auto_marker_todo"]) return TTRunAutoMarker(@"todo");
    if ([toolId isEqualToString:@"vfx_auto_marker_chapter"]) return TTRunAutoMarker(@"chapter");

    NSDictionary<NSString *, NSString *> *luaScripts = @{
        @"vfx_auto_naming": @"VFX Auto Naming.lua",
        @"vfx_reset_naming": @"VFX Reset Naming.lua",
    };
    NSString *scriptName = luaScripts[toolId ?: @""];
    if (scriptName.length > 0) return TTRunLuaCompatibilityScript(scriptName);

    return @{
        @"status": @"error",
        @"message": [NSString stringWithFormat:@"Unknown Turnover tool: %@", toolId ?: @""]
    };
}

@interface TTPanelController : NSObject
@end

@implementation TTPanelController

- (void)refresh:(__unused id)sender {
    gStatusLabel.stringValue = TTStatusText();
}

- (void)requestScreenRecording:(__unused id)sender {
    CGRequestScreenCaptureAccess();
    [self refresh:nil];
}

- (void)openDataFolder:(__unused id)sender {
    NSString *path = TTPluginDataPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)openTurnoverToolsPanel:(__unused id)sender {
    TTShowPanel();
}

- (void)runConformPrep:(__unused id)sender {
    TTSetRunMessage(@"Conform Prep: queued...");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = TTRunTool(@"conform_prep");
        NSString *status = [result[@"status"] description] ?: @"unknown";
        NSString *message = [result[@"message"] description] ?: @"";
        if ([status isEqualToString:@"ok"]) {
            TTSetRunMessage([NSString stringWithFormat:@"Conform Prep complete\nReport: %@", result[@"report_path"] ?: @""]);
        } else {
            TTSetRunMessage([NSString stringWithFormat:@"Conform Prep failed: %@", message]);
        }
    });
}

- (void)runMenuTool:(NSMenuItem *)sender {
    NSString *toolId = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : @"";
    NSString *label = sender.title ?: toolId;
    TTSetRunMessage([NSString stringWithFormat:@"%@: queued...", label]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = TTRunTool(toolId);
        NSString *status = [result[@"status"] description] ?: @"unknown";
        NSString *message = [result[@"message"] description] ?: @"";
        if ([status isEqualToString:@"ok"]) {
            TTSetRunMessage([NSString stringWithFormat:@"%@ complete", label]);
        } else {
            TTSetRunMessage([NSString stringWithFormat:@"%@ failed: %@", label, message]);
        }
    });
}

@end

static TTPanelController *gController = nil;

static void TTEnsureController(void) {
    if (!gController) {
        gController = [[TTPanelController alloc] init];
    }
}

static NSButton *TTButton(NSString *title, SEL action) {
    TTEnsureController();
    NSButton *button = [NSButton buttonWithTitle:title target:gController action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

static void TTShowPanel(void) {
    TTEnsureController();

    if (!gPanel) {
        gPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 360)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        gPanel.title = @"Turnover";
        gPanel.releasedWhenClosed = NO;

        NSStackView *root = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 520, 360)];
        root.orientation = NSUserInterfaceLayoutOrientationVertical;
        root.alignment = NSLayoutAttributeLeading;
        root.spacing = 12;
        root.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
        root.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *title = [NSTextField labelWithString:@"Turnover"];
        title.font = [NSFont boldSystemFontOfSize:20];
        [root addArrangedSubview:title];

        NSTextField *subtitle = [NSTextField labelWithString:@"Native turnover workflows for Final Cut Pro."];
        subtitle.textColor = NSColor.secondaryLabelColor;
        [root addArrangedSubview:subtitle];

        gStatusLabel = [NSTextField wrappingLabelWithString:TTStatusText()];
        gStatusLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
        [root addArrangedSubview:gStatusLabel];

        NSStackView *buttons = [[NSStackView alloc] init];
        buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        buttons.spacing = 8;
        [buttons addArrangedSubview:TTButton(@"Refresh", @selector(refresh:))];
        [buttons addArrangedSubview:TTButton(@"Request Screen Recording", @selector(requestScreenRecording:))];
        [buttons addArrangedSubview:TTButton(@"Open Data Folder", @selector(openDataFolder:))];
        [root addArrangedSubview:buttons];

        gRunLabel = [NSTextField wrappingLabelWithString:@"Run tools from the Turnover menu."];
        gRunLabel.textColor = NSColor.secondaryLabelColor;
        [root addArrangedSubview:gRunLabel];

        NSView *content = gPanel.contentView;
        [content addSubview:root];
        [NSLayoutConstraint activateConstraints:@[
            [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [root.topAnchor constraintEqualToAnchor:content.topAnchor],
            [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        ]];

        [gPanel center];
    }

    gStatusLabel.stringValue = TTStatusText();
    [gPanel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

static NSMenu *TTFindOrCreateMenu(NSString *title) {
    NSMenu *mainMenu = NSApp.mainMenu;
    if (!mainMenu) return nil;

    for (NSMenuItem *item in mainMenu.itemArray) {
        if ([item.title isEqualToString:title]) {
            if (!item.submenu) item.submenu = [[NSMenu alloc] initWithTitle:title];
            return item.submenu;
        }
    }

    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.submenu = [[NSMenu alloc] initWithTitle:title];
    NSInteger helpIndex = [mainMenu indexOfItemWithTitle:@"Help"];
    if (helpIndex >= 0) {
        [mainMenu insertItem:item atIndex:helpIndex];
    } else {
        [mainMenu addItem:item];
    }
    return item.submenu;
}

static void TTInstallMenuItem(void) {
    TTEnsureController();

    NSMenu *menu = TTFindOrCreateMenu(@"Turnover");
    if (!menu) menu = TTFindOrCreateMenu(@"Enhancements");
    if (!menu) return;

    for (NSMenuItem *item in menu.itemArray) {
        if ([item.representedObject isEqual:@"com.turnover.tools.show"]) {
            return;
        }
    }

    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"Open Turnover"
                                                      action:@selector(openTurnoverToolsPanel:)
                                               keyEquivalent:@""];
    showItem.target = gController;
    showItem.representedObject = @"com.turnover.tools.show";
    [menu addItem:showItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSArray<NSDictionary *> *tools = @[
        @{@"title": @"Conform Prep", @"id": @"conform_prep"},
        @{@"title": @"VFX Auto Naming", @"id": @"vfx_auto_naming"},
        @{@"title": @"VFX Reset Naming", @"id": @"vfx_reset_naming"},
        @{@"title": @"VFX Auto Marker", @"id": @"vfx_auto_marker"},
        @{@"title": @"VFX Shot List", @"id": @"vfx_shot_list"},
        @{@"title": @"VFX Pull EDL", @"id": @"vfx_pull_edl"},
        @{@"title": @"VFX Timeline", @"id": @"vfx_timeline"},
    ];
    for (NSDictionary *tool in tools) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:tool[@"title"]
                                                     action:@selector(runMenuTool:)
                                              keyEquivalent:@""];
        item.target = gController;
        item.representedObject = tool[@"id"];
        [menu addItem:item];
    }
}

static NSDictionary *TTHandleShow(__unused NSDictionary *params) {
    if (gAPI && gAPI->executeOnMainThreadAsync) {
        gAPI->executeOnMainThreadAsync(^{
            TTShowPanel();
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            TTShowPanel();
        });
    }
    return @{@"status": @"ok"};
}

static NSDictionary *TTHandleRequestScreenRecording(__unused NSDictionary *params) {
    if (gAPI && gAPI->executeOnMainThreadAsync) {
        gAPI->executeOnMainThreadAsync(^{
            CGRequestScreenCaptureAccess();
            if (gStatusLabel) gStatusLabel.stringValue = TTStatusText();
        });
    }
    return TTStatus();
}

static NSDictionary *TTHandleConformPrep(__unused NSDictionary *params) {
    return TTRunTool(@"conform_prep");
}

static NSDictionary *TTHandleRunTool(NSDictionary *params) {
    NSString *toolId = [params[@"tool_id"] isKindOfClass:NSString.class] ? params[@"tool_id"] : @"";
    return TTRunTool(toolId);
}

static NSDictionary *TTHandleVFXTimeline(__unused NSDictionary *params) {
    return TTRunTool(@"vfx_timeline");
}

static NSDictionary *TTHandleAutoMarker(NSDictionary *params) {
    NSString *kind = [params[@"marker_kind"] isKindOfClass:NSString.class] ? params[@"marker_kind"] : @"standard";
    if ([kind isEqualToString:@"todo"]) return TTRunTool(@"vfx_auto_marker_todo");
    if ([kind isEqualToString:@"chapter"]) return TTRunTool(@"vfx_auto_marker_chapter");
    return TTRunTool(@"vfx_auto_marker_standard");
}

static NSDictionary *TTHandleCaptureFullscreenViewer(NSDictionary *params) {
    NSString *path = [params[@"path"] isKindOfClass:NSString.class] ? params[@"path"] : @"";
    return TTCaptureLargestFCPWindow(path);
}

__attribute__((visibility("default")))
void SpliceKitPlugin_init(SpliceKitPluginAPI *api) {
    if (!api || api->apiVersion < 1) return;
    gAPIStorage = *api;
    gAPI = &gAPIStorage;
    if (api->dataPath) {
        gPluginDataPath = [[NSString alloc] initWithUTF8String:api->dataPath];
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:TTPluginDataPath()
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    api->executeOnMainThreadAsync(^{
        TTInstallMenuItem();
    });

    api->registerMethod(@"com.turnover.tools.show", ^NSDictionary *(NSDictionary *params) {
        return TTHandleShow(params);
    }, @{
        @"description": @"Open the Turnover panel",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.status", ^NSDictionary *(__unused NSDictionary *params) {
        return TTStatus();
    }, @{
        @"description": @"Return Turnover runtime and permission status",
        @"readOnly": @YES
    });

    api->registerMethod(@"com.turnover.tools.request_screen_recording", ^NSDictionary *(NSDictionary *params) {
        return TTHandleRequestScreenRecording(params);
    }, @{
        @"description": @"Request Screen Recording permission for the current FCP process",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.conform_prep", ^NSDictionary *(NSDictionary *params) {
        return TTHandleConformPrep(params);
    }, @{
        @"description": @"Run Conform Prep",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.vfx_timeline", ^NSDictionary *(NSDictionary *params) {
        return TTHandleVFXTimeline(params);
    }, @{
        @"description": @"Run VFX Timeline",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.vfx_auto_marker", ^NSDictionary *(NSDictionary *params) {
        return TTHandleAutoMarker(params);
    }, @{
        @"description": @"Run VFX Auto Marker by marker kind",
        @"readOnly": @NO,
        @"params": @{@"marker_kind": @{@"type": @"string", @"required": @YES}}
    });

    api->registerMethod(@"com.turnover.tools.capture_fullscreen_viewer", ^NSDictionary *(NSDictionary *params) {
        return TTHandleCaptureFullscreenViewer(params);
    }, @{
        @"description": @"Capture the largest visible Final Cut Pro window, intended for fullscreen playback preview",
        @"readOnly": @NO,
        @"params": @{@"path": @{@"type": @"string", @"required": @YES}}
    });

    api->registerMethod(@"com.turnover.tools.run_tool", ^NSDictionary *(NSDictionary *params) {
        return TTHandleRunTool(params);
    }, @{
        @"description": @"Run a Turnover tool by id",
        @"readOnly": @NO,
        @"params": @{@"tool_id": @{@"type": @"string", @"required": @YES}}
    });

    api->log(@"[Turnover] Native plugin initialized");
}
