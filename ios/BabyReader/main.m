// BabyReader for iPadOS — UIKit shell around the shared web/ front end.
//
// The web layer (web/app.js) is identical to the macOS build. This file only
// re-implements the native side of the `window.webkit.messageHandlers.native`
// bridge with iPadOS APIs: document picker instead of NSOpenPanel/NSSavePanel,
// security-scoped URLs for files outside the sandbox, scenes instead of
// NSWindow, and the iPadOS menu bar / hardware-keyboard commands.

@import UIKit;
@import WebKit;
@import UniformTypeIdentifiers;
@import CoreText;

// ---------------------------------------------------------------------------
// MARK: - Helpers
// ---------------------------------------------------------------------------

static NSArray<UTType *> *BRReadableTypes(void) {
  NSMutableArray<UTType *> *types = [NSMutableArray array];
  UTType *md = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
  if (md) [types addObject:md];
  UTType *mdExt = [UTType typeWithFilenameExtension:@"md"];
  if (mdExt && ![types containsObject:mdExt]) [types addObject:mdExt];
  UTType *epub = [UTType typeWithIdentifier:@"org.idpf.epub-container"];
  if (epub) [types addObject:epub];
  UTType *epubExt = [UTType typeWithFilenameExtension:@"epub"];
  if (epubExt && ![types containsObject:epubExt]) [types addObject:epubExt];
  [types addObject:UTTypePlainText];
  return types;
}

static NSURL *BRHighlightsDirectory(void) {
  NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
  NSURL *dir = [docs URLByAppendingPathComponent:@"BabyReader" isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

static NSURL *BRTemporaryFileURL(NSString *filename) {
  NSURL *dir = [[NSFileManager defaultManager].temporaryDirectory
                  URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES attributes:nil error:nil];
  return [dir URLByAppendingPathComponent:filename];
}

// ---------------------------------------------------------------------------
// MARK: - Songti SC (matches the Mac app's serif typeface)
//
// web/styles.css uses "Songti SC" for titles, the welcome screen and
// Chinese serif text. macOS ships it; iPadOS only offers it as an on-demand
// system font. We ask CoreText to download it, pull the Regular and Bold
// faces out of the .ttc collection, and serve them to the page through the
// brfont:// scheme as @font-face "Songti SC" — so the shared CSS renders the
// same typeface on both platforms. Nothing is bundled with the app.
// ---------------------------------------------------------------------------

static NSString *const BRFontScheme = @"brfont";

static uint32_t BRReadU32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint16_t BRReadU16(const uint8_t *p) {
  return (uint16_t)((p[0] << 8) | p[1]);
}
static void BRWriteU32(uint8_t *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}

// Rebuild one face of a TrueType/OpenType collection as a standalone sfnt.
static NSData *BRExtractFaceFromCollection(NSData *ttc, NSUInteger faceIndex) {
  const uint8_t *b = ttc.bytes;
  NSUInteger len = ttc.length;
  if (len < 12 || memcmp(b, "ttcf", 4) != 0) return faceIndex == 0 ? ttc : nil;
  uint32_t numFonts = BRReadU32(b + 8);
  if (faceIndex >= numFonts || 12 + 4 * (faceIndex + 1) > len) return nil;
  uint32_t dirOffset = BRReadU32(b + 12 + 4 * faceIndex);
  if (dirOffset + 12 > len) return nil;
  uint16_t numTables = BRReadU16(b + dirOffset + 4);
  NSUInteger headerLen = 12 + 16 * (NSUInteger)numTables;
  if (dirOffset + headerLen > len) return nil;

  NSMutableData *out = [NSMutableData dataWithBytes:b + dirOffset length:headerLen];
  uint8_t *records = (uint8_t *)out.mutableBytes + 12;
  for (uint16_t i = 0; i < numTables; i++) {
    uint8_t *rec = records + 16 * i;
    uint32_t off = BRReadU32(rec + 8), tlen = BRReadU32(rec + 12);
    if ((NSUInteger)off + tlen > len) return nil;
    NSUInteger newOff = out.length;
    [out appendBytes:b + off length:tlen];
    NSUInteger pad = (4 - (tlen % 4)) % 4;
    if (pad) [out increaseLengthBy:pad];
    records = (uint8_t *)out.mutableBytes + 12;  // buffer may have moved
    BRWriteU32(records + 16 * i + 8, (uint32_t)newOff);
  }
  return out;
}

@interface BRSongtiFonts : NSObject <WKURLSchemeHandler>
+ (instancetype)shared;
@property (strong) NSURL *regularURL;
@property (strong) NSURL *boldURL;
@property (assign) BOOL ready;
- (void)loadWithCompletion:(void (^)(BOOL ok))completion;
- (NSString *)fontFaceCSS;
@end

@implementation BRSongtiFonts {
  NSMutableArray<void (^)(BOOL)> *_waiters;
  BOOL _loading;
}

+ (instancetype)shared {
  static BRSongtiFonts *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [[BRSongtiFonts alloc] init]; });
  return s;
}

- (NSURL *)cacheDir {
  NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
  NSURL *dir = [caches URLByAppendingPathComponent:@"Fonts" isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES
                                            attributes:nil error:nil];
  return dir;
}

- (void)loadWithCompletion:(void (^)(BOOL ok))completion {
  if (self.ready) { if (completion) completion(YES); return; }
  if (!_waiters) _waiters = [NSMutableArray array];
  if (completion) [_waiters addObject:completion];
  if (_loading) return;
  _loading = YES;

  NSURL *regular = [[self cacheDir] URLByAppendingPathComponent:@"Songti-SC-Regular.ttf"];
  NSURL *bold    = [[self cacheDir] URLByAppendingPathComponent:@"Songti-SC-Bold.ttf"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if ([fm fileExistsAtPath:regular.path] && [fm fileExistsAtPath:bold.path]) {
    [self finishWithRegular:regular bold:bold];
    return;
  }

  NSArray *descs = @[
    (__bridge_transfer id)CTFontDescriptorCreateWithNameAndSize(CFSTR("STSongti-SC-Regular"), 0),
    (__bridge_transfer id)CTFontDescriptorCreateWithNameAndSize(CFSTR("STSongti-SC-Bold"), 0),
  ];
  __weak typeof(self) weakSelf = self;
  CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
    (__bridge CFArrayRef)descs, NULL,
    ^bool(CTFontDescriptorMatchingState state, CFDictionaryRef progress) {
      if (state == kCTFontDescriptorMatchingDidFinish) {
        NSArray *matched = ((__bridge NSDictionary *)progress)[(__bridge id)kCTFontDescriptorMatchingResult];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [weakSelf extractFrom:matched regular:regular bold:bold];
        });
      } else if (state == kCTFontDescriptorMatchingDidFailWithError) {
        NSLog(@"[BabyReader] Songti download failed: %@",
              ((__bridge NSDictionary *)progress)[(__bridge id)kCTFontDescriptorMatchingError]);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishWithRegular:nil bold:nil]; });
      }
      return true;
    });
}

- (void)extractFrom:(NSArray *)matched regular:(NSURL *)regularOut bold:(NSURL *)boldOut {
  NSURL *fileURL = nil;
  for (id d in matched) {
    NSURL *u = (__bridge_transfer NSURL *)CTFontDescriptorCopyAttribute(
      (__bridge CTFontDescriptorRef)d, kCTFontURLAttribute);
    if (u) { fileURL = u; break; }
  }
  NSData *data = fileURL ? [NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe
                                                   error:nil] : nil;
  BOOL ok = NO;
  if (data) {
    // Map PostScript names to face indexes in the collection.
    NSArray *faces = (__bridge_transfer NSArray *)CTFontManagerCreateFontDescriptorsFromData(
      (__bridge CFDataRef)data);
    NSInteger regularIdx = -1, boldIdx = -1;
    for (NSUInteger i = 0; i < faces.count; i++) {
      NSString *name = (__bridge_transfer NSString *)CTFontDescriptorCopyAttribute(
        (__bridge CTFontDescriptorRef)faces[i], kCTFontNameAttribute);
      if ([name isEqualToString:@"STSongti-SC-Regular"]) regularIdx = (NSInteger)i;
      if ([name isEqualToString:@"STSongti-SC-Bold"])    boldIdx = (NSInteger)i;
    }
    NSData *r = regularIdx >= 0 ? BRExtractFaceFromCollection(data, (NSUInteger)regularIdx) : nil;
    NSData *b = boldIdx >= 0 ? BRExtractFaceFromCollection(data, (NSUInteger)boldIdx) : nil;
    ok = r && b && [r writeToURL:regularOut atomically:YES] && [b writeToURL:boldOut atomically:YES];
    if (!ok) NSLog(@"[BabyReader] Songti extract failed (regular %ld, bold %ld)",
                   (long)regularIdx, (long)boldIdx);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self finishWithRegular:ok ? regularOut : nil bold:ok ? boldOut : nil];
  });
}

- (void)finishWithRegular:(NSURL *)regular bold:(NSURL *)bold {
  self.regularURL = regular;
  self.boldURL = bold;
  self.ready = regular && bold;
  _loading = NO;
  NSArray *waiters = [_waiters copy];
  [_waiters removeAllObjects];
  for (void (^w)(BOOL) in waiters) w(self.ready);
}

- (NSString *)fontFaceCSS {
  return @"@font-face{font-family:'Songti SC';font-weight:100 500;"
         @"src:url('brfont://songti/regular.ttf') format('truetype');}"
         @"@font-face{font-family:'Songti SC';font-weight:600 900;"
         @"src:url('brfont://songti/bold.ttf') format('truetype');}";
}

// WKURLSchemeHandler — serves the extracted faces to the page.
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
  NSString *name = task.request.URL.lastPathComponent;
  NSURL *file = [name isEqualToString:@"bold.ttf"] ? self.boldURL
              : [name isEqualToString:@"regular.ttf"] ? self.regularURL : nil;
  NSData *data = file ? [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil] : nil;
  if (!data) {
    [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                               code:NSURLErrorFileDoesNotExist userInfo:nil]];
    return;
  }
  NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
    initWithURL:task.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
    headerFields:@{@"Content-Type": @"font/ttf",
                   @"Content-Length": [@(data.length) stringValue],
                   @"Access-Control-Allow-Origin": @"*"}];
  [task didReceiveResponse:resp];
  [task didReceiveData:data];
  [task didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {}

@end

typedef NS_ENUM(NSInteger, BRPickerPurpose) {
  BRPickerPurposeNone,
  BRPickerPurposeOpen,
  BRPickerPurposeSaveAs,
  BRPickerPurposeExport,
};

// ---------------------------------------------------------------------------
// MARK: - BRReaderViewController
// ---------------------------------------------------------------------------

@interface BRReaderViewController : UIViewController
  <WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, UIDocumentPickerDelegate>
@property (strong) WKWebView     *webView;
@property (strong) NSURL         *currentFileURL;
@property (assign) BOOL           accessingCurrentFile;
@property (copy)   NSString      *currentTextContent;
@property (assign) BOOL           webReady;
@property (assign) BOOL           documentDirty;
@property (strong) NSDictionary  *pendingDocument;
@property (copy)   NSString      *theme;
@property (assign) BRPickerPurpose pickerPurpose;
@property (strong) NSURL         *pickerTempURL;
@property (copy)   NSString      *pickerContent;
- (void)openFileAtURL:(NSURL *)url securityScoped:(BOOL)scoped;
- (void)flushUnsavedChanges;
@end

@implementation BRReaderViewController

- (void)dealloc {
  [self stopAccessingCurrentFile];
}

// ---------------------------------------------------------------------------
// MARK: View setup

- (void)viewDidLoad {
  [super viewDidLoad];
  self.theme = [[NSUserDefaults standardUserDefaults] stringForKey:@"BRTheme"] ?: @"dark";
  self.view.backgroundColor = [self backgroundColorForTheme:self.theme];

  WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
  WKWebpagePreferences *pagePrefs = [[WKWebpagePreferences alloc] init];
  pagePrefs.allowsContentJavaScript = YES;
  config.defaultWebpagePreferences = pagePrefs;
  config.dataDetectorTypes = WKDataDetectorTypeNone;

  WKUserContentController *ucc = [[WKUserContentController alloc] init];
  // Weak proxy is not needed: the controller removes the handler on dealloc
  // of the web view; scenes live for the app lifetime in practice.
  [ucc addScriptMessageHandler:self name:@"native"];
  NSString *platformScript =
    @"document.documentElement.classList.add('platform-ios');"
    @"window.BR_PLATFORM = 'ios';";
  [ucc addUserScript:[[WKUserScript alloc] initWithSource:platformScript
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                         forMainFrameOnly:YES]];
  config.userContentController = ucc;
  [config setURLSchemeHandler:[BRSongtiFonts shared] forURLScheme:BRFontScheme];

  self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
  self.webView.translatesAutoresizingMaskIntoConstraints = NO;
  self.webView.navigationDelegate = self;
  self.webView.UIDelegate = self;
  self.webView.opaque = NO;
  self.webView.backgroundColor = UIColor.clearColor;
  self.webView.scrollView.backgroundColor = UIColor.clearColor;
  // The page manages its own scroll containers and uses env(safe-area-*).
  self.webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  self.webView.scrollView.bounces = NO;
#if DEBUG
  if (@available(iOS 16.4, *)) self.webView.inspectable = YES;
#endif
  [self.view addSubview:self.webView];

  // Shrink the web view above the on-screen keyboard so the editor's caret and
  // the 100vh layouts stay visible while typing.
  self.view.keyboardLayoutGuide.usesBottomSafeArea = NO;
  [NSLayoutConstraint activateConstraints:@[
    [self.webView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
    [self.webView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
    [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [self.webView.bottomAnchor   constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
  ]];

  [self applyThemeAppearance:self.theme];
  [self installSongtiFont];
  [self loadWebContent];
}

// Make "Songti SC" available to the page (see BRSongtiFonts). If the font is
// already cached it is injected before first paint; otherwise it is added to
// the live page as soon as the download finishes.
- (void)installSongtiFont {
  __weak typeof(self) weakSelf = self;
  [[BRSongtiFonts shared] loadWithCompletion:^(BOOL ok) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!ok || !self) return;
    NSString *css = [[BRSongtiFonts shared] fontFaceCSS];
    NSString *js = [NSString stringWithFormat:
      @"(function(){if(document.getElementById('br-songti'))return;"
      @"var s=document.createElement('style');s.id='br-songti';s.textContent=%@;"
      @"(document.head||document.documentElement).appendChild(s);})();",
      [self jsonStringLiteral:css]];
    [self.webView.configuration.userContentController addUserScript:
      [[WKUserScript alloc] initWithSource:js
                             injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                          forMainFrameOnly:YES]];
    [self.webView evaluateJavaScript:js completionHandler:nil];
  }];
}

- (NSString *)jsonStringLiteral:(NSString *)string {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[string] options:0 error:nil];
  NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
  return [self.theme isEqualToString:@"light"] ? UIStatusBarStyleDarkContent
                                               : UIStatusBarStyleLightContent;
}

- (UIColor *)backgroundColorForTheme:(NSString *)theme {
  return [theme isEqualToString:@"light"]
    ? [UIColor colorWithRed:252/255.0 green:248/255.0 blue:241/255.0 alpha:1]
    : [UIColor colorWithRed:30/255.0 green:30/255.0 blue:30/255.0 alpha:1];
}

- (void)loadWebContent {
  NSURL *indexURL  = [[NSBundle mainBundle] URLForResource:@"index"
                                             withExtension:@"html"
                                              subdirectory:@"web"];
  NSURL *webDirURL = [[NSBundle mainBundle] URLForResource:@"web" withExtension:nil];
  if (!indexURL || !webDirURL) {
    [self showError:@"Missing Resources"
             detail:@"Could not find web/index.html in the app bundle."];
    return;
  }
  self.webReady = NO;
  [self.webView loadFileURL:indexURL allowingReadAccessToURL:webDirURL];
}

// ---------------------------------------------------------------------------
// MARK: WKScriptMessageHandler — web → native bridge

- (void)userContentController:(WKUserContentController *)ucc
      didReceiveScriptMessage:(WKScriptMessage *)message {
  if (![message.body isKindOfClass:[NSDictionary class]]) return;
  NSDictionary *body    = message.body;
  NSString     *type    = body[@"type"];
  NSDictionary *payload = [body[@"payload"] isKindOfClass:[NSDictionary class]]
                            ? body[@"payload"] : @{};

  if ([type isEqualToString:@"ready"]) {
    self.webReady = YES;
    if (self.pendingDocument) {
      [self sendFunction:@"receiveDocument" payload:self.pendingDocument];
      self.pendingDocument = nil;
    }
    return;
  }

  if ([type isEqualToString:@"open"])   { [self commandOpen:nil];   return; }
  if ([type isEqualToString:@"save"])   { [self commandSave:nil];   return; }
  if ([type isEqualToString:@"saveAs"]) { [self commandSaveAs:nil]; return; }

  if ([type isEqualToString:@"dirtyChanged"]) {
    self.documentDirty = [payload[@"dirty"] boolValue];
    NSString *content = payload[@"content"];
    if ([content isKindOfClass:[NSString class]]) self.currentTextContent = content;
    [self updateSceneTitle];
    return;
  }

  if ([type isEqualToString:@"themeChanged"]) {
    NSString *theme = payload[@"theme"];
    if ([theme isKindOfClass:[NSString class]]) [self applyThemeAppearance:theme];
    return;
  }

  if ([type isEqualToString:@"copyText"]) {
    NSString *text = payload[@"text"];
    if ([text isKindOfClass:[NSString class]] && text.length) {
      UIPasteboard.generalPasteboard.string = text;
    }
    return;
  }

  if ([type isEqualToString:@"exportFile"]) {
    NSString *filename = payload[@"filename"];
    NSString *content  = payload[@"content"];
    if ([filename isKindOfClass:[NSString class]] && filename.length &&
        [content isKindOfClass:[NSString class]]) {
      [self presentExportPickerForContent:content filename:filename
                                  purpose:BRPickerPurposeExport];
    }
    return;
  }

  if ([type isEqualToString:@"writeFile"]) {
    // Silent highlight auto-save. Lands in the app's Documents/BabyReader,
    // which the Files app shows under "On My iPad › BabyReader".
    NSString *filename = payload[@"filename"];
    NSString *content  = payload[@"content"];
    BOOL silent = [payload[@"silent"] boolValue];
    if ([filename isKindOfClass:[NSString class]] && filename.length &&
        [content isKindOfClass:[NSString class]]) {
      NSURL *url = [BRHighlightsDirectory() URLByAppendingPathComponent:filename.lastPathComponent];
      [content writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
      [self sendFunction:@"notifyHighlightFileWritten" payload:@{
        @"path": [@"BabyReader/" stringByAppendingString:url.lastPathComponent],
        @"silent": @(silent)
      }];
    }
    return;
  }
}

// ---------------------------------------------------------------------------
// MARK: WKNavigationDelegate / WKUIDelegate

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURL *url = navigationAction.request.URL;
  if (url.isFileURL || [url.scheme isEqualToString:@"about"] ||
      [url.scheme isEqualToString:@"blob"] || [url.scheme isEqualToString:@"data"]) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }
  if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"] ||
      [url.scheme isEqualToString:@"mailto"]) {
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    decisionHandler(WKNavigationActionPolicyCancel);
    return;
  }
  decisionHandler(WKNavigationActionPolicyAllow);
}

// target="_blank" links
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  NSURL *url = navigationAction.request.URL;
  if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
  }
  return nil;
}

// iPadOS may kill the web content process under memory pressure (large EPUBs).
// Reload the page and re-send the current document instead of showing a blank view.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  NSURL *url = self.currentFileURL;
  [self loadWebContent];
  if (url) [self readDocumentAtURL:url completion:^(NSDictionary *doc, NSError *error) {
    if (doc) self.pendingDocument = doc;
  }];
}

// ---------------------------------------------------------------------------
// MARK: Opening documents

- (void)stopAccessingCurrentFile {
  if (self.accessingCurrentFile && self.currentFileURL) {
    [self.currentFileURL stopAccessingSecurityScopedResource];
  }
  self.accessingCurrentFile = NO;
}

- (void)openFileAtURL:(NSURL *)url securityScoped:(BOOL)scoped {
  [self flushUnsavedChanges];

  BOOL accessing = scoped ? [url startAccessingSecurityScopedResource] : NO;
  __weak typeof(self) weakSelf = self;
  [self readDocumentAtURL:url completion:^(NSDictionary *doc, NSError *error) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self) return;
    if (!doc) {
      if (accessing) [url stopAccessingSecurityScopedResource];
      [self showError:@"无法打开文件"
               detail:error.localizedDescription ?: @"读取文件时发生未知错误。"];
      return;
    }
    if (![url isEqual:self.currentFileURL]) [self stopAccessingCurrentFile];
    else if (accessing && self.accessingCurrentFile) [url stopAccessingSecurityScopedResource];
    self.currentFileURL       = url;
    self.accessingCurrentFile = self.accessingCurrentFile || accessing;
    self.currentTextContent   = [doc[@"type"] isEqualToString:@"text"] ? doc[@"content"] : nil;
    self.documentDirty        = NO;
    [self updateSceneTitle];

    if (self.webReady) [self sendFunction:@"receiveDocument" payload:doc];
    else self.pendingDocument = doc;
  }];
}

// Coordinated read so iCloud Drive / File Provider files are downloaded first.
- (void)readDocumentAtURL:(NSURL *)url
               completion:(void (^)(NSDictionary *doc, NSError *error))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    __block NSDictionary *doc = nil;
    __block NSError *readError = nil;
    NSError *coordError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url options:0 error:&coordError
                                 byAccessor:^(NSURL *readURL) {
      NSString *ext = readURL.pathExtension.lowercaseString;
      if ([ext isEqualToString:@"epub"]) {
        NSData *data = [NSData dataWithContentsOfURL:readURL options:0 error:&readError];
        if (data) doc = @{
          @"path": url.path,
          @"name": url.lastPathComponent,
          @"type": @"epub",
          @"data": [data base64EncodedStringWithOptions:0]
        };
      } else {
        NSString *content = [NSString stringWithContentsOfURL:readURL usedEncoding:NULL
                                                        error:&readError];
        if (!content) {
          // Fall back to UTF-8 for files without a detectable encoding.
          NSData *data = [NSData dataWithContentsOfURL:readURL];
          if (data) content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        if (content) doc = @{
          @"path": url.path,
          @"name": url.lastPathComponent,
          @"type": @"text",
          @"content": content
        };
      }
    }];
    NSError *error = readError ?: coordError;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(doc, error); });
  });
}

// ---------------------------------------------------------------------------
// MARK: Commands (menu bar, keyboard, and web bridge)

- (BOOL)isEditableTextDocument {
  if (!self.currentFileURL) return NO;
  return ![self.currentFileURL.pathExtension.lowercaseString isEqualToString:@"epub"];
}

- (void)commandOpen:(id)sender {
  if (self.presentedViewController) return;
  UIDocumentPickerViewController *picker =
    [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:BRReadableTypes()
                                                                asCopy:NO];
  picker.allowsMultipleSelection = NO;
  picker.delegate = self;
  self.pickerPurpose = BRPickerPurposeOpen;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)commandSave:(id)sender {
  if (![self isEditableTextDocument]) {
    if (!self.currentFileURL) [self commandSaveAs:nil];
    return;
  }
  NSURL *target = self.currentFileURL;
  __weak typeof(self) weakSelf = self;
  [self fetchContentFromWeb:^(NSString *content) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self || ![self writeContent:content toURL:target]) return;
    self.currentTextContent = content;
    self.documentDirty = NO;
    [self updateSceneTitle];
    [self sendFunction:@"notifySaved" payload:@{
      @"path": target.path, @"name": target.lastPathComponent
    }];
  }];
}

- (void)commandSaveAs:(id)sender {
  if (self.currentFileURL && ![self isEditableTextDocument]) return; // EPUB is read-only
  NSString *name = self.currentFileURL.lastPathComponent ?: @"Untitled.md";
  __weak typeof(self) weakSelf = self;
  [self fetchContentFromWeb:^(NSString *content) {
    [weakSelf presentExportPickerForContent:content filename:name
                                    purpose:BRPickerPurposeSaveAs];
  }];
}

- (void)commandToggleEditMode:(id)sender  { [self callWebFunction:@"toggleEditMode"]; }
- (void)commandToggleTheme:(id)sender     { [self callWebFunction:@"toggleTheme"]; }
- (void)commandHighlight:(id)sender       { [self callWebFunction:@"highlightSelection"]; }
- (void)commandExportHighlights:(id)sender{ [self callWebFunction:@"exportHighlights"]; }
- (void)commandZoomIn:(id)sender          { [self callWebFunction:@"zoomIn"]; }
- (void)commandZoomOut:(id)sender         { [self callWebFunction:@"zoomOut"]; }
- (void)commandZoomReset:(id)sender       { [self callWebFunction:@"zoomReset"]; }

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
  BOOL isEpub = self.currentFileURL && ![self isEditableTextDocument];
  if (action == @selector(commandSave:) || action == @selector(commandSaveAs:) ||
      action == @selector(commandToggleEditMode:)) {
    return !isEpub;
  }
  if (action == @selector(commandHighlight:) || action == @selector(commandExportHighlights:)) {
    return isEpub;
  }
  if (action == @selector(commandOpen:) || action == @selector(commandToggleTheme:) ||
      action == @selector(commandZoomIn:) || action == @selector(commandZoomOut:) ||
      action == @selector(commandZoomReset:)) {
    return YES;
  }
  return [super canPerformAction:action withSender:sender];
}

// ---------------------------------------------------------------------------
// MARK: Saving

- (void)presentExportPickerForContent:(NSString *)content
                             filename:(NSString *)filename
                              purpose:(BRPickerPurpose)purpose {
  if (self.presentedViewController) return;
  NSURL *tmp = BRTemporaryFileURL(filename.lastPathComponent.length ? filename.lastPathComponent
                                                                    : @"Untitled.md");
  NSError *error = nil;
  if (![content writeToURL:tmp atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
    [self showError:@"保存失败" detail:error.localizedDescription ?: @"无法创建临时文件。"];
    return;
  }
  // Save As moves the file so the picked location becomes the live document;
  // highlight export only copies it.
  UIDocumentPickerViewController *picker =
    [[UIDocumentPickerViewController alloc] initForExportingURLs:@[tmp]
                                                          asCopy:(purpose == BRPickerPurposeExport)];
  picker.delegate = self;
  self.pickerPurpose  = purpose;
  self.pickerTempURL  = tmp;
  self.pickerContent  = content;
  [self presentViewController:picker animated:YES completion:nil];
}

- (BOOL)writeContent:(NSString *)content toURL:(NSURL *)url {
  if (!url) return NO;
  __block BOOL ok = NO;
  __block NSError *writeError = nil;
  NSError *coordError = nil;
  NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForReplacing
                                    error:&coordError byAccessor:^(NSURL *writeURL) {
    ok = [content writeToURL:writeURL atomically:YES encoding:NSUTF8StringEncoding
                       error:&writeError];
  }];
  if (!ok) {
    NSError *error = writeError ?: coordError;
    [self showError:@"保存失败" detail:error.localizedDescription ?: @"写入文件时发生未知错误。"];
  }
  return ok;
}

- (void)fetchContentFromWeb:(void (^)(NSString *content))completion {
  if (!self.webReady) { completion(self.currentTextContent ?: @""); return; }
  NSString *script = @"window.appHost && typeof window.appHost.getContent === 'function' "
                     @"? window.appHost.getContent() : null;";
  [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
    completion([result isKindOfClass:[NSString class]] ? result : @"");
  }];
}

// Called when the scene goes to the background or another file replaces the
// current one. iPadOS can terminate background apps without warning, so this
// is the equivalent of the Mac build's save-on-window-close.
- (void)flushUnsavedChanges {
  if (!self.documentDirty || ![self isEditableTextDocument]) return;
  NSURL *target = self.currentFileURL;
  UIApplication *app = [UIApplication sharedApplication];
  __block UIBackgroundTaskIdentifier task =
    [app beginBackgroundTaskWithName:@"BRSave" expirationHandler:^{
      [app endBackgroundTask:task];
      task = UIBackgroundTaskInvalid;
    }];
  __weak typeof(self) weakSelf = self;
  [self fetchContentFromWeb:^(NSString *content) {
    __strong typeof(weakSelf) self = weakSelf;
    if (self && content && [self writeContent:content toURL:target] &&
        [target isEqual:self.currentFileURL]) {
      self.currentTextContent = content;
      self.documentDirty = NO;
      [self updateSceneTitle];
      [self sendFunction:@"notifySaved" payload:@{
        @"path": target.path, @"name": target.lastPathComponent
      }];
    }
    if (task != UIBackgroundTaskInvalid) {
      [app endBackgroundTask:task];
      task = UIBackgroundTaskInvalid;
    }
  }];
}

// ---------------------------------------------------------------------------
// MARK: UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSURL *url = urls.firstObject;
  BRPickerPurpose purpose = self.pickerPurpose;
  NSString *content = self.pickerContent;
  [self resetPickerState];
  if (!url) return;

  switch (purpose) {
    case BRPickerPurposeOpen:
      [self openFileAtURL:url securityScoped:YES];
      break;

    case BRPickerPurposeSaveAs: {
      [self stopAccessingCurrentFile];
      self.currentFileURL       = url;
      self.accessingCurrentFile = [url startAccessingSecurityScopedResource];
      self.currentTextContent   = content;
      self.documentDirty        = NO;
      [self updateSceneTitle];
      [self sendFunction:@"notifySaved" payload:@{
        @"path": url.path, @"name": url.lastPathComponent
      }];
      break;
    }

    case BRPickerPurposeExport:
      [self sendFunction:@"notifyHighlightFileWritten" payload:@{
        @"path": url.lastPathComponent, @"silent": @NO
      }];
      break;

    case BRPickerPurposeNone:
      break;
  }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
  [self resetPickerState];
}

- (void)resetPickerState {
  if (self.pickerTempURL) {
    [[NSFileManager defaultManager] removeItemAtURL:self.pickerTempURL.URLByDeletingLastPathComponent
                                              error:nil];
  }
  self.pickerPurpose = BRPickerPurposeNone;
  self.pickerTempURL = nil;
  self.pickerContent = nil;
}

// ---------------------------------------------------------------------------
// MARK: Appearance

- (void)updateSceneTitle {
  NSString *title = self.currentFileURL.lastPathComponent ?: @"BabyReader";
  if (self.documentDirty && [self isEditableTextDocument]) {
    title = [title stringByAppendingString:@" • 已编辑"];
  }
  self.view.window.windowScene.title = title;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self updateSceneTitle];
}

- (void)applyThemeAppearance:(NSString *)theme {
  self.theme = theme;
  [[NSUserDefaults standardUserDefaults] setObject:theme forKey:@"BRTheme"];
  UIUserInterfaceStyle style = [theme isEqualToString:@"light"] ? UIUserInterfaceStyleLight
                                                                : UIUserInterfaceStyleDark;
  self.overrideUserInterfaceStyle = style;
  self.view.window.overrideUserInterfaceStyle = style;
  self.view.backgroundColor = [self backgroundColorForTheme:theme];
  [self setNeedsStatusBarAppearanceUpdate];
}

// ---------------------------------------------------------------------------
// MARK: Native → Web bridge helpers

- (void)sendFunction:(NSString *)function payload:(id)payload {
  if (!self.webReady || !function.length) return;
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
  if (!data) { NSLog(@"[BabyReader] JSON serialization error: %@", error); return; }
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  [self evaluateJS:[NSString stringWithFormat:
    @"if (window.appHost && typeof window.appHost.%@ === 'function') { window.appHost.%@(%@); }",
    function, function, json]];
}

- (void)callWebFunction:(NSString *)function {
  if (!self.webReady || !function.length) return;
  [self evaluateJS:[NSString stringWithFormat:
    @"if (window.appHost && typeof window.appHost.%@ === 'function') { window.appHost.%@(); }",
    function, function]];
}

- (void)evaluateJS:(NSString *)script {
  [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
    if (error) NSLog(@"[BabyReader] JS error: %@", error.localizedDescription);
  }];
}

- (void)showError:(NSString *)title detail:(NSString *)detail {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:detail
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
  UIViewController *host = self.presentedViewController ?: self;
  [host presentViewController:alert animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
// MARK: - Scene delegate
// ---------------------------------------------------------------------------

@interface BRSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong) BRReaderViewController *reader;
@end

@implementation BRSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
  if (![scene isKindOfClass:[UIWindowScene class]]) return;
  UIWindowScene *windowScene = (UIWindowScene *)scene;
  self.reader = [[BRReaderViewController alloc] init];
  self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
  self.window.rootViewController = self.reader;
  [self.window makeKeyAndVisible];
  windowScene.title = @"BabyReader";

  [self openURLContexts:connectionOptions.URLContexts];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
  [self openURLContexts:URLContexts];
}

- (void)openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
  UIOpenURLContext *context = contexts.anyObject;
  if (!context || !context.URL.isFileURL) return;
  // With LSSupportsOpeningDocumentsInPlace the URL points at the original file
  // and needs security-scoped access; otherwise it is a copy in our Inbox.
  [self.reader openFileAtURL:context.URL securityScoped:context.options.openInPlace];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
  [self.reader flushUnsavedChanges];
}

@end

// ---------------------------------------------------------------------------
// MARK: - App delegate (menu bar / keyboard shortcuts)
// ---------------------------------------------------------------------------

@interface BRAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation BRAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
  UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default"
                                                                sessionRole:session.role];
  config.delegateClass = [BRSceneDelegate class];
  return config;
}

static UIKeyCommand *BRCommand(NSString *title, SEL action, NSString *input,
                               UIKeyModifierFlags flags) {
  UIKeyCommand *cmd = [UIKeyCommand commandWithTitle:title image:nil action:action
                                               input:input modifierFlags:flags
                                        propertyList:nil];
  cmd.wantsPriorityOverSystemBehavior = YES;
  return cmd;
}

// Same shortcuts as the macOS menu bar. ⌘H is reserved by iPadOS (Home), so
// highlighting uses ⇧⌘H here.
- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
  [super buildMenuWithBuilder:builder];
  if (builder.system != UIMenuSystem.mainSystem) return;

  UIKeyModifierFlags cmd = UIKeyModifierCommand;
  UIKeyModifierFlags shiftCmd = UIKeyModifierCommand | UIKeyModifierShift;

  UIMenu *fileMenu = [UIMenu menuWithTitle:@"" image:nil identifier:@"com.baobao.babyreader.file"
                                   options:UIMenuOptionsDisplayInline children:@[
    BRCommand(@"打开…", @selector(commandOpen:), @"o", cmd),
    BRCommand(@"保存", @selector(commandSave:), @"s", cmd),
    BRCommand(@"另存为…", @selector(commandSaveAs:), @"s", shiftCmd),
  ]];
  [builder insertChildMenu:fileMenu atStartOfMenuForIdentifier:UIMenuFile];

  UIMenu *editMenu = [UIMenu menuWithTitle:@"" image:nil identifier:@"com.baobao.babyreader.edit"
                                   options:UIMenuOptionsDisplayInline children:@[
    BRCommand(@"切换编辑模式", @selector(commandToggleEditMode:), @"e", cmd),
    BRCommand(@"划线", @selector(commandHighlight:), @"h", shiftCmd),
    BRCommand(@"导出划线", @selector(commandExportHighlights:), @"e", shiftCmd),
  ]];
  [builder insertChildMenu:editMenu atEndOfMenuForIdentifier:UIMenuEdit];

  UIMenu *viewMenu = [UIMenu menuWithTitle:@"" image:nil identifier:@"com.baobao.babyreader.view"
                                   options:UIMenuOptionsDisplayInline children:@[
    BRCommand(@"切换主题", @selector(commandToggleTheme:), @"t", cmd),
    BRCommand(@"放大", @selector(commandZoomIn:), @"=", cmd),
    BRCommand(@"缩小", @selector(commandZoomOut:), @"-", cmd),
    BRCommand(@"实际大小", @selector(commandZoomReset:), @"0", cmd),
  ]];
  [builder insertChildMenu:viewMenu atStartOfMenuForIdentifier:UIMenuView];
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([BRAppDelegate class]));
  }
}
