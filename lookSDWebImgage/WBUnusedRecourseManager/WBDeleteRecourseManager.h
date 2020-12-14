//
//  WBDeleteRecourseManager.h
//  HtmlOpenImage
//
//  Created by wmmMac on 2019/4/17.
//  Copyright © 2019 58. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface WBDeleteRecourseManager : NSObject

//通过server获取误删除图片的数据
+(void)requestDeleteRecourse;

//从沙箱中读取图片路径
+(UIImage *)readImageFormDocumence:(NSString *)name;

//判断图片是否存在
+(UIImage *)judgeImage:(UIImage *)image imageName:(NSString *)imageName;

//获取bundle中的图片名
+(NSString *)getImageNameFormBundle:(NSString *)bundlePath;

//获取路径获取图片名
+(NSString *)getImageNameFormImagePath:(NSString *)imagePath;

@end

NS_ASSUME_NONNULL_END
