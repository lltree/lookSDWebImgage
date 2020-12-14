//
//  NSBundle+HookPath.m
//  HtmlOpenImage
//
//  Created by wmmMac on 2019/4/17.
//  Copyright © 2019 58. All rights reserved.
//

#import "NSBundle+HookPath.h"
#import <objc/runtime.h>

@implementation NSBundle (HookPath)
+(void)load{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method origM = class_getInstanceMethod([self class], @selector(pathForResource:ofType:));
        Method swizM = class_getInstanceMethod([self class], @selector(wb_pathForResource:ofType:));
        BOOL success = class_addMethod([self class], @selector(pathForResource:ofType:), method_getImplementation(swizM), method_getTypeEncoding(swizM));
        if(success){
            class_replaceMethod([self class], @selector(wb_pathForResource:ofType:), method_getImplementation(origM), method_getTypeEncoding(origM));
        }else{
            method_exchangeImplementations(origM, swizM);
        }
    });
}
- (nullable NSString *)wb_pathForResource:(nullable NSString *)name ofType:(nullable NSString *)ext;{
    NSString * string = [self wb_pathForResource:name ofType:ext];
    if(([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"]) && string.length == 0){
        return [NSString stringWithFormat:@"WBDeleteImagePath/%@.%@",name,ext];
    }else{
        return string;
    }
    return @"";
}
@end
