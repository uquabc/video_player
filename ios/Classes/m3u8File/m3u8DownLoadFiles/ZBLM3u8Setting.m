//
//  ZBLM3U8Setting.m
//  M3U8DownLoadTest
//
//  Created by zengbailiang on 10/6/17.
//  Copyright © 2017 controling. All rights reserved.
//

#import "ZBLM3u8Setting.h"
#import "NSString+m3u8.h"

@implementation ZBLM3u8Setting
#pragma mark - download Controller parameter
+ (NSInteger)maxConcurrentMovieDownloadCount
{
    return 2;
}
+ (NSInteger)maxTsFileDownloadCount
{
    return 20;
}

#pragma mark - service
+ (NSString *)localHost
{
    return @"http://127.0.0.1:8080";
}
+ (NSString *)port
{
    return @"8080";
}

#pragma mark - dir/fileName

///下载临时存放目录
+ (NSString *)downloadTemporaryPath {
    return  [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES) objectAtIndex:0] stringByAppendingPathComponent:@"m3u8files"];//
}

///下载完成地址
+ (NSString *)commonDirPrefix
{
    return  [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES) objectAtIndex:0] stringByAppendingPathComponent:@"temporaryDir"];
}
+ (NSString *)m3u8InfoFileName
{
    return @"movie.m3u8";
}

+ (NSString *)oriM3u8InfoFileName
{
    return @"oriMovie.m3u8";
}

+ (NSString *)keyFileName
{
    return @"key";
}
+ (NSString *)uuidWithUrl:(NSString *)Url
{
    return [Url md5];
}
+ (NSString *)fullCommonDirPrefixWithUrl:(NSString *)url
{
    return [[self commonDirPrefix] stringByAppendingPathComponent:[self uuidWithUrl:url]];
}
+ (NSString *)tsFileWithIdentify:(NSString *)identify;
{
    return [NSString stringWithFormat:@"%@.ts",identify];
}
@end
