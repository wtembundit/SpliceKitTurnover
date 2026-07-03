#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import "SpliceKitPluginAPI.h"

static SpliceKitPluginAPI gAPIStorage;
static SpliceKitPluginAPI *gAPI = NULL;
static NSString *gPluginDataPath = nil;
static NSPanel *gPanel = nil;
static NSTextField *gStatusLabel = nil;
static NSTextField *gRunLabel = nil;
static BOOL gToolRunInProgress = NO;
static BOOL gDidAutoCheckForUpdates = NO;
static NSString *gUpdateStatusText = @"Not checked";
static NSString * const TTTurnoverVersion = @"1.3.0";
static NSString * const TTLatestReleaseAPI = @"https://api.github.com/repos/wtembundit/SpliceKitTurnover/releases/latest";
static NSString * const TTLatestReleaseURL = @"https://github.com/wtembundit/SpliceKitTurnover/releases/latest";

static void TTShowPanel(void);
static NSDictionary *TTRunTool(NSString *toolId);
static NSDictionary *TTRunConformPrepVerify(void);
static NSDictionary *TTRunAutoMarker(NSString *markerKind, BOOL renameMarkers);
static NSDictionary *TTRunLuaCompatibilityScript(NSString *scriptName);
static NSDictionary *TTResetLuaVM(void);
static BOOL TTFileExists(NSString *path);
static NSString *TTTrimString(NSString *value);
static NSDictionary *TTCaptureLargestFCPWindow(NSString *outputPath);
static NSArray<NSDictionary<NSString *, NSString *> *> *TTReadShotListManifestRows(NSString *path);

static NSComparisonResult TTCompareVersions(NSString *left, NSString *right) {
    NSString *a = [[left ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]] copy];
    NSString *b = [[right ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]] copy];
    return [a compare:b options:NSNumericSearch];
}

static NSDictionary *TTLatestReleaseInfo(void) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:TTLatestReleaseAPI]
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10.0];
    [request setValue:@"SpliceKitTurnover" forHTTPHeaderField:@"User-Agent"];
    __block NSError *error = nil;
    __block NSData *data = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                completionHandler:^(NSData *responseData, __unused NSURLResponse *response, NSError *responseError) {
        data = responseData;
        error = responseError;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC));
    if (task.state == NSURLSessionTaskStateRunning) [task cancel];
    if (!data) return @{ @"status": @"error", @"message": error.localizedDescription ?: @"Could not check for updates" };
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:NSDictionary.class]) {
        return @{ @"status": @"error", @"message": error.localizedDescription ?: @"Invalid update response" };
    }
    NSString *tag = [json[@"tag_name"] isKindOfClass:NSString.class] ? json[@"tag_name"] : @"";
    NSString *url = [json[@"html_url"] isKindOfClass:NSString.class] ? json[@"html_url"] : TTLatestReleaseURL;
    if (tag.length == 0) return @{ @"status": @"error", @"message": @"Latest release has no version tag" };
    BOOL available = TTCompareVersions(TTTurnoverVersion, tag) == NSOrderedAscending;
    return @{ @"status": @"ok", @"tag": tag, @"url": url, @"update_available": @(available) };
}

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

static NSString *TTSafeFilenamePart(NSString *value) {
    NSString *trimmed = TTTrimString(value);
    if (trimmed.length == 0) return @"Untitled Project";

    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"<>:\"/\\|?*"];
    NSMutableString *out = [NSMutableString stringWithCapacity:trimmed.length];
    BOOL previousSpace = NO;
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar ch = [trimmed characterAtIndex:i];
        BOOL isInvalid = [invalid characterIsMember:ch] || ch < 32;
        BOOL isWhitespace = [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:ch];
        if (isInvalid || isWhitespace) {
            if (!previousSpace) [out appendString:@" "];
            previousSpace = YES;
        } else {
            [out appendFormat:@"%C", ch];
            previousSpace = NO;
        }
    }
    NSString *safe = TTTrimString(out);
    return safe.length > 0 ? safe : @"Untitled Project";
}

static NSString *TTProjectNameFromShotListManifest(NSString *manifestPath) {
    NSString *text = [NSString stringWithContentsOfFile:manifestPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) return @"";
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (lines.count < 2) return @"";
    NSArray<NSString *> *headers = [lines[0] componentsSeparatedByString:@"\t"];
    NSInteger projectIndex = [headers indexOfObject:@"project_name"];
    if (projectIndex == NSNotFound) return @"";
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if (line.length == 0) continue;
        NSArray<NSString *> *values = [line componentsSeparatedByString:@"\t"];
        if (projectIndex < (NSInteger)values.count) {
            return TTTrimString(values[projectIndex]);
        }
    }
    return @"";
}

static NSString *TTShotListWorkbookPath(NSString *manifestPath) {
    NSString *projectName = TTProjectNameFromShotListManifest(manifestPath);
    NSString *stem = projectName.length > 0
        ? [NSString stringWithFormat:@"VFX Shot List - %@", TTSafeFilenamePart(projectName)]
        : @"VFX Shot List";
    return [TTOldVFXShotListStatePath() stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"xlsx"]];
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

static NSString *TTChoosePath(NSString *prompt, BOOL canChooseFiles, BOOL canChooseDirectories, NSArray<NSString *> *allowedTypes) {
    return TTOnMainSync(^id{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = prompt ?: @"Choose File";
        panel.message = prompt ?: @"Choose File";
        panel.canChooseFiles = canChooseFiles;
        panel.canChooseDirectories = canChooseDirectories;
        panel.allowsMultipleSelection = NO;
        panel.canCreateDirectories = NO;
        if (allowedTypes.count > 0) {
            NSMutableArray<UTType *> *contentTypes = [NSMutableArray array];
            for (NSString *extension in allowedTypes) {
                UTType *type = [UTType typeWithFilenameExtension:extension];
                if (type) [contentTypes addObject:type];
            }
            if (contentTypes.count > 0) {
                panel.allowedContentTypes = contentTypes;
            }
        }
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

static NSDictionary *TTMarkerOptionsPrompt(void) {
    return TTOnMainSync(^id{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"VFX Auto Marker";
        alert.informativeText = @"Choose marker type. Marker renaming is optional and uses FCPXML import, so it is off by default for timeline stability.";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSStackView *stack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 360, 74)];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 8;

        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
        [popup addItemsWithTitles:@[@"standard", @"todo", @"chapter"]];
        [popup selectItemWithTitle:@"standard"];
        [stack addArrangedSubview:popup];

        NSButton *rename = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 360, 22)];
        rename.buttonType = NSButtonTypeSwitch;
        rename.title = @"Rename markers from VFX titles";
        rename.state = NSControlStateValueOff;
        [stack addArrangedSubview:rename];

        NSTextField *hint = [NSTextField wrappingLabelWithString:@"Optional. Uses FCPXML import and may be less stable on complex timelines."];
        hint.textColor = NSColor.secondaryLabelColor;
        [stack addArrangedSubview:hint];

        alert.accessoryView = stack;
        NSInteger response = [alert runModal];
        if (response != NSAlertFirstButtonReturn) return nil;
        return @{
            @"marker_kind": popup.titleOfSelectedItem ?: @"standard",
            @"rename_markers": @(rename.state == NSControlStateValueOn)
        };
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

typedef NSDictionary *(*TTSpliceKitHandler)(NSDictionary *);

static NSDictionary *TTCallSpliceKitHandlerSymbol(NSString *symbolName, NSDictionary *params) {
    if (symbolName.length == 0) return @{@"error": @"Missing SpliceKit handler symbol"};
    TTSpliceKitHandler handler = (TTSpliceKitHandler)dlsym(RTLD_DEFAULT, symbolName.UTF8String);
    if (!handler) {
        const char *err = dlerror();
        return @{
            @"error": [NSString stringWithFormat:@"SpliceKit handler not found: %@%@", symbolName, err ? [NSString stringWithFormat:@" (%s)", err] : @""]
        };
    }
    NSDictionary *result = handler(params ?: @{});
    if (![result isKindOfClass:NSDictionary.class]) {
        return @{@"error": [NSString stringWithFormat:@"Invalid response from %@", symbolName]};
    }
    return result;
}

static NSDictionary *TTPlaybackSeekSeconds(NSTimeInterval seconds) {
    NSDictionary *direct = TTCallSpliceKitHandlerSymbol(@"SpliceKit_handlePlaybackSeek", @{@"seconds": @(seconds)});
    if (!direct[@"error"]) return direct;

    NSString *code = [NSString stringWithFormat:@"sk.seek(%.6f)", seconds];
    NSDictionary *fallback = TTCallRPC(@"lua.execute", @{@"code": code});
    if (fallback[@"error"]) return direct;
    return fallback;
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
        @autoreleasepool {
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
        }
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
        @"version": TTTurnoverVersion,
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
    [lines addObject:[NSString stringWithFormat:@"Updates: %@", gUpdateStatusText ?: @"Not checked"]];
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
        NSString *message = output.length > 0 ? output : @"Planner failed or did not create patched FCPXML";
        NSString *fallbackReport = [NSString stringWithFormat:
            @"Conform Prep failed\n\nstage: planner\nsource_xml_path: %@\noutput_xml_path: %@\n\n%@\n",
            sourceXML,
            patchedXML,
            message
        ];
        TTWriteString(reportPath, fallbackReport, nil);
        return @{
            @"status": @"error",
            @"stage": @"planner",
            @"message": message,
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

static BOOL TTYesNoPrompt(NSString *title, NSString *message, NSString *yesTitle, NSString *noTitle) {
    NSNumber *answer = TTOnMainSync(^id{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = title ?: @"Turnover";
        alert.informativeText = message ?: @"";
        [alert addButtonWithTitle:yesTitle ?: @"Yes"];
        [alert addButtonWithTitle:noTitle ?: @"No"];
        NSInteger response = [alert runModal];
        return @(response == NSAlertFirstButtonReturn);
    });
    return answer.boolValue;
}

static NSDictionary *TTRunConformPrepVerify(void) {
    NSString *dataPath = TTPluginDataPath();
    NSString *scriptPath = [TTPluginRootPath() stringByAppendingPathComponent:@"scripts/verify_conform_prep.mjs"];
    NSString *nodePath = TTWhich(@"node");
    NSString *reportPath = [dataPath stringByAppendingPathComponent:@"Conform_Prep_Verify_Report.txt"];
    NSString *jsonPath = [dataPath stringByAppendingPathComponent:@"Conform_Prep_Verify_Report.json"];

    [[NSFileManager defaultManager] createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:reportPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:jsonPath error:nil];

    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(scriptPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing verifier: %@", scriptPath]};
    }

    TTSetRunMessage(@"Verify Conform Prep: choose original XML...");
    NSString *originalXML = TTChoosePath(@"Choose the original FCPXML or .fcpxmld bundle", YES, YES, @[@"fcpxml", @"fcpxmld"]);
    if (originalXML.length == 0) return @{@"status": @"cancelled", @"message": @"Original XML selection cancelled"};

    TTSetRunMessage(@"Verify Conform Prep: choose imported/re-exported XML...");
    NSString *importedXML = TTChoosePath(@"Choose the FCP-imported/re-exported Conform Prep FCPXML or .fcpxmld bundle", YES, YES, @[@"fcpxml", @"fcpxmld"]);
    if (importedXML.length == 0) return @{@"status": @"cancelled", @"message": @"Imported XML selection cancelled"};

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        scriptPath,
        @"--original-xml", originalXML,
        @"--imported-xml", importedXML,
        @"--report", reportPath,
        @"--json", jsonPath
    ]];

    if (TTYesNoPrompt(@"Conform Prep Verify", @"Do you want to include the generated patched XML too?", @"Choose Patched XML", @"Skip")) {
        NSString *patchedXML = TTChoosePath(@"Choose Conform_Prep_Patched.fcpxml or patched .fcpxmld bundle", YES, YES, @[@"fcpxml", @"fcpxmld"]);
        if (patchedXML.length > 0) {
            [args addObjectsFromArray:@[@"--patched-xml", patchedXML]];
        }
    }

    if (TTYesNoPrompt(@"Conform Prep Verify", @"Do you want to include Timeline Index CSV files?", @"Choose CSVs", @"Skip")) {
        NSString *originalIndex = TTChoosePath(@"Choose original Timeline Index CSV", YES, NO, @[@"csv"]);
        if (originalIndex.length == 0) return @{@"status": @"cancelled", @"message": @"Original Timeline Index selection cancelled"};
        NSString *importedIndex = TTChoosePath(@"Choose imported Timeline Index CSV", YES, NO, @[@"csv"]);
        if (importedIndex.length == 0) return @{@"status": @"cancelled", @"message": @"Imported Timeline Index selection cancelled"};
        [args addObjectsFromArray:@[@"--original-index", originalIndex, @"--imported-index", importedIndex]];
    }

    TTSetRunMessage(@"Verify Conform Prep: running...");
    NSDictionary *result = TTRunProcess(nodePath, args);
    NSString *output = result[@"output"] ?: @"";
    if (!TTFileExists(reportPath) && output.length > 0) {
        TTWriteString(reportPath, output, nil);
    }
    if (!TTFileExists(reportPath)) {
        return @{
            @"status": @"error",
            @"message": output.length > 0 ? output : @"Verifier did not create a report",
            @"report_path": reportPath
        };
    }

    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:reportPath]];
    TTSetRunMessage([NSString stringWithFormat:@"Verify Conform Prep complete\nReport: %@", reportPath]);
    return @{
        @"status": @"ok",
        @"verify_exit_code": result[@"exit_code"] ?: @0,
        @"report_path": reportPath,
        @"json_path": jsonPath,
        @"output": output
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

    // SpliceKit reuses one quota-limited Lua VM for the lifetime of FCP.
    // Reset around every standalone Turnover script so one project cannot
    // exhaust the allocator and crash a later run while loading its chunk.
    TTResetLuaVM();
    NSDictionary *result = TTCallRPC(@"lua.executeFile", @{@"path": path});
    TTResetLuaVM();
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

static NSDictionary *TTResetLuaVM(void) {
    NSDictionary *result = TTCallRPC(@"lua.reset", @{});
    return [result isKindOfClass:NSDictionary.class] ? result : @{@"error": @"Invalid lua.reset response"};
}

static NSDictionary *TTRunLuaCompatibilityScript(NSString *scriptName) {
    NSString *path = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:scriptName ?: @""];
    if (!TTFileExists(path)) {
        path = [TTMenuRootPath() stringByAppendingPathComponent:scriptName ?: @""];
    }
    return TTRunLuaFile(path);
}

static NSDictionary *TTRunAutoMarker(NSString *markerKind, BOOL renameMarkers) {
    NSDictionary<NSString *, NSString *> *actions = @{
        @"standard": @"addMarker",
        @"todo": @"addTodoMarker",
        @"chapter": @"addChapterMarker",
    };
    NSString *action = actions[markerKind ?: @""];
    if (action.length == 0) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Unknown marker kind: %@", markerKind ?: @""]};
    }

    NSString *configPath = [TTPluginDataPath() stringByAppendingPathComponent:@"VFX_Auto_Marker_Config.tsv"];
    NSError *configError = nil;
    BOOL wroteConfig = TTWriteKeyValueFile(configPath, @{
        @"marker_kind": markerKind ?: @"standard",
        @"rename_markers": renameMarkers ? @"true" : @"false",
    }, &configError);
    if (!wroteConfig) {
        return @{@"status": @"error", @"message": configError.localizedDescription ?: @"Could not write VFX Auto Marker config"};
    }

    if (renameMarkers) {
        NSDictionary<NSString *, NSString *> *scripts = @{
            @"standard": @"VFX Auto Marker - Standard.lua",
            @"todo": @"VFX Auto Marker - To Do.lua",
            @"chapter": @"VFX Auto Marker - Chapter.lua",
        };
        NSString *scriptName = scripts[markerKind ?: @""];
        NSString *path = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua/scripts"] stringByAppendingPathComponent:scriptName ?: @""];
        return TTRunLuaFile(path);
    }

    NSString *nodePath = TTWhich(@"node");
    NSString *stateDir = TTOldVFXShotListStatePath();
    NSString *sourceXML = [stateDir stringByAppendingPathComponent:@"VFX_Auto_Marker_Source.fcpxml"];
    NSString *planPath = [stateDir stringByAppendingPathComponent:@"VFX_Auto_Marker_Plan.tsv"];
    NSString *reportPath = [stateDir stringByAppendingPathComponent:@"VFX_Auto_Marker_Report.txt"];
    NSString *plannerPath = [[[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"scripts"] stringByAppendingPathComponent:@"build_vfx_auto_marker_plan.mjs"];

    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:sourceXML error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:planPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:reportPath error:nil];

    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(plannerPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing VFX Auto Marker planner: %@", plannerPath]};
    }

    TTSetRunMessage(@"VFX Auto Marker: exporting current project...");
    NSDictionary *exportResult = TTCallRPC(@"fcpxml.export", @{@"path": sourceXML});
    if (exportResult[@"error"]) {
        return @{@"status": @"error", @"stage": @"export", @"message": [exportResult[@"error"] description]};
    }
    if (!TTFileExists(sourceXML)) {
        return @{@"status": @"error", @"stage": @"export", @"message": @"Export did not create source FCPXML"};
    }

    TTSetRunMessage(@"VFX Auto Marker: planning markers...");
    NSDictionary *plannerResult = TTRunProcess(nodePath, @[
        plannerPath,
        @"--source-xml", sourceXML,
        @"--output-plan", planPath,
        @"--report", reportPath
    ]);
    if (![plannerResult[@"status"] isEqual:@"ok"]) {
        return @{
            @"status": @"error",
            @"stage": @"planner",
            @"message": plannerResult[@"output"] ?: @"VFX Auto Marker planner failed",
            @"source_xml_path": sourceXML,
            @"plan_path": planPath,
            @"report_path": reportPath
        };
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *rows = TTReadShotListManifestRows(planPath);
    if (rows.count == 0) {
        return @{
            @"status": @"error",
            @"stage": @"plan",
            @"message": @"VFX Auto Marker planner created no rows.",
            @"source_xml_path": sourceXML,
            @"plan_path": planPath,
            @"report_path": reportPath
        };
    }

    TTSetRunMessage([NSString stringWithFormat:@"VFX Auto Marker: creating markers 0/%lu...", (unsigned long)rows.count]);
    NSUInteger created = 0;
    for (NSDictionary<NSString *, NSString *> *row in rows) {
        NSString *index = TTTrimString(row[@"index"]);
        NSString *markerName = TTTrimString(row[@"marker_name"]);
        NSTimeInterval timelineSeconds = TTTrimString(row[@"timeline_seconds"]).doubleValue;
        NSUInteger displayIndex = (NSUInteger)MAX(1, index.integerValue);
        if (displayIndex == 1 || displayIndex == rows.count || displayIndex % 25 == 0) {
            TTSetRunMessage([NSString stringWithFormat:@"VFX Auto Marker: creating markers %lu/%lu...",
                (unsigned long)displayIndex,
                (unsigned long)rows.count]);
        }

        NSDictionary *seekResult = TTPlaybackSeekSeconds(timelineSeconds);
        if (seekResult[@"error"]) {
            return @{
                @"status": @"error",
                @"stage": @"seek",
                @"message": [NSString stringWithFormat:@"Could not seek to %.6f for %@: %@",
                    timelineSeconds,
                    markerName.length > 0 ? markerName : index,
                    [seekResult[@"error"] description]],
                @"plan_path": planPath,
                @"report_path": reportPath
            };
        }
        [NSThread sleepForTimeInterval:0.05];
        TTCallRPC(@"timeline.selectClipInLane", @{@"lane": @0});
        NSDictionary *actionResult = TTCallRPC(@"timeline.action", @{@"action": action});
        if (actionResult[@"error"]) {
            return @{
                @"status": @"error",
                @"stage": @"timeline_action",
                @"message": [NSString stringWithFormat:@"timeline.action failed for %@: %@",
                    markerName.length > 0 ? markerName : index,
                    [actionResult[@"error"] description]],
                @"plan_path": planPath,
                @"report_path": reportPath
            };
        }
        created++;
        [NSThread sleepForTimeInterval:0.05];
    }

    TTSetRunMessage(@"VFX Auto Marker: complete");
    return @{
        @"status": @"ok",
        @"created": @(created),
        @"marker_kind": markerKind ?: @"standard",
        @"source_xml_path": sourceXML,
        @"plan_path": planPath,
        @"report_path": reportPath
    };
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
    NSString *sourceXML = [stateDir stringByAppendingPathComponent:@"VFX_Pull_EDL_Source.fcpxml"];
    NSString *configPath = [stateDir stringByAppendingPathComponent:@"VFX_Pull_EDL_Config.tsv"];
    NSString *reportPath = [stateDir stringByAppendingPathComponent:@"VFX_Pull_EDL_Report.txt"];
    NSString *plannerPath = [[[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"scripts"] stringByAppendingPathComponent:@"build_vfx_pull_edl.mjs"];
    NSString *nodePath = TTWhich(@"node");
    NSString *outputDir = TTDesktopPath();

    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:sourceXML error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:reportPath error:nil];

    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(plannerPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing VFX Pull EDL planner: %@", plannerPath]};
    }

    NSError *error = nil;
    BOOL ok = TTWriteKeyValueFile(configPath, @{
        @"handle_frames": [NSString stringWithFormat:@"%ld", (long)totalHandleFrames],
        @"total_handle_frames": [NSString stringWithFormat:@"%ld", (long)totalHandleFrames],
    }, &error);
    if (!ok) {
        return @{@"status": @"error", @"message": error.localizedDescription ?: @"Could not write VFX Pull EDL config"};
    }

    TTSetRunMessage(@"VFX Pull EDL: exporting current project...");
    NSDictionary *exportResult = TTCallRPC(@"fcpxml.export", @{@"path": sourceXML});
    if (exportResult[@"error"]) {
        return @{@"status": @"error", @"stage": @"export", @"message": [exportResult[@"error"] description]};
    }
    if (!TTFileExists(sourceXML)) {
        return @{@"status": @"error", @"stage": @"export", @"message": @"Export did not create source FCPXML"};
    }

    TTSetRunMessage(@"VFX Pull EDL: building EDL...");
    NSDictionary *plannerResult = TTRunProcess(nodePath, @[
        plannerPath,
        @"--source-xml", sourceXML,
        @"--config", configPath,
        @"--output-dir", outputDir,
        @"--report", reportPath
    ]);
    if (![plannerResult[@"status"] isEqual:@"ok"]) {
        return @{
            @"status": @"error",
            @"stage": @"planner",
            @"message": plannerResult[@"output"] ?: @"VFX Pull EDL planner failed",
            @"source_xml_path": sourceXML,
            @"config_path": configPath,
            @"report_path": reportPath
        };
    }

    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:outputDir]];
    TTSetRunMessage(@"VFX Pull EDL: complete");
    return @{
        @"status": @"ok",
        @"source_xml_path": sourceXML,
        @"config_path": configPath,
        @"report_path": reportPath,
        @"output_folder": outputDir,
        @"output": plannerResult[@"output"] ?: @""
    };
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

static NSURL *TTOrganizeShotListOutputs(NSURL *workbookURL, NSString *thumbDir, BOOL cleanupTemp) {
    if (!workbookURL) return nil;
    NSString *stem = workbookURL.URLByDeletingPathExtension.lastPathComponent ?: @"VFX Shot List";
    NSString *outputDir = [TTDesktopPath() stringByAppendingPathComponent:stem];
    NSString *finalWorkbook = [outputDir stringByAppendingPathComponent:workbookURL.lastPathComponent];
    thumbDir = thumbDir.length > 0 ? thumbDir : [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    NSString *finalThumbDir = [outputDir stringByAppendingPathComponent:@"Thumbnails"];

    [[NSFileManager defaultManager] createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalWorkbook error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:finalThumbDir error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:workbookURL.path toPath:finalWorkbook error:nil];
    if (TTFileExists(thumbDir)) {
        if (cleanupTemp) {
            [[NSFileManager defaultManager] moveItemAtPath:thumbDir toPath:finalThumbDir error:nil];
        } else {
            [[NSFileManager defaultManager] copyItemAtPath:thumbDir toPath:finalThumbDir error:nil];
        }
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:finalThumbDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    if (cleanupTemp) {
        for (NSString *dirName in @[@"VFX_Shot_List_Captures_Raw", @"VFX_Shot_List_Captures_16x9"]) {
            [[NSFileManager defaultManager] removeItemAtPath:[TTDesktopPath() stringByAppendingPathComponent:dirName] error:nil];
        }
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

static NSArray<NSString *> *TTReadNonEmptyLines(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
            [lines addObject:line];
        }
    }
    return lines;
}

static BOOL TTAppendString(NSString *path, NSString *text, NSError **error) {
    if (path.length == 0) return NO;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [text ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    if (!TTFileExists(path)) {
        return [data writeToFile:path options:0 error:error];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return NO;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"Turnover" code:7 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Could not append file"}];
        }
        return NO;
    }
}

static NSString *TTTSVUnescape(NSString *value) {
    NSString *input = value ?: @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:input.length];
    BOOL escaping = NO;
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar ch = [input characterAtIndex:i];
        if (escaping) {
            if (ch == 't') [out appendString:@"\t"];
            else if (ch == 'n') [out appendString:@"\n"];
            else if (ch == 'r') [out appendString:@"\r"];
            else [out appendFormat:@"%C", ch];
            escaping = NO;
        } else if (ch == '\\') {
            escaping = YES;
        } else {
            [out appendFormat:@"%C", ch];
        }
    }
    if (escaping) [out appendString:@"\\"];
    return out;
}

static NSArray<NSDictionary<NSString *, NSString *> *> *TTReadShotListManifestRows(NSString *path) {
    NSArray<NSString *> *lines = TTReadNonEmptyLines(path);
    if (lines.count < 2) return @[];
    NSArray<NSString *> *headers = [lines.firstObject componentsSeparatedByString:@"\t"];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows = [NSMutableArray array];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSArray<NSString *> *values = [lines[i] componentsSeparatedByString:@"\t"];
        NSMutableDictionary<NSString *, NSString *> *row = [NSMutableDictionary dictionary];
        for (NSUInteger j = 0; j < headers.count; j++) {
            NSString *key = headers[j];
            if (key.length == 0) continue;
            NSString *value = j < values.count ? values[j] : @"";
            row[key] = TTTSVUnescape(value);
        }
        if ([TTTrimString(row[@"index"]) length] > 0) {
            [rows addObject:row];
        }
    }
    return rows;
}

static NSString *TTShotListFullCaptureName(NSDictionary<NSString *, NSString *> *row) {
    NSString *thumbName = TTTrimString(row[@"suggested_thumb_name"]);
    if (thumbName.length > 0) {
        NSString *stem = [thumbName stringByDeletingPathExtension];
        return [stem stringByAppendingPathExtension:@"png"];
    }
    NSString *index = TTTrimString(row[@"index"]);
    NSString *vfx = TTTrimString(row[@"vfx_number"]);
    if (index.length == 0) index = @"000";
    if (vfx.length == 0) vfx = @"VFX";
    return [[NSString stringWithFormat:@"%@_%@", index, TTSafeFilenamePart(vfx)] stringByAppendingPathExtension:@"png"];
}

static NSTimeInterval TTShotListCaptureSeconds(NSDictionary<NSString *, NSString *> *row) {
    NSString *capture = TTTrimString(row[@"capture_seconds"]);
    if (capture.length > 0) return capture.doubleValue;
    return TTTrimString(row[@"timeline_seconds"]).doubleValue;
}

static NSArray<NSString *> *TTImageFilesInFolder(NSString *folder) {
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil] ?: @[];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg"]];
    for (NSString *item in items) {
        if ([extensions containsObject:[[item pathExtension] lowercaseString]]) {
            [images addObject:item];
        }
    }
    return [images sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

static NSDictionary *TTNormalizeShotListThumbnailsFromFolder(NSString *sourceFolder,
                                                             NSArray<NSDictionary<NSString *, NSString *> *> *rows,
                                                             NSString *thumbDir,
                                                             NSString *captureDir) {
    [[NSFileManager defaultManager] createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:captureDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *images = TTImageFilesInFolder(sourceFolder);
    NSMutableDictionary<NSString *, NSString *> *byLowerName = [NSMutableDictionary dictionary];
    for (NSString *image in images) {
        byLowerName[[image lowercaseString]] = image;
    }

    NSUInteger exactMatches = 0;
    for (NSDictionary<NSString *, NSString *> *row in rows) {
        NSString *expectedThumb = TTTrimString(row[@"suggested_thumb_name"]);
        if (expectedThumb.length > 0 && byLowerName[[expectedThumb lowercaseString]]) {
            exactMatches++;
        }
    }
    BOOL useSequentialFallback = exactMatches < rows.count && images.count >= rows.count;

    NSUInteger processed = 0;
    NSUInteger failed = 0;
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        NSDictionary<NSString *, NSString *> *row = rows[i];
        NSString *expectedThumb = TTTrimString(row[@"suggested_thumb_name"]);
        if (expectedThumb.length == 0) {
            expectedThumb = [[[TTShotListFullCaptureName(row) stringByDeletingPathExtension] lastPathComponent] stringByAppendingPathExtension:@"jpg"];
        }
        NSString *sourceName = byLowerName[[expectedThumb lowercaseString]];
        if (sourceName.length == 0 && useSequentialFallback && i < images.count) {
            sourceName = images[i];
        }
        if (sourceName.length == 0) {
            failed++;
            [messages addObject:[NSString stringWithFormat:@"Missing thumbnail for %@", expectedThumb]];
            continue;
        }

        NSString *sourcePath = [sourceFolder stringByAppendingPathComponent:sourceName];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:sourcePath];
        CGImageRef cgImage = [image CGImageForProposedRect:nil context:nil hints:nil];
        if (!cgImage) {
            failed++;
            [messages addObject:[NSString stringWithFormat:@"Could not decode %@", sourceName]];
            continue;
        }

        NSString *captureName = [[expectedThumb stringByDeletingPathExtension] stringByAppendingPathExtension:@"png"];
        NSString *capturePath = [captureDir stringByAppendingPathComponent:captureName];
        NSString *thumbPath = [thumbDir stringByAppendingPathComponent:expectedThumb];
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
            [messages addObject:[NSString stringWithFormat:@"%@: %@", sourceName, error.localizedDescription ?: @"write failed"]];
        }
    }

    NSString *mode = useSequentialFallback ? @"sequential" : @"filename";
    return @{
        @"status": failed == 0 ? @"ok" : @"partial",
        @"processed": @(processed),
        @"failed": @(failed),
        @"source_count": @(images.count),
        @"exact_matches": @(exactMatches),
        @"matching_mode": mode,
        @"message": [messages componentsJoinedByString:@"\n"]
    };
}

static NSUInteger TTCountTSVDataRows(NSString *path) {
    NSArray<NSString *> *lines = TTReadNonEmptyLines(path);
    return lines.count > 0 ? lines.count - 1 : 0;
}

static BOOL TTProgressHasDoneLine(NSString *path) {
    for (NSString *line in TTReadNonEmptyLines(path)) {
        if ([line hasPrefix:@"done\t"]) {
            return YES;
        }
    }
    return NO;
}

static NSString *TTLastProgressLine(NSString *path) {
    NSArray<NSString *> *lines = TTReadNonEmptyLines(path);
    return lines.lastObject ?: @"";
}

static NSDictionary *TTPostProcessShotListCaptures(NSString *captureDir, NSString *thumbDir) {
    NSString *desktop = TTDesktopPath();
    captureDir = captureDir.length > 0 ? captureDir : [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    thumbDir = thumbDir.length > 0 ? thumbDir : [desktop stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    [[NSFileManager defaultManager] createDirectoryAtPath:captureDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:captureDir error:nil] ?: @[];
    NSUInteger processed = 0;
    NSUInteger failed = 0;
    NSUInteger total = 0;
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    for (NSString *item in items) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"png"]) {
            total++;
        }
    }

    for (NSString *item in items) {
        if (![[item.pathExtension lowercaseString] isEqualToString:@"png"]) continue;
        @autoreleasepool {
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
    }

    return @{
        @"status": failed == 0 ? @"ok" : @"partial",
        @"processed": @(processed),
        @"failed": @(failed),
        @"message": [messages componentsJoinedByString:@"\n"]
    };
}

static NSDictionary *TTGenerateShotListExcel(NSString *manifestPath, NSString *captureDir, NSString *thumbDir, BOOL cleanupTemp) {
    NSString *nodePath = TTWhich(@"node");
    NSString *generatorPath = [[[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"scripts"] stringByAppendingPathComponent:@"generate_vfx_shot_list_excel.mjs"];
    thumbDir = thumbDir.length > 0 ? thumbDir : [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    captureDir = captureDir.length > 0 ? captureDir : [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    NSString *outputPath = TTShotListWorkbookPath(manifestPath);
    if (nodePath.length == 0) {
        return @{@"status": @"error", @"message": @"Node.js runtime not found"};
    }
    if (!TTFileExists(generatorPath)) {
        return @{@"status": @"error", @"message": [NSString stringWithFormat:@"Missing generator: %@", generatorPath]};
    }
    NSDictionary *result = TTRunProcess(nodePath, @[
        generatorPath,
        @"--manifest", manifestPath ?: @"",
        @"--captures", captureDir,
        @"--thumbs", thumbDir,
        @"--output", outputPath ?: @""
    ]);
    if (![result[@"status"] isEqual:@"ok"]) {
        return @{@"status": @"error", @"message": result[@"output"] ?: @"Excel generator failed"};
    }

    NSURL *workbookURL = TTFileExists(outputPath) ? [NSURL fileURLWithPath:outputPath] : TTNewestWorkbookURL();
    if (!workbookURL) {
        return @{
            @"status": @"error",
            @"message": [NSString stringWithFormat:@"Excel generator finished, but no workbook was found. Expected: %@\n%@", outputPath ?: @"", result[@"output"] ?: @""]
        };
    }
    NSURL *outputDir = TTOrganizeShotListOutputs(workbookURL, thumbDir, cleanupTemp);
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
    [NSThread sleepForTimeInterval:0.20];
    for (NSUInteger i = 0; i < 5; i++) {
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
        if (!source) continue;
        CGEventRef down = CGEventCreateKeyboardEvent(source, 53, true);
        CGEventRef up = CGEventCreateKeyboardEvent(source, 53, false);
        if (down) {
            CGEventPost(kCGHIDEventTap, down);
            CGEventPost(kCGSessionEventTap, down);
        }
        [NSThread sleepForTimeInterval:0.04];
        if (up) {
            CGEventPost(kCGHIDEventTap, up);
            CGEventPost(kCGSessionEventTap, up);
        }
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        CFRelease(source);
        [NSThread sleepForTimeInterval:0.12];
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
    NSString *donePath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Done.flag"];
    NSString *manifestOnlyPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Manifest_Only.flag"];
    NSString *nativeLogPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Native_Capture.log"];
    NSString *scriptPath = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"VFX Shot List.lua"];

    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *path in @[progressPath, manifestPath, reportPath, donePath, manifestOnlyPath, nativeLogPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    TTWriteString(readyPath, [[NSDate date] description], nil);
    TTWriteString(manifestOnlyPath, [[NSDate date] description], nil);
    TTAppendLog(nativeLogPath, @"native shot list run");

    NSString *desktop = TTDesktopPath();
    for (NSString *dirName in @[@"VFX_Shot_List_Captures_Raw", @"VFX_Shot_List_Captures_16x9", @"VFX_Shot_List_Captures_Thumb"]) {
        [[NSFileManager defaultManager] removeItemAtPath:[desktop stringByAppendingPathComponent:dirName] error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:[desktop stringByAppendingPathComponent:dirName]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    NSString *defaultCaptureDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    NSString *defaultThumbDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];
    TTSetRunMessage(@"VFX Shot List: preparing shot manifest...");
    NSDictionary *luaResult = TTRunLuaFile(scriptPath);
    [[NSFileManager defaultManager] removeItemAtPath:readyPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:manifestOnlyPath error:nil];
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"lua status=%@", luaResult[@"status"] ?: @""]);
    if (![luaResult[@"status"] isEqual:@"ok"]) {
        return luaResult;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *manifestRowsData = TTReadShotListManifestRows(manifestPath);
    NSUInteger manifestRows = manifestRowsData.count;
    if (manifestRows == 0) {
        return @{
            @"status": @"error",
            @"stage": @"manifest",
            @"message": @"VFX Shot List manifest was not created or has no rows.",
            @"manifest_path": manifestPath,
            @"progress_path": progressPath,
            @"native_log_path": nativeLogPath
        };
    }

    TTWriteString(progressPath, @"status\tindex\tmarker_name\ttimeline_seconds\tfull_capture_name\tthumb_name\n", nil);

    TTSetRunMessage([NSString stringWithFormat:@"VFX Shot List: capturing viewer frames 0/%lu...", (unsigned long)manifestRows]);
    NSDictionary *enterResult = TTCallRPC(@"menu.execute", @{@"menuPath": @[@"View", @"Playback", @"Play Full Screen"]});
    if (enterResult[@"error"]) {
        return @{
            @"status": @"error",
            @"stage": @"fullscreen",
            @"message": [enterResult[@"error"] description],
            @"manifest_path": manifestPath,
            @"native_log_path": nativeLogPath
        };
    }
    [NSThread sleepForTimeInterval:0.08];
    TTCallRPC(@"menu.execute", @{@"menuPath": @[@"View", @"Playback", @"Play"]});
    [NSThread sleepForTimeInterval:0.08];

    NSUInteger captured = 0;
    for (NSDictionary<NSString *, NSString *> *row in manifestRowsData) {
        @autoreleasepool {
        NSString *index = TTTrimString(row[@"index"]);
        NSString *markerName = TTTrimString(row[@"vfx_number"]);
        NSString *fullName = TTShotListFullCaptureName(row);
        NSString *thumbName = TTTrimString(row[@"suggested_thumb_name"]);
        if (thumbName.length == 0) {
            thumbName = [[fullName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        }
        NSTimeInterval captureSeconds = TTShotListCaptureSeconds(row);
        NSUInteger displayIndex = (NSUInteger)MAX(1, index.integerValue);
        if (displayIndex == 1 || displayIndex == manifestRows || displayIndex % 10 == 0) {
            TTSetRunMessage([NSString stringWithFormat:@"VFX Shot List: capturing viewer frames %lu/%lu...",
                (unsigned long)displayIndex,
                (unsigned long)manifestRows]);
        }

        NSDictionary *seekResult = TTPlaybackSeekSeconds(captureSeconds);
        if (seekResult[@"error"]) {
            TTSendEscapeToFinalCut();
            return @{
                @"status": @"error",
                @"stage": @"seek",
                @"message": [NSString stringWithFormat:@"Could not seek to %.6f for %@: %@",
                    captureSeconds,
                    markerName.length > 0 ? markerName : index,
                    [seekResult[@"error"] description]],
                @"manifest_path": manifestPath,
                @"progress_path": progressPath,
                @"native_log_path": nativeLogPath
            };
        }

        [NSThread sleepForTimeInterval:0.18];
        NSString *capturePath = [defaultCaptureDir stringByAppendingPathComponent:fullName];
        NSDictionary *captureResult = TTCaptureLargestFCPWindow(capturePath);
        if (![captureResult[@"status"] isEqual:@"ok"] || !TTFileExists(capturePath)) {
            TTSendEscapeToFinalCut();
            return @{
                @"status": @"error",
                @"stage": @"capture",
                @"message": [NSString stringWithFormat:@"Capture failed at %@ %@: %@",
                    index,
                    markerName,
                    captureResult[@"message"] ?: captureResult[@"error"] ?: @"unknown capture error"],
                @"expected": @(manifestRows),
                @"captures": @(captured),
                @"manifest_path": manifestPath,
                @"progress_path": progressPath,
                @"native_log_path": nativeLogPath
            };
        }
        captured++;
        TTAppendString(progressPath, [NSString stringWithFormat:@"ready\t%@\t%@\t%.6f\t%@\t%@\n",
            index,
            markerName,
            captureSeconds,
            fullName,
            thumbName], nil);
        [NSThread sleepForTimeInterval:0.04];
        }
    }

    TTSendEscapeToFinalCut();
    TTAppendString(progressPath, [NSString stringWithFormat:@"done\t%lu\t\t\t\t\n", (unsigned long)captured], nil);
    TTWriteString(donePath, @"done\n", nil);
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"native capture complete expected=%lu captured=%lu",
        (unsigned long)manifestRows,
        (unsigned long)captured]);

    NSUInteger directCaptureCount = TTCountFilesWithExtension(defaultCaptureDir, @"png");
    BOOL progressDone = TTProgressHasDoneLine(progressPath);
    if (!progressDone || directCaptureCount < manifestRows) {
        return @{
            @"status": @"error",
            @"stage": @"capture",
            @"message": [NSString stringWithFormat:@"Capture did not complete. Expected %lu thumbnails, captured %lu. Last progress: %@",
                (unsigned long)manifestRows,
                (unsigned long)directCaptureCount,
                TTLastProgressLine(progressPath)],
            @"expected": @(manifestRows),
            @"captures": @(directCaptureCount),
            @"manifest_path": manifestPath,
            @"progress_path": progressPath,
            @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"VFX Shot List: cropping thumbnails...");
    NSDictionary *postProcess = TTPostProcessShotListCaptures(defaultCaptureDir, defaultThumbDir);
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"postprocess status=%@ processed=%@ failed=%@",
        postProcess[@"status"] ?: @"",
        postProcess[@"processed"] ?: @0,
        postProcess[@"failed"] ?: @0]);
    NSUInteger thumbCount = TTCountFilesWithExtension(defaultThumbDir, @"jpg");
    if (thumbCount < manifestRows) {
        return @{
            @"status": @"error",
            @"stage": @"thumbnail",
            @"message": [NSString stringWithFormat:@"Thumbnail generation incomplete. Expected %lu thumbnails, created %lu. %@",
                (unsigned long)manifestRows,
                (unsigned long)thumbCount,
                postProcess[@"message"] ?: @""],
            @"expected": @(manifestRows),
            @"captures": @(directCaptureCount),
            @"thumbnails": @(thumbCount),
            @"report_path": reportPath,
            @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"VFX Shot List: generating Excel workbook... this can take a moment.");
    NSDictionary *excel = TTGenerateShotListExcel(manifestPath, defaultCaptureDir, defaultThumbDir, YES);
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"excel status=%@ output_folder=%@ workbook=%@ message=%@",
        excel[@"status"] ?: @"",
        excel[@"output_folder"] ?: @"",
        excel[@"workbook_path"] ?: @"",
        excel[@"message"] ?: @""]);
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

    TTSetRunMessage([NSString stringWithFormat:@"VFX Shot List complete\nOutput: %@",
        excel[@"output_folder"] ?: @""]);
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

static NSDictionary *TTRunGenerateVFXShotListFromThumbnails(void) {
    NSString *stateDir = TTOldVFXShotListStatePath();
    NSString *readyPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Worker_Ready.flag"];
    NSString *manifestPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Manifest.tsv"];
    NSString *progressPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Progress.tsv"];
    NSString *reportPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Report.txt"];
    NSString *donePath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Done.flag"];
    NSString *manifestOnlyPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Manifest_Only.flag"];
    NSString *nativeLogPath = [stateDir stringByAppendingPathComponent:@"VFX_Shot_List_Native_Capture.log"];
    NSString *scriptPath = [[TTPluginRootPath() stringByAppendingPathComponent:@"lua"] stringByAppendingPathComponent:@"VFX Shot List.lua"];
    NSString *captureDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_16x9"];
    NSString *thumbDir = [TTDesktopPath() stringByAppendingPathComponent:@"VFX_Shot_List_Captures_Thumb"];

    [[NSFileManager defaultManager] createDirectoryAtPath:stateDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *path in @[manifestPath, progressPath, reportPath, donePath, manifestOnlyPath, nativeLogPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    TTAppendLog(nativeLogPath, @"generate shot list from thumbnails run");

    TTSetRunMessage(@"Generate VFX Shot List: choose existing thumbnail folder...");
    NSString *sourceThumbFolder = TTChooseFolder(@"Choose existing VFX thumbnail/capture folder");
    if (sourceThumbFolder.length == 0) {
        return @{@"status": @"cancelled", @"message": @"Thumbnail folder selection cancelled"};
    }

    NSUInteger sourceImageCount = TTImageFilesInFolder(sourceThumbFolder).count;
    if (sourceImageCount == 0) {
        return @{
            @"status": @"error",
            @"stage": @"thumbnail_folder",
            @"message": @"No PNG/JPG thumbnails found in the selected folder.",
            @"thumbnail_folder": sourceThumbFolder
        };
    }

    TTWriteString(readyPath, [[NSDate date] description], nil);
    TTWriteString(manifestOnlyPath, [[NSDate date] description], nil);
    TTSetRunMessage(@"Generate VFX Shot List: exporting current timeline data...");
    NSDictionary *luaResult = TTRunLuaFile(scriptPath);
    [[NSFileManager defaultManager] removeItemAtPath:readyPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:manifestOnlyPath error:nil];
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"manifest lua status=%@", luaResult[@"status"] ?: @""]);
    if (![luaResult[@"status"] isEqual:@"ok"]) {
        return luaResult;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *rows = TTReadShotListManifestRows(manifestPath);
    if (rows.count == 0) {
        return @{
            @"status": @"error",
            @"stage": @"manifest",
            @"message": @"Current timeline did not produce a VFX Shot List manifest.",
            @"manifest_path": manifestPath,
            @"native_log_path": nativeLogPath
        };
    }

    [[NSFileManager defaultManager] removeItemAtPath:captureDir error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:thumbDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:captureDir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:thumbDir withIntermediateDirectories:YES attributes:nil error:nil];

    TTSetRunMessage(@"Generate VFX Shot List: matching and resizing thumbnails...");
    NSDictionary *normalize = TTNormalizeShotListThumbnailsFromFolder(sourceThumbFolder, rows, thumbDir, captureDir);
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"thumbnail normalize status=%@ processed=%@ failed=%@ source=%@ exact=%@ mode=%@",
        normalize[@"status"] ?: @"",
        normalize[@"processed"] ?: @0,
        normalize[@"failed"] ?: @0,
        normalize[@"source_count"] ?: @0,
        normalize[@"exact_matches"] ?: @0,
        normalize[@"matching_mode"] ?: @""]);

    NSUInteger thumbCount = TTCountFilesWithExtension(thumbDir, @"jpg");
    if (thumbCount < rows.count) {
        return @{
            @"status": @"error",
            @"stage": @"thumbnail",
            @"message": [NSString stringWithFormat:@"Thumbnail matching incomplete. Expected %lu, created %lu. %@",
                (unsigned long)rows.count,
                (unsigned long)thumbCount,
                normalize[@"message"] ?: @""],
            @"expected": @(rows.count),
            @"manifest_path": manifestPath,
            @"thumbnail_folder": sourceThumbFolder,
            @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"Generate VFX Shot List: generating Excel...");
    NSDictionary *excel = TTGenerateShotListExcel(manifestPath, captureDir, thumbDir, YES);
    TTAppendLog(nativeLogPath, [NSString stringWithFormat:@"generate excel status=%@ output_folder=%@ workbook=%@ message=%@",
        excel[@"status"] ?: @"",
        excel[@"output_folder"] ?: @"",
        excel[@"workbook_path"] ?: @"",
        excel[@"message"] ?: @""]);
    if (![excel[@"status"] isEqual:@"ok"]) {
        return @{
            @"status": @"error",
            @"stage": @"excel",
            @"message": excel[@"message"] ?: @"Excel generation failed",
            @"expected": @(rows.count),
            @"thumbnails": @(thumbCount),
            @"manifest_path": manifestPath,
            @"thumbnail_folder": sourceThumbFolder,
            @"native_log_path": nativeLogPath
        };
    }

    TTSetRunMessage(@"Generate VFX Shot List: complete");
    return @{
        @"status": @"ok",
        @"expected": @(rows.count),
        @"source_images": @(sourceImageCount),
        @"thumbnails": @(thumbCount),
        @"manifest_path": manifestPath,
        @"thumbnail_folder": sourceThumbFolder,
        @"matching_mode": normalize[@"matching_mode"] ?: @"",
        @"output_folder": excel[@"output_folder"] ?: @"",
        @"native_log_path": nativeLogPath
    };
}

static NSDictionary *TTRunTool(NSString *toolId) {
    if ([toolId isEqualToString:@"conform_prep"]) return TTRunConformPrep();
    if ([toolId isEqualToString:@"conform_prep_verify"]) return TTRunConformPrepVerify();
    if ([toolId isEqualToString:@"vfx_timeline"]) return TTRunVFXTimeline();
    if ([toolId isEqualToString:@"vfx_shot_list"]) return TTRunVFXShotList();
    if ([toolId isEqualToString:@"vfx_shot_list_recover"]) return TTRunGenerateVFXShotListFromThumbnails();
    if ([toolId isEqualToString:@"vfx_pull_edl"]) return TTRunVFXPullEDL();
    if ([toolId isEqualToString:@"vfx_auto_marker"]) {
        NSDictionary *options = TTMarkerOptionsPrompt();
        if (!options) return @{@"status": @"cancelled", @"message": @"Marker selection cancelled"};
        NSString *kind = [options[@"marker_kind"] isKindOfClass:NSString.class] ? options[@"marker_kind"] : @"standard";
        BOOL rename = [options[@"rename_markers"] boolValue];
        return TTRunAutoMarker(kind, rename);
    }
    if ([toolId isEqualToString:@"vfx_auto_marker_standard"]) return TTRunAutoMarker(@"standard", NO);
    if ([toolId isEqualToString:@"vfx_auto_marker_todo"]) return TTRunAutoMarker(@"todo", NO);
    if ([toolId isEqualToString:@"vfx_auto_marker_chapter"]) return TTRunAutoMarker(@"chapter", NO);

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

- (void)checkForUpdates:(id)sender {
    BOOL showResult = sender != nil;
    gUpdateStatusText = @"Checking...";
    [self refresh:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = TTLatestReleaseInfo();
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = [result[@"status"] isEqual:@"ok"];
            BOOL available = [result[@"update_available"] boolValue];
            NSString *tag = [result[@"tag"] description] ?: @"";
            if (!ok) {
                gUpdateStatusText = @"Check failed";
            } else if (available) {
                gUpdateStatusText = [NSString stringWithFormat:@"%@ available", tag];
            } else {
                gUpdateStatusText = @"Up to date";
            }
            [self refresh:nil];

            if (available || showResult) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = available ? @"Turnover update available" : (ok ? @"Turnover is up to date" : @"Update check failed");
                alert.informativeText = available
                    ? [NSString stringWithFormat:@"Turnover %@ is available. You are using %@.", tag, TTTurnoverVersion]
                    : (ok ? [NSString stringWithFormat:@"You are using the latest version (%@).", TTTurnoverVersion] : ([result[@"message"] description] ?: @"Could not reach GitHub Releases."));
                if (available) [alert addButtonWithTitle:@"Open Download Page"];
                [alert addButtonWithTitle:@"OK"];
                NSModalResponse response = [alert runModal];
                if (available && response == NSAlertFirstButtonReturn) {
                    NSString *releaseURL = [result[@"url"] description] ?: TTLatestReleaseURL;
                    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:releaseURL]];
                }
            }
        });
    });
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

- (void)runConformPrepVerify:(__unused id)sender {
    TTSetRunMessage(@"Verify Conform Prep: queued...");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = TTRunConformPrepVerify();
        NSString *status = [result[@"status"] description] ?: @"unknown";
        NSString *message = [result[@"message"] description] ?: @"";
        if ([status isEqualToString:@"ok"]) {
            TTSetRunMessage([NSString stringWithFormat:@"Verify Conform Prep complete\nReport: %@", result[@"report_path"] ?: @""]);
        } else if ([status isEqualToString:@"cancelled"]) {
            TTSetRunMessage(@"Verify Conform Prep cancelled");
        } else {
            TTSetRunMessage([NSString stringWithFormat:@"Verify Conform Prep failed: %@", message]);
        }
    });
}

- (void)runRecoverVFXShotList:(__unused id)sender {
    TTSetRunMessage(@"Generate VFX Shot List: queued...");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = TTRunGenerateVFXShotListFromThumbnails();
        NSString *status = [result[@"status"] description] ?: @"unknown";
        NSString *message = [result[@"message"] description] ?: @"";
        if ([status isEqualToString:@"ok"]) {
            TTSetRunMessage([NSString stringWithFormat:@"Generate VFX Shot List complete\nOutput: %@", result[@"output_folder"] ?: @""]);
        } else if ([status isEqualToString:@"cancelled"]) {
            TTSetRunMessage(@"Generate VFX Shot List cancelled");
        } else {
            TTSetRunMessage([NSString stringWithFormat:@"Generate VFX Shot List failed: %@", message]);
        }
    });
}

- (void)runMenuTool:(NSMenuItem *)sender {
    NSString *toolId = [sender.representedObject isKindOfClass:NSString.class] ? sender.representedObject : @"";
    NSString *label = sender.title ?: toolId;
    @synchronized ([TTPanelController class]) {
        if (gToolRunInProgress) {
            TTSetRunMessage([NSString stringWithFormat:@"%@ was not started because another Turnover tool is still running.", label]);
            return;
        }
        gToolRunInProgress = YES;
    }
    TTSetRunMessage([NSString stringWithFormat:@"%@: queued...", label]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @try {
                NSDictionary *result = TTRunTool(toolId);
                NSString *status = [result[@"status"] description] ?: @"unknown";
                NSString *message = [result[@"message"] description] ?: @"";
                if ([status isEqualToString:@"ok"]) {
                    NSString *outputFolder = [result[@"output_folder"] isKindOfClass:NSString.class] ? result[@"output_folder"] : @"";
                    if (outputFolder.length > 0) {
                        TTSetRunMessage([NSString stringWithFormat:@"%@ complete\nOutput: %@", label, outputFolder]);
                    } else {
                        TTSetRunMessage([NSString stringWithFormat:@"%@ complete", label]);
                    }
                } else {
                    TTSetRunMessage([NSString stringWithFormat:@"%@ failed: %@", label, message]);
                }
            } @catch (NSException *exception) {
                TTSetRunMessage([NSString stringWithFormat:@"%@ failed: %@", label, exception.reason ?: exception.name]);
            } @finally {
                @synchronized ([TTPanelController class]) {
                    gToolRunInProgress = NO;
                }
            }
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
        gPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 390)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        gPanel.title = @"Turnover";
        gPanel.releasedWhenClosed = NO;

        NSStackView *root = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 560, 390)];
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

        NSStackView *verifyButtons = [[NSStackView alloc] init];
        verifyButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        verifyButtons.spacing = 8;
        [verifyButtons addArrangedSubview:TTButton(@"Check for Updates", @selector(checkForUpdates:))];
        [verifyButtons addArrangedSubview:TTButton(@"Verify Conform Prep", @selector(runConformPrepVerify:))];
        [verifyButtons addArrangedSubview:TTButton(@"Generate VFX Shot List", @selector(runRecoverVFXShotList:))];
        [root addArrangedSubview:verifyButtons];

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
    if (!gDidAutoCheckForUpdates) {
        gDidAutoCheckForUpdates = YES;
        [gController checkForUpdates:nil];
    }
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

static NSDictionary *TTHandleConformPrepVerify(__unused NSDictionary *params) {
    return TTRunTool(@"conform_prep_verify");
}

static NSDictionary *TTHandleRunTool(NSDictionary *params) {
    NSString *toolId = [params[@"tool_id"] isKindOfClass:NSString.class] ? params[@"tool_id"] : @"";
    return TTRunTool(toolId);
}

static NSDictionary *TTHandleVFXTimeline(__unused NSDictionary *params) {
    return TTRunTool(@"vfx_timeline");
}

static NSDictionary *TTHandleRecoverVFXShotList(__unused NSDictionary *params) {
    return TTRunTool(@"vfx_shot_list_recover");
}

static NSDictionary *TTHandleAutoMarker(NSDictionary *params) {
    NSString *kind = [params[@"marker_kind"] isKindOfClass:NSString.class] ? params[@"marker_kind"] : @"standard";
    BOOL rename = [params[@"rename_markers"] respondsToSelector:@selector(boolValue)] ? [params[@"rename_markers"] boolValue] : NO;
    if ([kind isEqualToString:@"todo"]) return TTRunAutoMarker(@"todo", rename);
    if ([kind isEqualToString:@"chapter"]) return TTRunAutoMarker(@"chapter", rename);
    return TTRunAutoMarker(@"standard", rename);
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

    api->registerMethod(@"com.turnover.tools.conform_prep_verify", ^NSDictionary *(NSDictionary *params) {
        return TTHandleConformPrepVerify(params);
    }, @{
        @"description": @"Verify a Conform Prep result by choosing original/imported XML and optional CSV files",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.vfx_timeline", ^NSDictionary *(NSDictionary *params) {
        return TTHandleVFXTimeline(params);
    }, @{
        @"description": @"Run VFX Timeline",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.vfx_shot_list_recover", ^NSDictionary *(NSDictionary *params) {
        return TTHandleRecoverVFXShotList(params);
    }, @{
        @"description": @"Generate VFX Shot List Excel from current timeline data and an existing thumbnail folder without recapturing",
        @"readOnly": @NO
    });

    api->registerMethod(@"com.turnover.tools.vfx_auto_marker", ^NSDictionary *(NSDictionary *params) {
        return TTHandleAutoMarker(params);
    }, @{
        @"description": @"Run VFX Auto Marker by marker kind",
        @"readOnly": @NO,
        @"params": @{
            @"marker_kind": @{@"type": @"string", @"required": @YES},
            @"rename_markers": @{@"type": @"boolean", @"required": @NO}
        }
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
