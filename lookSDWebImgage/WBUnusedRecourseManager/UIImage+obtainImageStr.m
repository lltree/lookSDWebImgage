//
//  UIImage+obtainImageStr.m
//  HtmlOpenImage
//
//  Created by wmmMac on 2019/4/16.
//  Copyright © 2019 58. All rights reserved.
//

#import "UIImage+obtainImageStr.h"
#import <objc/runtime.h>
#import "WBDeleteRecourseManager.h"

@implementation UIImage (obtainImageStr)

+(void)load{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class class = object_getClass((id)self);
        SEL imageNameSel = @selector(imageNamed:);
        SEL wb_imageNamedSel = @selector(wb_imageNamed:);
        [UIImage swizzleClassMethodClass:class orig:imageNameSel swiz:wb_imageNamedSel];
        
        //imageNamed:inBundle:compatibleWithTraitCollection:
        SEL imageNamebundleSEL = @selector(imageNamed:inBundle:compatibleWithTraitCollection:);
        SEL wb_imageNamebundleSEL = @selector(wb_imageNamed:inBundle:compatibleWithTraitCollection:);
        [UIImage swizzleClassMethodClass:class orig:imageNamebundleSEL swiz:wb_imageNamebundleSEL];
         
        
        //imageWithContentsOfFile
        SEL imageWithContentsOfFileSEL = @selector(imageWithContentsOfFile:);
        SEL wb_imageWithContentsOfFileSEL = @selector(wb_imageWithContentsOfFile:);
        [UIImage swizzleClassMethodClass:class orig:imageWithContentsOfFileSEL swiz:wb_imageWithContentsOfFileSEL];
        // 不在hook此方法，因为此方法内部调用的就是initWithContentsOfFile，所有当使用imageWithContentsOfFile方法是会执行到initWithContentsOfFile中，也就是我们重写的wb_initWithContentsOfFile方法中
        //initWithContentsOfFile
//        SEL initWithContentsOfFileSEL = @selector(initWithContentsOfFile:);
//        SEL wb_initWithContentsOfFileSEL = @selector(wb_initWithContentsOfFile:);
//        [UIImage swizzleInstanceMethodClass:[self class] orig:initWithContentsOfFileSEL swiz:wb_initWithContentsOfFileSEL];
    });
}
+(void)swizzleClassMethodClass:(Class)class orig:(SEL)origSel swiz:(SEL)swizSel{
    Method origMethod = class_getClassMethod(class,origSel);
    Method swizMethod = class_getClassMethod(class, swizSel);
    BOOL success = class_addMethod(class, origSel, method_getImplementation(swizMethod), method_getTypeEncoding(swizMethod));
    if(success){
        class_replaceMethod(class, swizSel, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    }else{
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

+(void)swizzleInstanceMethodClass:(Class)class orig:(SEL)origSEL swiz:(SEL)swizSEL{
    Method origM = class_getInstanceMethod(class, origSEL);
    Method swizM = class_getInstanceMethod(class, swizSEL);
    BOOL success = class_addMethod(class, origSEL, method_getImplementation(swizM), method_getTypeEncoding(swizM));
    if(success){
        class_replaceMethod(class, swizSEL, method_getImplementation(origM), method_getTypeEncoding(origM));
    }else{
        method_exchangeImplementations(origM, swizM);
    }
}
+(UIImage *)wb_imageNamed:(NSString*)name{
    UIImage * image = [self wb_imageNamed:name];//相当于调用imageNamed:
    return [WBDeleteRecourseManager judgeImage:image imageName:[WBDeleteRecourseManager getImageNameFormBundle:name]];
//    return image;
}
+(UIImage *)wb_imageNamed:(NSString *)name inBundle:(nullable NSBundle *)bundle compatibleWithTraitCollection:(nullable UITraitCollection *)traitCollection{
    UIImage * image = [self wb_imageNamed:name inBundle:bundle compatibleWithTraitCollection:traitCollection];
    return [WBDeleteRecourseManager judgeImage:image imageName:[WBDeleteRecourseManager getImageNameFormBundle:name]];
}
+(instancetype)wb_imageWithContentsOfFile:(NSString *)namepath{
    UIImage * image = [self wb_imageWithContentsOfFile:namepath];
    return [WBDeleteRecourseManager judgeImage:image imageName:[WBDeleteRecourseManager getImageNameFormImagePath:namepath]];
}

//- (instancetype)wb_initWithContentsOfFile:(NSString *)path{
//    UIImage * image = [self wb_initWithContentsOfFile:path];
//    image = [WBDeleteRecourseManager judgeImage:image imageName:[WBDeleteRecourseManager getImageNameFormImagePath:path]];
//    return image;
//}
//重写方法
//- (instancetype)wbsub_initWithContentsOfFile:(NSString *)path;
//{
//    UIImage * image = [self initWithContentsOfFile:path];
//    image = [WBDeleteRecourseManager judgeImage:image imageName:[WBDeleteRecourseManager getImageNameFormImagePath:path]];
//    return image;
//}

@end
