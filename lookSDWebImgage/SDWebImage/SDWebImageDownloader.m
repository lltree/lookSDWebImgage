/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"

#define LOCK(lock)   dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

@interface SDWebImageDownloadToken ()

@property (nonatomic, weak, nullable) NSOperation<SDWebImageDownloaderOperationInterface> *downloadOperation;

@end

@implementation SDWebImageDownloadToken

- (void)cancel {
    if (self.downloadOperation) {
        SDWebImageDownloadToken *cancelToken = self.downloadOperationCancelToken;

        if (cancelToken) {
            [self.downloadOperation cancel:cancelToken];
        }
    }
}

@end

@interface SDWebImageDownloader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

@property (strong, nonatomic, nonnull) NSOperationQueue *downloadQueue;
@property (weak, nonatomic, nullable) NSOperation *lastAddedOperation;//上次添加进来的Operation
@property (assign, nonatomic, nullable) Class operationClass;//要创建的Operation类名
@property (strong, nonatomic, nonnull) NSMutableDictionary<NSURL *, SDWebImageDownloaderOperation *> *URLOperations;//DownloaderOperation
@property (strong, nonatomic, nullable) SDHTTPHeadersMutableDictionary *HTTPHeaders;
@property (strong, nonatomic, nonnull) dispatch_semaphore_t operationsLock; // a lock to keep the access to `URLOperations` thread-safe
@property (strong, nonatomic, nonnull) dispatch_semaphore_t headersLock; // a lock to keep the access to `HTTPHeaders` thread-safe

// The session in which data tasks will run
@property (strong, nonatomic) NSURLSession *session;

@end

@implementation SDWebImageDownloader

+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (nonnull instancetype)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (nonnull instancetype)init {
    //创建默认会话模式（default）
    return [self initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
}

- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration {
    if ((self = [super init])) {
        _operationClass = [SDWebImageDownloaderOperation class]; //定义ImageDownloaderOperation的类名
        _shouldDecompressImages = YES;
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;

        _downloadQueue = [NSOperationQueue new];//创建全局队列 ，默认6个
        _downloadQueue.maxConcurrentOperationCount = 6;
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";

        _URLOperations = [NSMutableDictionary new];
#ifdef SD_WEBP
        _HTTPHeaders = [@{ @"Accept": @"image/webp,image/*;q=0.8" } mutableCopy];
#else
        _HTTPHeaders = [@{ @"Accept": @"image/*;q=0.8" } mutableCopy];
#endif
        _operationsLock = dispatch_semaphore_create(1);
        _headersLock = dispatch_semaphore_create(1);
        _downloadTimeout = 15.0; //默认超时15秒

        [self createNewSessionWithConfiguration:sessionConfiguration];
    }

    return self;
}

- (void)createNewSessionWithConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    [self cancelAllDownloads];

    if (self.session) {
        [self.session invalidateAndCancel];
    }

    //会话超时时间
    sessionConfiguration.timeoutIntervalForRequest = self.downloadTimeout;

    /**
     *  Create the session for this task
     *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
     *  method calls and completion handler calls.
     */
    //创建一个会话
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                 delegate:self
                                            delegateQueue:nil];
}

- (void)invalidateSessionAndCancel:(BOOL)cancelPendingOperations {
    if (self == [SDWebImageDownloader sharedDownloader]) {
        return;
    }

    if (cancelPendingOperations) {

        /*
         取消所有未完成的任务，然后使会话失效。（有任务，取消所有任务）
        一旦失效，对委托和回调对象的引用就会被破坏。无效后，会话对象不能重用。

        在由sharedSession方法返回的会话上调用此方法不起作用。
         */

        [self.session invalidateAndCancel];
    }
    else {
        /*
         使会话无效，允许任何未完成的任务完成(有任务，继续任务)
         此方法立即返回，无需等待任务完成。 一旦会话失效，无法在会话中创建新任务，但现有任务会一直持续到完成。 在最后一个任务完成并且会话进行与这些任务相关的最后一个委托调用之后，会话将在其委托上调用URLSession：didBecomeInvalidWithError：方法，然后中断对委托和回调对象的引用。 无效后，会话对象不能重用。
         */
        [self.session finishTasksAndInvalidate];
    }
}

- (void)dealloc {
    [self.session invalidateAndCancel];
    self.session = nil;

    [self.downloadQueue cancelAllOperations];
}

#pragma mark - HTTPHeaders添加 删除field
/*
 如果 value 有值则添加到HTTPHeaders中
 否则 删除HTTPHeaders对应的key
 */
- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field {
    LOCK(self.headersLock);

    if (value) {
        self.HTTPHeaders[field] = value;
    }
    else {
        [self.HTTPHeaders removeObjectForKey:field];
    }

    UNLOCK(self.headersLock);
}

- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field {
    if (!field) {
        return nil;
    }

    return [[self allHTTPHeaderFields] objectForKey:field];
}

- (nonnull SDHTTPHeadersDictionary *)allHTTPHeaderFields {
    LOCK(self.headersLock);
    SDHTTPHeadersDictionary *allHTTPHeaderFields = [self.HTTPHeaders copy];
    UNLOCK(self.headersLock);
    return allHTTPHeaderFields;
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;
}

- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;
}

- (NSURLSessionConfiguration *)sessionConfiguration {
    return self.session.configuration;
}

- (void)setOperationClass:(nullable Class)operationClass {
    //支持自定义
    if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperationInterface)]) {
        _operationClass = operationClass;
    }
    else {
        //默认的
        _operationClass = [SDWebImageDownloaderOperation class];
    }
}

#pragma mark - 返回一个DownloadToken 下载就在这里进行了
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
    __weak SDWebImageDownloader *wself = self;

    return [self addProgressCallback:progressBlock completedBlock:completedBlock forURL:url createCallback:^SDWebImageDownloaderOperation *{
        __strong __typeof (wself) sself = wself;
        NSTimeInterval timeoutInterval = sself.downloadTimeout;

        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                    cachePolicy:cachePolicy
                                                                timeoutInterval:timeoutInterval];

        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        request.HTTPShouldUsePipelining = YES;

        if (sself.headersFilter) {
            request.allHTTPHeaderFields = sself.headersFilter(url, [sself allHTTPHeaderFields]);
        }
        else {
            request.allHTTPHeaderFields = [sself allHTTPHeaderFields];
        }

        SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
        operation.shouldDecompressImages = sself.shouldDecompressImages;

        if (sself.urlCredential) {
            operation.credential = sself.urlCredential;
        }
        else if (sself.username && sself.password) { //
            operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
        }

        //在队列中调度质量
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        }
        else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }

        if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [sself.lastAddedOperation addDependency:operation];
            sself.lastAddedOperation = operation;
        }

        return operation;
    }];
}

- (nullable SDWebImageDownloadToken *)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock
                                           completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock
                                                   forURL:(nullable NSURL *)url
                                           createCallback:(SDWebImageDownloaderOperation *(^)(void))createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }

        return nil;
    }

    LOCK(self.operationsLock);
    //
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];

    // There is a case that the operation may be marked as finished, but not been removed from `self.URLOperations`.
    // 从sharedDownloader的URLOperations后获取operation 如果operation不存在或者已经完成，则重新创建operation
    if (!operation || operation.isFinished) {
        operation = createCallback();
        __weak typeof(self) wself = self;
        operation.completionBlock = ^{
            __strong typeof(wself) sself = wself;

            if (!sself) {
                return;
            }

            LOCK(sself.operationsLock);
            [sself.URLOperations removeObjectForKey:url];//队列执行完成则从URLOperations中删除
            UNLOCK(sself.operationsLock);
        };
        [self.URLOperations setObject:operation forKey:url];
        // Add operation to operation queue only after all configuration done according to Apple's doc.
        // `addOperation:` does not synchronously execute the `operation.completionBlock` so this will not cause deadlock.
        //扔到队列中执行
        [self.downloadQueue addOperation:operation];
    }

    UNLOCK(self.operationsLock);

    //创建ImageDownloadToken
    id downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];

    SDWebImageDownloadToken *token = [SDWebImageDownloadToken new];
    token.downloadOperation = operation;
    token.url = url;
    token.downloadOperationCancelToken = downloadOperationCancelToken;

    return token;
}

- (void)cancel:(nullable SDWebImageDownloadToken *)token {
    NSURL *url = token.url;

    if (!url) {
        return;
    }

    LOCK(self.operationsLock);
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];

    if (operation) {
        BOOL canceled = [operation cancel:token.downloadOperationCancelToken];

        if (canceled) {
            [self.URLOperations removeObjectForKey:url];
        }
    }

    UNLOCK(self.operationsLock);
}

//挂起
- (void)setSuspended:(BOOL)suspended {
    self.downloadQueue.suspended = suspended;
}

- (void)cancelAllDownloads {
    [self.downloadQueue cancelAllOperations];
}

#pragma mark Helper methods

- (SDWebImageDownloaderOperation *)operationWithTask:(NSURLSessionTask *)task {
    SDWebImageDownloaderOperation *returnOperation = nil;

    for (SDWebImageDownloaderOperation *operation in self.downloadQueue.operations) {
        if (operation.dataTask.taskIdentifier == task.taskIdentifier) {
            returnOperation = operation;
            break;
        }
    }

    return returnOperation;
}

#pragma mark - NSURLSessionDataDelegate

- (void)    URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
    }
    else {
        if (completionHandler) {
            completionHandler(NSURLSessionResponseAllow);
        }
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveData:data];
    }
}

- (void)   URLSession:(NSURLSession *)session
             dataTask:(NSURLSessionDataTask *)dataTask
    willCacheResponse:(NSCachedURLResponse *)proposedResponse
    completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];

    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:willCacheResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
    }
    else {
        if (completionHandler) {
            completionHandler(proposedResponse);
        }
    }
}

#pragma mark NSURLSessionTaskDelegate
/*
 通知URL会话该会话已失效。
 如果通过调用finishTasksAndInvalidate方法使会话失效，则会话将一直等待，
 直到会话中的最终任务完成或失败，然后再调用此委托方法。如果您调用invalidateAndCancel方法，会话将立即调用此委托方法。
 */
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {

    //取出dataOperation，让dataOperation 处理
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    if ([dataOperation respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [dataOperation URLSession:session task:task didCompleteWithError:error];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    if ([dataOperation respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)]) {
        [dataOperation URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:completionHandler];
    }
    else {
        if (completionHandler) {
            completionHandler(request);
        }
    }
}
/*
 响应来自远程服务器的会话级别认证请求，从代理请求凭据。
这种方法在两种情况下被调用：
1、远程服务器请求客户端证书或Windows NT LAN Manager（NTLM）身份验证时，允许您的应用程序提供适当的凭据
2、当会话首先建立与使用SSL或TLS的远程服务器的连接时，允许您的应用程序验证服务器的证书链
如果您未实现此方法，则会话会调用其委托的URLSession：task：didReceiveChallenge：completionHandler：方法。
注：此方法仅处理NSURLAuthenticationMethodNTLM，NSURLAuthenticationMethodNegotiate，NSURLAuthenticationMethodClientCertificate和NSURLAuthenticationMethodServerTrust身份验证类型。对于所有其他认证方案，会话仅调用URLSession：task：didReceiveChallenge：completionHandler：方法。 */

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];

    if ([dataOperation respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
        [dataOperation URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
    }
    else {
        if (completionHandler) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    }
}

@end
