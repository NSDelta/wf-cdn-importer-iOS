//
//  CdnTarIndex.m
//

#import "CdnTarIndex.h"

#import <string.h>

static const NSUInteger kTarBlock = 512;
static const uint64_t kTarMaxReasonableSize = 1ULL << 42;   // 4TB 护栏
static const NSUInteger kTarMaxMembers = 200000;

@implementation CdnTarMember

- (instancetype)initWithName:(NSString *)name size:(uint64_t)size dataOffset:(uint64_t)dataOffset typeFlag:(char)typeFlag {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
        _size = size;
        _dataOffset = dataOffset;
        _typeFlag = typeFlag;
        _isRegularFile = (typeFlag == '0' || typeFlag == '\0');
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<CdnTarMember %@ %llu 字节 @%llu %c>", _name, _size, _dataOffset, _typeFlag];
}

@end

/// 八进制数字段；base-256（首字节 0x80）走大端二进制（GNU 大文件扩展）。
static uint64_t TarNumericField(const uint8_t *bytes, NSUInteger length) {
    if (length == 0) return 0;
    if ((bytes[0] & 0x80) != 0) {
        uint64_t value = (uint64_t)(bytes[0] & 0x7f);
        for (NSUInteger index = 1; index < length; index++) {
            value = (value << 8) | (uint64_t)bytes[index];
        }
        return value;
    }
    uint64_t value = 0;
    NSUInteger index = 0;
    while (index < length && (bytes[index] == ' ' || bytes[index] == '\0')) index++;
    for (; index < length; index++) {
        uint8_t byte = bytes[index];
        if (byte < '0' || byte > '7') break;
        value = (value << 3) | (uint64_t)(byte - '0');
    }
    return value;
}

static NSString *TarStringField(const uint8_t *bytes, NSUInteger length) {
    NSUInteger count = 0;
    while (count < length && bytes[count] != '\0') count++;
    if (count == 0) return @"";
    NSData *data = [NSData dataWithBytes:bytes length:count];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text != nil ? text : @"";
}

/// pax 扩展头（typeflag 'x'）负载里取 path= 的值；找不到返回 nil。
static NSString * _Nullable TarPaxPathFromPayload(NSData *payload) {
    if (payload.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (text == nil) return nil;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange space = [line rangeOfString:@" "];
        if (space.location == NSNotFound) continue;
        NSString *keyValue = [line substringFromIndex:space.location + 1];
        if ([keyValue hasPrefix:@"path="]) {
            return [keyValue substringFromIndex:5];
        }
    }
    return nil;
}

@implementation CdnTarIndex

+ (nullable instancetype)indexWithSource:(id<CdnArchiveSource>)source error:(NSError **)error {
    if (source == nil) {
        if (error != NULL) *error = CdnError(CdnImporterErrorIO, @"空数据源");
        return nil;
    }
    NSMutableArray<CdnTarMember *> *members = [NSMutableArray array];
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    NSString *pendingLongName = nil;
    NSString *pendingPaxPath = nil;

    uint64_t offset = 0;
    uint64_t total = source.length;
    NSUInteger iterations = 0;
    while (offset + kTarBlock <= total && iterations < kTarMaxMembers) {
        iterations++;
        NSData *header = CdnReadData(source, offset, kTarBlock, error);
        if (header == nil) return nil;
        const uint8_t *bytes = header.bytes;

        BOOL allZero = YES;
        for (NSUInteger index = 0; index < kTarBlock; index++) {
            if (bytes[index] != 0) {
                allZero = NO;
                break;
            }
        }
        if (allZero) break;   // tar 以零块结尾（允许只有一块）

        uint64_t size = TarNumericField(bytes + 124, 12);
        char typeFlag = (char)bytes[156];
        NSString *name = TarStringField(bytes, 100);
        NSString *prefix = TarStringField(bytes + 345, 155);
        if (prefix.length > 0) name = [NSString stringWithFormat:@"%@/%@", prefix, name];

        uint64_t dataOffset = offset + kTarBlock;
        uint64_t nextOffset = dataOffset + ((size + kTarBlock - 1) / kTarBlock) * kTarBlock;

        if (size > kTarMaxReasonableSize || nextOffset <= offset) {
            if (error != NULL) {
                *error = CdnError(CdnImporterErrorFormat, @"tar 头异常（off=%llu size=%llu type=%c）", offset, size, typeFlag);
            }
            return nil;
        }

        if (typeFlag == 'L') {
            // GNU 长名：负载即下一个条目的名字
            NSData *payload = CdnReadData(source, dataOffset, (NSUInteger)MIN(size, (uint64_t)4096), error);
            if (payload == nil) return nil;
            pendingLongName = TarStringField(payload.bytes, payload.length);
            [notes addObject:[NSString stringWithFormat:@"GNU 长名头 @%llu: %@", offset, pendingLongName]];
        } else if (typeFlag == 'x' || typeFlag == 'g') {
            NSData *payload = CdnReadData(source, dataOffset, (NSUInteger)MIN(size, (uint64_t)65536), error);
            if (payload == nil) return nil;
            NSString *path = TarPaxPathFromPayload(payload);
            if (path.length > 0 && typeFlag == 'x') {
                pendingPaxPath = path;
                [notes addObject:[NSString stringWithFormat:@"pax 头 @%llu: path=%@", offset, path]];
            }
        } else {
            if (pendingLongName.length > 0) name = pendingLongName;
            if (pendingPaxPath.length > 0) name = pendingPaxPath;
            pendingLongName = nil;
            pendingPaxPath = nil;
            if (name.length > 0) {
                CdnTarMember *member = [[CdnTarMember alloc] initWithName:name
                                                                     size:size
                                                               dataOffset:dataOffset
                                                                 typeFlag:typeFlag];
                [members addObject:member];
            }
        }

        offset = nextOffset;
    }

    if (iterations >= kTarMaxMembers) {
        [notes addObject:[NSString stringWithFormat:@"tar 成员数达到上限 %lu，后续未索引", (unsigned long)kTarMaxMembers]];
    }

    CdnTarIndex *index = [[CdnTarIndex alloc] init];
    index->_members = [members copy];
    index->_notes = [notes copy];
    return index;
}

- (nullable CdnTarMember *)memberNamed:(NSString *)name {
    for (CdnTarMember *member in _members) {
        if ([member.name isEqualToString:name]) return member;
    }
    return nil;
}

@end
