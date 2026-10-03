//
//  CdnTarIndex.h
//  CdnImporter
//
//  TAR 索引：只顺序读 512 字节头（数据区靠 seek 跳过），不解压、不落盘。
//  用于参考 APK 那套「分卷 tar」交付形态（cn-cdn.tar.part.NN），以及自建的单文件 tar 包。
//

#import <Foundation/Foundation.h>
#import "CdnArchiveSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface CdnTarMember : NSObject

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) uint64_t size;
@property (nonatomic, readonly) uint64_t dataOffset;
@property (nonatomic, readonly) char typeFlag;
@property (nonatomic, readonly) BOOL isRegularFile;

@end

@interface CdnTarIndex : NSObject

+ (nullable instancetype)indexWithSource:(id<CdnArchiveSource>)source error:(NSError **)error;

@property (nonatomic, readonly, copy) NSArray<CdnTarMember *> *members;
/// 索引过程中的观察（pax 头、长名、异常头部等），用于日志。
@property (nonatomic, readonly, copy) NSArray<NSString *> *notes;

- (nullable CdnTarMember *)memberNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
