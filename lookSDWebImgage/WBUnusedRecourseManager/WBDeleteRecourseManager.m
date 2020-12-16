//
//  WBDeleteRecourseManager.m
//  HtmlOpenImage
//
//  Created by wmmMac on 2019/4/17.
//  Copyright © 2019 58. All rights reserved.
//

#import "WBDeleteRecourseManager.h"
#import "SDImageCache.h"
#import "SDWebImageManager.h"
#import "SDWebImageDownloader.h"
#import <WBBusinessTool/NSString+MD5Addition.h>
#import "WBToolNetWorkManager.h"
#import "WBTestFlightService.h"
#import <WBTools/WBCommonServerUrls.h>

#define DeleteImageRecource @"DeleteImageRecource"

static NSMutableDictionary <NSString *, NSString *> *imageNameToMd5Path = nil;
static NSMutableDictionary <NSString *, NSString *> *commonImagesDic = nil;
static NSString *filePath = nil;

static SDImageCache *imageCache = nil;
static SDWebImageDownloader *imageDownloader = nil;

//DocumentDirectory目录下建立DeleteImageRecource文件夹
//DocumentDirectory
//  -DeleteImageRecource
//      - app_Version1
//          -com.hackemist.SDWebImageCache.UnUsedImage
//      - app_Version2

@implementation WBDeleteRecourseManager
+ (void)load {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidFinishLaunching:) name:UIApplicationDidFinishLaunchingNotification object:nil];
}

//删除低版本的文件夹文件夹
+ (void)deleteAllFloder {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];

    NSString *pathurl = [NSString stringWithFormat:@"%@/%@", path, DeleteImageRecource];
    //该目录下所有文件夹
    NSArray *fileArrays = [fileManager contentsOfDirectoryAtPath:pathurl error:nil];
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *app_Version = [infoDictionary objectForKey:@"CFBundleShortVersionString"];

    for (NSInteger i = 0; i < fileArrays.count; i++) {
        NSString *floder = [fileArrays objectAtIndex:i];

        if (![floder isEqualToString:app_Version]) {
            [fileManager removeItemAtPath:[NSString stringWithFormat:@"%@/%@", pathurl, floder] error:nil];//删除不是该版本的
        }
    }

    fileArrays = [fileManager contentsOfDirectoryAtPath:pathurl error:nil];
}

+ (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self requestDeleteRecourse];
}

//通过server获取误删除图片的数据
+ (void)requestDeleteRecourse {
    [WBDeleteRecourseManager deleteAllFloder];

    imageNameToMd5Path = [NSMutableDictionary dictionary];
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    //路径
    //DocumentDirectory
    //  -DeleteImageRecource
    //      - app_Version
    //          - com.hackemist.SDWebImageCache.UnUsedImage
    NSString *app_Version = [infoDictionary objectForKey:@"CFBundleShortVersionString"];
    filePath = [NSString stringWithFormat:@"%@/%@/%@", path, DeleteImageRecource, app_Version];

    //创建
    /* imageCache 内部并没有保存图片 而是保存这些内容
     {
        @"内置图片名_1"：@"图片url_1",
        @"内置图片名_2"：@"图片url_2"
     }
     */
    imageCache = [[SDImageCache alloc] initWithNamespace:@"UnUsedImage" diskCacheDirectory:filePath];

    imageDownloader = [SDWebImageDownloader sharedDownloader];

    NSDictionary *imageNameToMd5s = [self imageCacheDictionaryWithKey:@"imageNameToMd5Path"];

    if (imageNameToMd5s) {
        imageNameToMd5Path = [imageNameToMd5s mutableCopy];
    }

    NSString *requestURL = [NSString stringWithFormat:@"%@/resource/imgPatch", @"https://app.58.com/api/base"];
    NSDictionary *requestParmas = @{
            @"dataVersion": [WBDeleteRecourseManager getDataVersion]
    };
    [WBToolNetWorkManager getRequestManagerUrl:requestURL parms:requestParmas Success:^(id result) {
        NSDictionary *resultDic  = (NSDictionary *)result;

        /*
         @{
            @"dataVersion":@"",
            @"commonImages":@{

            }
        }
         */
        /*
         第一次：全返回。
         第二次：
         */
        if ([[resultDic objectForKey:@"code"] integerValue] == 200) { //版本不一致 需要重新保存
            //保存数据版本号
            [WBDeleteRecourseManager saveDataVersion:[resultDic objectForKey:@"dataVersion"]];//服务端每次新添一张会发生dataVersion 变化
            commonImagesDic = resultDic[@"commonImages"];

            if ([commonImagesDic isKindOfClass:NSDictionary.class] && commonImagesDic.allKeys.count > 0) {
                NSData *commonImagesDicToData =    [NSJSONSerialization dataWithJSONObject:commonImagesDic options:0 error:nil];

                [imageCache storeImageDataToDisk:commonImagesDicToData forKey:@"commonImagesDicToData"];

                [WBDeleteRecourseManager downLoadDeleteRecourse:commonImagesDic];
            }
        }
        else if ([[resultDic objectForKey:@"code"] integerValue] == 201) {//版本一致  需要从缓存中获取
            NSDictionary *commonImagesDic = [self imageCacheDictionaryWithKey:@"commonImagesDicToData"];

            if (commonImagesDic) {
                [WBDeleteRecourseManager downLoadDeleteRecourse:commonImagesDic];
            }
        }
    } Failure:^(NSError *error) {
    }];
}

+ (NSDictionary *)imageCacheDictionaryWithKey:(NSString *)key {
    NSData *imageCacheData = [imageCache diskImageDataForKey:key];

    if (!imageCacheData) {
        return nil;
    }

    NSDictionary *imageCacheDic = (NSDictionary *)[NSJSONSerialization JSONObjectWithData:imageCacheData options:0 error:nil];

    if ([imageCacheDic isKindOfClass:NSDictionary.class]) {
        return imageCacheDic;
    }

    return nil;
}

//下载数据并保存
/*
 {
    @"内置图片名_1"：@"图片url_1",
    @"内置图片名_2"：@"图片url_2"
 }
 */
+ (void)downLoadDeleteRecourse:(NSDictionary *)result {
    [imageNameToMd5Path removeAllObjects];

    for (NSInteger i = 0; i < result.allKeys.count; i++) {
        NSString *urlString = [result.allValues objectAtIndex:i];

        //如果不是正确的url跳出当次循环
        if (![WBDeleteRecourseManager isUrl:urlString]) {
            continue;
        }

        //下载的时候把图片名字转为MD5值
        NSString *md5String = [[NSString stringWithFormat:@"%@+%@", [result.allKeys objectAtIndex:i], urlString] string02XFromMD5];
        [imageNameToMd5Path setObject:md5String forKey:[result.allKeys objectAtIndex:i]];

        //如果磁盘和缓存中没有数据就去下载，下载完成后缓存
        if (![imageCache diskImageDataExistsWithKey:md5String]) {
            //构造数据
            [imageDownloader downloadImageWithURL:[NSURL URLWithString:urlString] options:0 progress:^(NSInteger receivedSize, NSInteger expectedSize, NSURL *_Nullable targetURL) {
            } completed:^(UIImage *_Nullable image, NSData *_Nullable data, NSError *_Nullable error, BOOL finished) {
                if (image && finished) {
                    //下载下来之后保存在内存 并保存在沙盒中
                    [imageCache storeImage:image forKey:md5String toDisk:YES completion:^{}];
                }
            }];
        }
    }

    //imageNameToMd5Path 也存到磁盘中
    NSData *commonImagesDicToData = [NSJSONSerialization dataWithJSONObject:imageNameToMd5Path options:0 error:nil];
    [imageCache storeImageDataToDisk:commonImagesDicToData forKey:@"imageNameToMd5Path"];
}

//从沙箱中读取图片路径
+ (UIImage *)readImageFormDocumence:(NSString *)name {
    NSString *md5String = [imageNameToMd5Path objectForKey:name];
    UIImage *image = nil;

    if (md5String && md5String.length > 0) {
        image = [imageCache imageFromCacheForKey:md5String];
    }

    return image;
}

//判断图片是否存在
+ (UIImage *)judgeImage:(UIImage *)image imageName:(NSString *)imageName {
    if (image != nil) { //如果图片存在则返回
        return image;
    }
    else {
        [WBDeleteRecourseManager reportingServer:imageName];//不存在则上报server
        return [WBDeleteRecourseManager readImageFormDocumence:imageName];
    }

    return nil;
}

//获取bundle中的图片名
+ (NSString *)getImageNameFormBundle:(NSString *)bundlePath {
    NSString *imageName = @"";

    if ([bundlePath containsString:@"bundle/"]) {
        NSArray *nameArray = [bundlePath componentsSeparatedByString:@"/"];

        if (nameArray.count > 0) {
            imageName = [nameArray lastObject];
        }
    }
    else {
        imageName = bundlePath;
    }

    //处理扩展名
    imageName = [WBDeleteRecourseManager deleteExtensionName:imageName];
    return imageName;
}

//获取路径获取图片名
+ (NSString *)getImageNameFormImagePath:(NSString *)imagePath {
    NSArray *nameArray = [imagePath componentsSeparatedByString:@"/"];
    NSString *totalImageName = @"";

    if (nameArray.count > 0) {
        totalImageName = [nameArray lastObject];
    }

    //处理扩展名
    totalImageName = [WBDeleteRecourseManager deleteExtensionName:totalImageName];
    return totalImageName;
}

//删除扩展名
+ (NSString *)deleteExtensionName:(NSString *)imageName {
    NSString *imageString = imageName;

    if ([imageName containsString:@".png"] ||
        [imageName containsString:@".jpg"]) {
        imageString = [imageName substringToIndex:imageName.length - 4];
    }

    return imageString;
}

//上报服务器
+ (void)reportingServer:(NSString *)name {
    //如何不是appstore包在上报
    if ([WBTestFlightService currentAppEnvironment] != WBAppEnvironmentAppStore) {
        if (!WB_BASE_HOST_OSS_STR_BRANDNEW) {
            return;
        }

        return;

        NSString *url = [NSString stringWithFormat:@"%@/resource/upLoadImg", WB_BASE_HOST_OSS_STR_BRANDNEW]; //测试域名
        NSString *nameString = [name stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([nameString isKindOfClass:NSString.class] && nameString.length > 0) {
            NSDictionary *parms = @{
                    @"imageName": nameString
            };
            [WBToolNetWorkManager getRequestManagerUrl:url parms:parms Success:^(id result) {
            } Failure:^(NSError *error) {
            }];
        }
    }
}

//获取本地的数据版本号
+ (NSString *)getDataVersion {
    NSString *dataVersion = [[NSUserDefaults standardUserDefaults] objectForKey:@"dataVersion"];

    if ([dataVersion isKindOfClass:NSString.class] && dataVersion && dataVersion.length > 0) {
        return dataVersion;
    }

    return @"0";
}

//保存数据版本号
+ (void)saveDataVersion:(NSString *)dataVersion {
    [[NSUserDefaults standardUserDefaults] setObject:dataVersion forKey:@"dataVersion"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

//判断是否为url
+ (BOOL)isUrl:(NSString *)urlString {
    if (urlString == nil) {
        return NO;
    }

    NSString *url;

    if (urlString.length > 4 && [[urlString substringToIndex:4] isEqualToString:@"www."]) {
        url = [NSString stringWithFormat:@"http://%@", self];
    }
    else {
        url = urlString;
    }

    NSString *urlRegex = @"\\bhttps?://[a-zA-Z0-9\\-.]+(?::(\\d+))?(?:(?:/[a-zA-Z0-9\\-._?,'+\\&%$=~*!():@\\\\]*)+)?";
    NSPredicate *urlTest = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", urlRegex];
    return [urlTest evaluateWithObject:url];
}

@end
