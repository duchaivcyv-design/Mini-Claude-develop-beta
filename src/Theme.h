#import <UIKit/UIKit.h>

// Light-only palette inspired by Claude's interface (warm cream, terracotta accent).
@interface Theme : NSObject

+ (UIColor *)background;      // page background
+ (UIColor *)surface;         // cards / input fields
+ (UIColor *)border;
+ (UIColor *)accent;          // terracotta
+ (UIColor *)accentPressed;
+ (UIColor *)accentDisabled;
+ (UIColor *)text;
+ (UIColor *)secondaryText;
+ (UIColor *)success;
+ (UIColor *)error;
+ (UIColor *)selection;       // highlighted table row

+ (UIFont *)serifFontOfSize:(CGFloat)size;           // Georgia, falls back to system font
+ (UIImage *)imageWithColor:(UIColor *)color;        // 1x1 stretchable image for button states

// Template icons drawn in code (no image assets needed). Tint them with tintColor.
+ (UIImage *)iconMenu;
+ (UIImage *)iconPlus;
+ (UIImage *)iconCompose;   // square with a pencil: "new chat"
+ (UIImage *)iconSend;
+ (UIImage *)iconStop;

+ (void)styleNavigationBar:(UINavigationBar *)bar;

@end
