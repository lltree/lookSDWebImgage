//
//  WBToolNetWorkManager.h
//  BuildinTool
//
//  Created by wm on 2018/6/12.
//  Copyright © 2018年 58.com. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface WBToolNetWorkManager : NSObject
+(void)getRequestManagerUrl:(NSString *)url parms:(NSDictionary *)parameters Success:(void(^)(id result))success Failure:(void(^)(NSError *error))failure;
@end
