//
//  WBToolNetWorkManager.m
//  BuildinTool
//
//  Created by wm on 2018/6/12.
//  Copyright © 2018年 58.com. All rights reserved.
//

#import "WBToolNetWorkManager.h"
//#import <WBCommonValue/WBOpenUDID.h>
@implementation WBToolNetWorkManager

+ (void)getRequestManagerUrl:(NSString *)url parms:(NSDictionary *)parameters Success:(void (^)(id result))success Failure:(void (^)(NSError *error))failure {

    if (![url isKindOfClass:NSString.class] || !url) {
        return;
    }

    NSMutableString *mutableUrl = [[NSMutableString alloc] initWithString:url];

    if ([parameters allKeys]) {
        [mutableUrl appendString:@"?"];

        for (id key in parameters) {
            NSString *value = [[parameters objectForKey:key] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            [mutableUrl appendString:[NSString stringWithFormat:@"%@=%@&", key, value]];
        }
    }

    NSString *urlEnCode = [[mutable Url substringToIndex:mutableUrl.length - 1] stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *urlRequest = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:urlEnCode]];
    urlRequest = [self prepareHeaderForRequest:urlRequest];
    NSURLSession *urlSession = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [urlSession dataTaskWithRequest:urlRequest completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response, NSError *_Nullable error) {
        if (!data || error) {
            if (failure) {
                failure(error);
            }
        }
        else {
            NSDictionary *dic = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];

            if (success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                                   success(dic);
                               });
            }
        }
    }];
    [dataTask resume];
}

+ (NSMutableURLRequest *)prepareHeaderForRequest:(NSMutableURLRequest *)request {
    [request setValue:[WBToolNetWorkManager getVersion] forHTTPHeaderField:@"cversion"];
    [request setValue:@"ios" forHTTPHeaderField:@"os"];
//    [request setValue:[WBOpenUDID value] forHTTPHeaderField:@"openudid"];
    return request;
}

+ (NSString *)getVersion {
    NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
    NSString *app_Version = [infoDictionary objectForKey:@"CFBundleShortVersionString"];
    return app_Version;
}

@end
