// Regression test for the macOS writeFile bridge: highlight file names coming
// from the web layer must stay inside ~/Documents/BabyReader.
#import <Foundation/Foundation.h>
#import "../native/BRConfinedPath.h"

int main(void) {
  @autoreleasepool {
    NSString *dir = @"/Users/someone/Documents/BabyReader";
    int failures = 0;

    NSDictionary<NSString *, id> *cases = @{
      @"书名.md":           @"/Users/someone/Documents/BabyReader/书名.md",
      @"Book Notes.MD":     @"/Users/someone/Documents/BabyReader/Book Notes.MD",
      @".hidden.md":        @"/Users/someone/Documents/BabyReader/.hidden.md",
      @"../../.zshrc":      [NSNull null],
      @"../PWNED.md":       [NSNull null],
      @"..":                [NSNull null],
      @".":                 [NSNull null],
      @"/tmp/x.md":         [NSNull null],
      @"a/b.md":            [NSNull null],
      @"notes.txt":         [NSNull null],
      @"launch.plist":      [NSNull null],
      @"":                  [NSNull null],
    };

    for (NSString *name in cases) {
      NSString *got = BRConfinedHighlightPath(dir, name);
      id want = cases[name];
      BOOL ok = (want == [NSNull null]) ? (got == nil) : [got isEqualToString:want];
      if (!ok) {
        failures++;
        fprintf(stderr, "FAIL %s -> %s\n", name.UTF8String, got ? got.UTF8String : "(nil)");
      }
    }

    if (failures) return 1;
    printf("highlight path checks passed (%lu cases)\n", (unsigned long)cases.count);
  }
  return 0;
}
