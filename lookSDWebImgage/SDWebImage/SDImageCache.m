/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "NSImage+WebCache.h"
#import "SDWebImageCodersManager.h"

#define LOCK(lock)   dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

//计算图片大小
FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
#if SD_MAC
    return image.size.height * image.size.width;

#elif SD_UIKIT || SD_WATCH
    return image.size.height * image.size.width * image.scale * image.scale;

#endif
}

// 继承NSCache
/*
 线程安全
 key：强引用
 自动进行缓存的清理
 */
// A memory cache which auto purge the cache on memory warning and support weak cache.
@interface SDMemoryCache <KeyType, ObjectType> : NSCache <KeyType, ObjectType>

@end

// Private
@interface SDMemoryCache <KeyType, ObjectType> ()

@property (nonatomic, strong, nonnull) SDImageCacheConfig *config;
@property (nonatomic, strong, nonnull) NSMapTable<KeyType, ObjectType> *weakCache; // strong-weak cache
@property (nonatomic, strong, nonnull) dispatch_semaphore_t weakCacheLock; // a lock to keep the access to `weakCache` thread-safe

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithConfig:(nonnull SDImageCacheConfig *)config;

@end

@implementation SDMemoryCache

// Current this seems no use on macOS (macOS use virtual memory and do not clear cache when memory warning). So we only override on iOS/tvOS platform.
// But in the future there may be more options and features for this subclass.
#if SD_UIKIT

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    self = [super init];

    if (self) {
        // Use a strong-weak maptable storing the secondary cache. Follow the doc that NSCache does not copy keys
        // This is useful when the memory warning, the cache was purged. However, the image instance can be retained by other instance such as imageViews and alive.
        // At this case, we can sync weak cache back and do not need to load from disk cache
        self.weakCache = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];//采用强Key 弱Value存储
        self.weakCacheLock = dispatch_semaphore_create(1);
        self.config = config;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }

    return self;
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    // Only remove cache, but keep weak cache
    [super removeAllObjects];
}

// `setObject:forKey:` just call this with 0 cost. Override this is enough
- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)g {
    [super setObject:obj forKey:key cost:g];

    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }

    if (key && obj) {
        // Store weak cache
        LOCK(self.weakCacheLock);
        [self.weakCache setObject:obj forKey:key];
        UNLOCK(self.weakCacheLock);
    }
}

- (id)objectForKey:(id)key {
    id obj = [super objectForKey:key];

    if (!self.config.shouldUseWeakMemoryCache) {
        return obj;
    }

    if (key && !obj) {
        // Check weak cache
        LOCK(self.weakCacheLock);
        obj = [self.weakCache objectForKey:key];
        UNLOCK(self.weakCacheLock);

        if (obj) {
            // Sync cache
            NSUInteger cost = 0;

            if ([obj isKindOfClass:[UIImage class]]) {
                cost = SDCacheCostForImage(obj);
            }

            [super setObject:obj forKey:key cost:cost];
        }
    }

    return obj;
}

- (void)removeObjectForKey:(id)key {
    [super removeObjectForKey:key];

    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }

    if (key) {
        // Remove weak cache
        LOCK(self.weakCacheLock);
        [self.weakCache removeObjectForKey:key];
        UNLOCK(self.weakCacheLock);
    }
}

- (void)removeAllObjects {
    [super removeAllObjects];

    if (!self.config.shouldUseWeakMemoryCache) {
        return;
    }

    // Manually remove should also remove weak cache
    LOCK(self.weakCacheLock);
    [self.weakCache removeAllObjects];
    UNLOCK(self.weakCacheLock);
}

#else

- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    self = [super init];
    return self;
}

#endif

@end

@interface SDImageCache ()

#pragma mark - Properties
@property (strong, nonatomic, nonnull) SDMemoryCache *memCache;
@property (strong, nonatomic, nonnull) NSString *diskCachePath;
@property (strong, nonatomic, nullable) NSMutableArray<NSString *> *customPaths;
@property (strong, nonatomic, nullable) dispatch_queue_t ioQueue;
@property (strong, nonatomic, nonnull) NSFileManager *fileManager;

@end

@implementation SDImageCache

#pragma mark - Singleton, init, dealloc

+ (nonnull instancetype)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

- (instancetype)init {
    return [self initWithNamespace:@"default"];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    NSString *path = [self makeDiskCachePath:ns];//在磁盘中创建一个缓存目录
    return [self initWithNamespace:ns diskCacheDirectory:path];
}

- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
        //
        ///directory = data/Containers/Data/Application/2C0C6D9F-CAA6-4E26-B61E-AFF60862F809/Library/Caches/default
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];

        // Create IO serial queue
        //创建IO串行队列
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);

        _config = [[SDImageCacheConfig alloc] init];

        // Init the memory cache
        _memCache = [[SDMemoryCache alloc] initWithConfig:_config];
        _memCache.name = fullNamespace;

        // Init the disk cache
        if (directory != nil) {
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        }
        else {
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }

        ///Users/lltree/Library/Developer/CoreSimulator/Devices/DAEB3DC2-3A59-40C8-BE21-48C90A3E80C3/data/Containers/Data/Application/70F01DB4-0EB7-4BF4-AEDE-B63515AFE311/Library/Caches/default/com.hackemist.SDWebImageCache.default

        dispatch_sync(_ioQueue, ^{
            self.fileManager = [NSFileManager new];
        });

#if SD_UIKIT
        /*
         UIApplicationWillTerminateNotification 是应用即将终止的时候调用,但是我发现并没有调用 , Google 了一下
         得出最终结论 :
         1.应用在前台,双击 Home 键 ,终止应用 , UIApplicationWillTerminateNotification 调用
         2.应用在前台,单击 Home 键,进入桌面 , 再终止应用 UIApplicationWillTerminateNotification 不会被调用.
         */
        // Subscribe to app events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Cache paths 存储路径

- (void)addReadOnlyCachePath:(nonnull NSString *)path {
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }

    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}

///Users/lltree/Library/Developer/CoreSimulator/Devices/DAEB3DC2-3A59-40C8-BE21-48C90A3E80C3/data/Containers/Data/Application/70F01DB4-0EB7-4BF4-AEDE-B63515AFE311/Library/Caches/default/com.hackemist.SDWebImageCache.default/MD5字符串
- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {

    NSString *filename = [self cachedFileNameForKey:key];

    return [path stringByAppendingPathComponent:filename];
}

//
- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}

//把网址转变成MD5
- (nullable NSString *)cachedFileNameForKey:(nullable NSString *)key {
    const char *str = key.UTF8String;

    if (str == NULL) {
        str = "";
    }

    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSURL *keyURL = [NSURL URLWithString:key];
    NSString *ext = keyURL ? keyURL.pathExtension : key.pathExtension;
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext.length == 0 ? @"" : [NSString stringWithFormat:@".%@", ext]];
    return filename;
}

- (nullable NSString *)makeDiskCachePath:(nonnull NSString *)fullNamespace {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}

#pragma mark - Store Ops 存储操作

- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:YES completion:completionBlock];
}

- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk completion:completionBlock];
}

/*
    toDisk : 保存到memCache的同时，是否也保存到沙盒中
 */
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    if (!image || !key) {
        if (completionBlock) {
            completionBlock();
        }

        return;
    }

    // if memory cache is enabled
    if (self.config.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(image);
        [self.memCache setObject:image forKey:key cost:cost];
    }

    if (toDisk) {
        dispatch_async(self.ioQueue, ^{
            @autoreleasepool {
                NSData *data = imageData;

                if (!data && image) {
                    // If we do not have any data to detect image format, check whether it contains alpha channel to use PNG or JPEG format
                    SDImageFormat format;

                    if (SDCGImageRefContainsAlpha(image.CGImage)) {
                        format = SDImageFormatPNG;
                    }
                    else {
                        format = SDImageFormatJPEG;
                    }

                    //image 转变成 imageData
                    data = [[SDWebImageCodersManager sharedInstance] encodedDataWithImage:image format:format];
                }

                [self _storeImageDataToDisk:data forKey:key];
            }

            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock();
                });
            }
        });
    }
    else {
        if (completionBlock) {
            completionBlock();
        }
    }
}

- (void)storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
    if (!imageData || !key) {
        return;
    }

    dispatch_sync(self.ioQueue, ^{
        [self _storeImageDataToDisk:imageData forKey:key];
    });
}

// Make sure to call form io queue by caller
//
- (void)_storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
    if (!imageData || !key) {
        return;
    }

    if (![self.fileManager fileExistsAtPath:_diskCachePath]) {
        [self.fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    // get cache Path for image key
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
    //写入沙盒中
    //file:///Users/lltree/Library/Developer/CoreSimulator/Devices/DAEB3DC2-3A59-40C8-BE21-48C90A3E80C3/data/Containers/Data/Application/B780A740-1005-4D4F-B998-1710CDAE9B4F/Library/Caches/default/com.hackemist.SDWebImageCache.default/e443cfe482237e50a7f2e2ae2e47f0cc
    [imageData writeToURL:fileURL options:self.config.diskCacheWritingOptions error:nil];

    // disable iCloud backup
    if (self.config.shouldDisableiCloud) {
        [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}

#pragma mark - Query and Retrieve Ops 查询和检索

- (void)diskImageExistsWithKey:(nullable NSString *)key completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        BOOL exists = [self _diskImageDataExistsWithKey:key];

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

//沙盒中是否存在该 key对应下的图片
- (BOOL)diskImageDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }

    __block BOOL exists = NO;
    dispatch_sync(self.ioQueue, ^{
        exists = [self _diskImageDataExistsWithKey:key];
    });

    return exists;
}

// Make sure to call form io queue by caller
- (BOOL)_diskImageDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }

    BOOL exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {
        exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key].stringByDeletingPathExtension];
    }

    return exists;
}

//从沙盒中获取图片的NSData数据
- (nullable NSData *)diskImageDataForKey:(nullable NSString *)key {
    if (!key) {
        return nil;
    }

    __block NSData *imageData = nil;
    dispatch_sync(self.ioQueue, ^{
        imageData = [self diskImageDataBySearchingAllPathsForKey:key];
    });

    return imageData;
}

//从内存中获取UIImage
- (nullable UIImage *)imageFromMemoryCacheForKey:(nullable NSString *)key {
    //先从memCache 中获取
    return [self.memCache objectForKey:key];
}

//磁盘中获取UIImage
- (nullable UIImage *)imageFromDiskCacheForKey:(nullable NSString *)key {
    UIImage *diskImage = [self diskImageForKey:key];

    if (diskImage && self.config.shouldCacheImagesInMemory) {
        NSUInteger cost = SDCacheCostForImage(diskImage);
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}

//从存储中获取UIImage
- (nullable UIImage *)imageFromCacheForKey:(nullable NSString *)key {
    // First check the in-memory cache...
    UIImage *image = [self imageFromMemoryCacheForKey:key];

    if (image) {
        return image;
    }

    // Second check the disk cache...
    image = [self imageFromDiskCacheForKey:key];
    return image;
}

- (nullable NSData *)diskImageDataBySearchingAllPathsForKey:(nullable NSString *)key {
    NSString *defaultPath = [self defaultCachePathForKey:key];//先从沙盒中找NSData数据
    NSData *data = [NSData dataWithContentsOfFile:defaultPath options:self.config.diskCacheReadingOptions error:nil];

    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];

    if (data) {
        return data;
    }

    NSArray<NSString *> *customPaths = [self.customPaths copy];

    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];

        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        imageData = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];

        if (imageData) {
            return imageData;
        }
    }

    return nil;
}

- (nullable UIImage *)diskImageForKey:(nullable NSString *)key {
    NSData *data = [self diskImageDataForKey:key];
    return [self diskImageForKey:key data:data];
}

- (nullable UIImage *)diskImageForKey:(nullable NSString *)key data:(nullable NSData *)data {
    return [self diskImageForKey:key data:data options:0];
}

- (nullable UIImage *)diskImageForKey:(nullable NSString *)key data:(nullable NSData *)data options:(SDImageCacheOptions)options {
    if (data) {
        UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:data];
        image = [self scaledImageForKey:key image:image];

        if (self.config.shouldDecompressImages) {
            BOOL shouldScaleDown = options & SDImageCacheScaleDownLargeImages;
            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{ SDWebImageCoderScaleDownLargeImagesKey: @(shouldScaleDown) }];
        }

        return image;
    }
    else {
        return nil;
    }
}

- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}

- (NSOperation *)queryCacheOperationForKey:(NSString *)key done:(SDCacheQueryCompletedBlock)doneBlock {
    return [self queryCacheOperationForKey:key options:0 done:doneBlock];
}

//Query
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key options:(SDImageCacheOptions)options done:(nullable SDCacheQueryCompletedBlock)doneBlock {
    if (!key) {
        if (doneBlock) {
            doneBlock(nil, nil, SDImageCacheTypeNone);
        }

        return nil;
    }

    // First check the in-memory cache...
    // 先从Memory内存中获取，不包含沙盒
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    BOOL shouldQueryMemoryOnly = (image && !(options & SDImageCacheQueryDataWhenInMemory));//当内存中有缓存了仍要查询 沙盒

    if (shouldQueryMemoryOnly) {
        if (doneBlock) {
            doneBlock(image, nil, SDImageCacheTypeMemory);
        }

        return nil;
    }

    NSOperation *operation = [NSOperation new];
    void (^ queryDiskBlock)(void) =  ^{
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            return;
        }

        @autoreleasepool {
            //从沙盒中找数据
            NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
            UIImage *diskImage;
            SDImageCacheType cacheType = SDImageCacheTypeDisk;

            if (image) {//这不是骗人吗，明显从内存中国获取的最后还是返回了磁盘中的
            // the image is from in-memory cache
            // 从内存中找到了但是非让再从沙盒中找一遍
                diskImage = image;
                cacheType = SDImageCacheTypeMemory;//沙盒中的数据
            }
            else if (diskData) {
            // decode image data only if in-memory cache missed
            //把数据转换成图片
                diskImage = [self diskImageForKey:key data:diskData options:options];

            //shouldCacheImagesInMemory允许使用内存，则放到MemoryCache中
            //重新放到memCache中，方便下次使用
                if (diskImage && self.config.shouldCacheImagesInMemory) {
                    NSUInteger cost = SDCacheCostForImage(diskImage);
                    [self.memCache setObject:diskImage forKey:key cost:cost];
                }
            }

            if (doneBlock) {
                if (options & SDImageCacheQueryDiskSync) {
                    doneBlock(diskImage, diskData, cacheType);
                }
                else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        doneBlock(diskImage, diskData, cacheType);
                    });
                }
            }
        }
    };

    if (options & SDImageCacheQueryDiskSync) {//同步方式返回沙盒数据
        queryDiskBlock();
    }
    else {
        dispatch_async(self.ioQueue, queryDiskBlock);//默认异步返回沙盒数据
    }

    return operation;
}

#pragma mark - Remove Ops 删除操作

- (void)removeImageForKey:(nullable NSString *)key withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}

- (void)removeImageForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    if (key == nil) {
        return;
    }

    if (self.config.shouldCacheImagesInMemory) {
        [self.memCache removeObjectForKey:key];
    }

    if (fromDisk) {
        dispatch_async(self.ioQueue, ^{
            [self.fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
    }
    else if (completion) {
        completion();
    }
}

# pragma mark - Mem Cache settings 设置缓存最大数量 占用内存

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

#pragma mark - Cache clean Ops  Cache清除操作

- (void)clearMemory {
    [self.memCache removeAllObjects];
}

- (void)clearDiskOnCompletion:(nullable SDWebImageNoParamsBlock)completion {
    dispatch_async(self.ioQueue, ^{
        [self.fileManager removeItemAtPath:self.diskCachePath error:nil];
        [self.fileManager createDirectoryAtPath:self.diskCachePath
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:NULL];

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}

- (void)deleteOldFiles {
    [self deleteOldFilesWithCompletionBlock:nil];
}

- (void)deleteOldFilesWithCompletionBlock:(nullable SDWebImageNoParamsBlock)completionBlock {
    dispatch_async(self.ioQueue, ^{
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

        // Compute content date key to be used for tests
        NSURLResourceKey cacheContentDateKey = NSURLContentModificationDateKey;
        switch (self.config.diskCacheExpireType) {
            case SDImageCacheConfigExpireTypeAccessDate:
                cacheContentDateKey = NSURLContentAccessDateKey;
                break;

            case SDImageCacheConfigExpireTypeModificationDate:
                cacheContentDateKey = NSURLContentModificationDateKey;
                break;

            default:
                break;
        }

        NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, cacheContentDateKey, NSURLTotalFileAllocatedSizeKey];

        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                       includingPropertiesForKeys:resourceKeys
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                     errorHandler:NULL];

        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.config.maxCacheAge];
        NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];

        for (NSURL *fileURL in fileEnumerator) {
            NSError *error;
            NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];

            // Skip directories and errors.
            if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // Remove files that are older than the expiration date;
            // 删除过期的数据
            NSDate *modifiedDate = resourceValues[cacheContentDateKey];

            if ([[modifiedDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // Store a reference to this file and account for its total size.
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
            cacheFiles[fileURL] = resourceValues;
        }

        for (NSURL *fileURL in urlsToDelete) {
            [self.fileManager removeItemAtURL:fileURL error:nil];
        }

        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        if (self.config.maxCacheSize > 0 && currentCacheSize > self.config.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
            const NSUInteger desiredCacheSize = self.config.maxCacheSize / 2;

            // Sort the remaining cache files by their last modification time (oldest first).
            //排序，老的在前，新修改的在前
            NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                     usingComparator:^NSComparisonResult (id obj1, id obj2) {
                return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
            }];

            // Delete files until we fall below our desired cache size.
            for (NSURL *fileURL in sortedFiles) {
                if ([self.fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;

                    //一直删除，删到允许保存的内存下降到desiredCacheSize为止
                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

#if SD_UIKIT
- (void)backgroundDeleteOldFiles {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");

    if (!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }

    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // Start the long-running task and return immediately.
    [self deleteOldFilesWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}

#endif

#pragma mark - Cache Info

- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];

        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary<NSString *, id> *attrs = [self.fileManager attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}

//占用磁盘数量
- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
        count = fileEnumerator.allObjects.count;
    });
    return count;
}

//占用磁盘大小
- (void)calculateSizeWithCompletionBlock:(nullable SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                       includingPropertiesForKeys:@[NSFileSize]
                                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                     errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += fileSize.unsignedIntegerValue;
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}

@end
