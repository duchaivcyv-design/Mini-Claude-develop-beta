#import "Theme.h"

static UIColor *HexColor(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

@implementation Theme

+ (UIColor *)background     { return HexColor(0xFAF9F5); }
+ (UIColor *)surface        { return HexColor(0xFFFFFF); }
+ (UIColor *)border         { return HexColor(0xE3E0D5); }
+ (UIColor *)accent         { return HexColor(0xC96442); }
+ (UIColor *)accentPressed  { return HexColor(0xAE5233); }
+ (UIColor *)accentDisabled { return HexColor(0xE2B4A3); }
+ (UIColor *)text           { return HexColor(0x29261B); }
+ (UIColor *)secondaryText  { return HexColor(0x6F6B5E); }
+ (UIColor *)success        { return HexColor(0x3F7D58); }
+ (UIColor *)error          { return HexColor(0xB3402A); }
+ (UIColor *)selection      { return HexColor(0xF0EEE6); }

+ (UIFont *)serifFontOfSize:(CGFloat)size {
    UIFont *font = [UIFont fontWithName:@"Georgia" size:size];
    return font ? font : [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
}

+ (UIImage *)imageWithColor:(UIColor *)color {
    CGRect rect = CGRectMake(0, 0, 1, 1);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    [color setFill];
    UIRectFill(rect);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsZero];
}

#pragma mark - Icons

+ (UIImage *)iconWithSize:(CGSize)size draw:(void (^)(CGContextRef ctx))draw {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        draw(rendererContext.CGContext);
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage *)iconMenu {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGFloat ys[3] = {6.5, 12, 17.5};
        for (int i = 0; i < 3; i++) {
            CGContextMoveToPoint(c, 4, ys[i]);
            CGContextAddLineToPoint(c, 20, ys[i]);
        }
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconPlus {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextMoveToPoint(c, 12, 5);
        CGContextAddLineToPoint(c, 12, 19);
        CGContextMoveToPoint(c, 5, 12);
        CGContextAddLineToPoint(c, 19, 12);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconCompose {
    return [self iconWithSize:CGSizeMake(24, 24) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        UIBezierPath *path = [UIBezierPath bezierPath];
        // rounded square, open at the top-right where the pencil goes
        [path moveToPoint:CGPointMake(11, 5)];
        [path addLineToPoint:CGPointMake(7, 5)];
        [path addQuadCurveToPoint:CGPointMake(4, 8) controlPoint:CGPointMake(4, 5)];
        [path addLineToPoint:CGPointMake(4, 17)];
        [path addQuadCurveToPoint:CGPointMake(7, 20) controlPoint:CGPointMake(4, 20)];
        [path addLineToPoint:CGPointMake(16, 20)];
        [path addQuadCurveToPoint:CGPointMake(19, 17) controlPoint:CGPointMake(19, 20)];
        [path addLineToPoint:CGPointMake(19, 13)];
        // pencil
        [path moveToPoint:CGPointMake(10.5, 13.5)];
        [path addLineToPoint:CGPointMake(19.5, 4.5)];
        CGContextAddPath(c, path.CGPath);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconSend {
    return [self iconWithSize:CGSizeMake(20, 20) draw:^(CGContextRef c) {
        CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
        CGContextSetLineWidth(c, 2.2);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextSetLineJoin(c, kCGLineJoinRound);
        CGContextMoveToPoint(c, 10, 16.5);
        CGContextAddLineToPoint(c, 10, 4);
        CGContextMoveToPoint(c, 4.5, 9.5);
        CGContextAddLineToPoint(c, 10, 4);
        CGContextAddLineToPoint(c, 15.5, 9.5);
        CGContextStrokePath(c);
    }];
}

+ (UIImage *)iconStop {
    return [self iconWithSize:CGSizeMake(16, 16) draw:^(CGContextRef c) {
        CGContextSetFillColorWithColor(c, [UIColor blackColor].CGColor);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 12, 12) cornerRadius:3];
        CGContextAddPath(c, path.CGPath);
        CGContextFillPath(c);
    }];
}

#pragma mark - Navigation bar

+ (void)styleNavigationBar:(UINavigationBar *)bar {
    bar.barTintColor = [self background];
    bar.tintColor = [self accent];
    bar.translucent = NO;
    // A custom shadow image is only honored together with a custom background image.
    [bar setBackgroundImage:[self imageWithColor:[self background]] forBarMetrics:UIBarMetricsDefault];
    bar.shadowImage = [[UIImage alloc] init];
    bar.titleTextAttributes = @{ NSForegroundColorAttributeName: [self text],
                                 NSFontAttributeName: [self serifFontOfSize:18] };
}

@end
