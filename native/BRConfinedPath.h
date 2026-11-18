#pragma once
#import <Foundation/Foundation.h>

// Returns the path for a highlight file named `filename` directly inside
// `dir`, or nil if `filename` is not a single plain `.md` file name. The web
// layer is not trusted to supply a safe name: document content can run script
// there, so traversal ("../"), absolute paths and other extensions are refused.
static inline NSString *BRConfinedHighlightPath(NSString *dir, NSString *filename) {
  if (filename.length == 0 || filename.length > 255) return nil;
  if ([filename rangeOfString:@"/"].location != NSNotFound) return nil;
  if ([filename rangeOfString:@"\0"].location != NSNotFound) return nil;
  if (![filename isEqualToString:filename.lastPathComponent]) return nil;
  if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."]) return nil;
  if (![filename.pathExtension.lowercaseString isEqualToString:@"md"]) return nil;

  NSString *base = [dir stringByStandardizingPath];
  NSString *path = [[base stringByAppendingPathComponent:filename] stringByStandardizingPath];
  if (![path.stringByDeletingLastPathComponent isEqualToString:base]) return nil;
  return path;
}

// YES only for the app's own bundled pages: file URLs inside `webDir`
// (including #fragment jumps within index.html) and about:blank. Everything
// else, such as data:, blob:, other local files or custom schemes, must not
// load inside the web view, because whatever loads there can reach the bridge.
static inline BOOL BRIsAppWebURL(NSURL *url, NSURL *webDir) {
  if (!url) return NO;
  if ([url.absoluteString isEqualToString:@"about:blank"]) return YES;
  if (!url.isFileURL || !webDir.isFileURL) return NO;
  NSString *base = [webDir.path stringByStandardizingPath];
  NSString *path = [url.path stringByStandardizingPath];
  return [path isEqualToString:base] ||
         [path hasPrefix:[base stringByAppendingString:@"/"]];
}
