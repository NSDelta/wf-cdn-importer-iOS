// 由 ios/importer/tools/verify-plan.mjs --emit 生成，请勿手改。
// 计划来源：/asset/get_path 快照（iOS 视图）+ 客户端 diff 链推导。
#ifndef CDN_IMPORT_PLAN_GENERATED_H
#define CDN_IMPORT_PLAN_GENERATED_H

#include <stdint.h>

typedef struct {
    const char *relative_path;
    const char *basename;
    const char *layer;
    const char *kind;
    const char *version;
    const char *original_version;
    uint64_t size;
    const char *sha256_base64;
} CdnImportPlanEntry;

#define CDN_IMPORT_PLAN_TARGET_VERSION "1.4.54"
#define CDN_IMPORT_PLAN_BASELINE_VERSION "1.4.0"
#define CDN_IMPORT_PLAN_COUNT 634U

// 完整导入后的终态规模（实体表 size 列之和 / 行数），用于 info.json.totalSize 与自检。
#define CDN_IMPORT_PLAN_TOTAL_BYTES 10191161030ULL
#define CDN_IMPORT_PLAN_TOTAL_FILES 137820U

extern const CdnImportPlanEntry gCdnImportPlan[CDN_IMPORT_PLAN_COUNT];

#endif
