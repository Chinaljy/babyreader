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
