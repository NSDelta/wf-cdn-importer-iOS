//
//  CdnImportPlan.m
//

#import "CdnImportPlan.h"

@implementation CdnImportPlanItem

- (instancetype)initWithEntry:(const CdnImportPlanEntry *)entry order:(NSUInteger)order {
    self = [super init];
    if (self != nil) {
        _order = order;
        _relativePath = @(entry->relative_path != NULL ? entry->relative_path : "");
        _basename = @(entry->basename != NULL ? entry->basename : "");
        _layer = @(entry->layer != NULL ? entry->layer : "");
        _kind = @(entry->kind != NULL ? entry->kind : "");
        _version = @(entry->version != NULL ? entry->version : "");
        _originalVersion = @(entry->original_version != NULL ? entry->original_version : "");
        _sha256Base64 = @(entry->sha256_base64 != NULL ? entry->sha256_base64 : "");
        _size = entry->size;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"#%lu %@ (%@/%@ %@ %llu 字节)",
            (unsigned long)_order, _relativePath, _layer, _kind, _version, _size];
}

@end

@implementation CdnImportPlan

+ (instancetype)sharedPlan {
    static CdnImportPlan *plan = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plan = [[CdnImportPlan alloc] init];
    });
    return plan;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;

    NSMutableArray<CdnImportPlanItem *> *items = [NSMutableArray arrayWithCapacity:CDN_IMPORT_PLAN_COUNT];
    NSMutableDictionary<NSString *, CdnImportPlanItem *> *byBasename = [NSMutableDictionary dictionaryWithCapacity:CDN_IMPORT_PLAN_COUNT];
    NSMutableDictionary<NSString *, NSMutableArray<CdnImportPlanItem *> *> *bySize = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *layerCounts = [NSMutableDictionary dictionary];
    uint64_t totalCompressed = 0;

    for (NSUInteger index = 0; index < CDN_IMPORT_PLAN_COUNT; index++) {
        CdnImportPlanItem *item = [[CdnImportPlanItem alloc] initWithEntry:&gCdnImportPlan[index] order:index];
        [items addObject:item];
        if (item.basename.length > 0) byBasename[item.basename] = item;
        NSString *sizeKey = [NSString stringWithFormat:@"%llu", item.size];
        NSMutableArray<CdnImportPlanItem *> *bucket = bySize[sizeKey];
        if (bucket == nil) {
            bucket = [NSMutableArray array];
            bySize[sizeKey] = bucket;
        }
        [bucket addObject:item];
        layerCounts[item.layer] = @([layerCounts[item.layer] unsignedIntegerValue] + 1);
        totalCompressed += item.size;
    }

    _items = [items copy];
    _itemsByBasename = [byBasename copy];
    _itemsBySize = [bySize copy];
    _layerCounts = [layerCounts copy];
    _totalCompressedBytes = totalCompressed;
    _targetVersion = @(CDN_IMPORT_PLAN_TARGET_VERSION);
    _baselineVersion = @(CDN_IMPORT_PLAN_BASELINE_VERSION);
    _expectedTotalBytes = CDN_IMPORT_PLAN_TOTAL_BYTES;
    _expectedTotalFiles = CDN_IMPORT_PLAN_TOTAL_FILES;
    return self;
}

@end
