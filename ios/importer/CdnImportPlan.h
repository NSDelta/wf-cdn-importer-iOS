//
//  CdnImportPlan.h
//  CdnImporter
//
//  导入计划（634 个归档）的内存视图：直接包住 CdnImportPlan.generated.{h,m} 里的 C 表。
//  计划本身的生成与验证在 Node 侧（ios/importer/tools/verify-plan.mjs）。
//

#import <Foundation/Foundation.h>
#import "CdnImportPlan.generated.h"

NS_ASSUME_NONNULL_BEGIN

@interface CdnImportPlanItem : NSObject

@property (nonatomic, readonly) NSUInteger order;          ///< 0 起；解压顺序即此序（后覆盖先）
@property (nonatomic, readonly, copy) NSString *relativePath;
@property (nonatomic, readonly, copy) NSString *basename;
@property (nonatomic, readonly, copy) NSString *layer;      ///< common / medium / ios
@property (nonatomic, readonly, copy) NSString *kind;       ///< full / diff
@property (nonatomic, readonly) uint64_t size;              ///< 归档 zip 的字节数
@property (nonatomic, readonly, copy) NSString *version;
@property (nonatomic, readonly, copy) NSString *originalVersion;   ///< full 归档为空串
@property (nonatomic, readonly, copy) NSString *sha256Base64;      ///< 与 /asset/get_path 同口径

@end

@interface CdnImportPlan : NSObject

+ (instancetype)sharedPlan;

@property (nonatomic, readonly, copy) NSArray<CdnImportPlanItem *> *items;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, CdnImportPlanItem *> *itemsByBasename;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSArray<CdnImportPlanItem *> *> *itemsBySize;

@property (nonatomic, readonly, copy) NSString *targetVersion;      ///< 1.4.54
@property (nonatomic, readonly, copy) NSString *baselineVersion;    ///< 1.4.0
@property (nonatomic, readonly) uint64_t totalCompressedBytes;
@property (nonatomic, readonly) uint64_t expectedTotalBytes;        ///< 完整导入后的终态字节数
@property (nonatomic, readonly) uint64_t expectedTotalFiles;        ///< 完整导入后的终态文件数
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSNumber *> *layerCounts;

@end

NS_ASSUME_NONNULL_END
