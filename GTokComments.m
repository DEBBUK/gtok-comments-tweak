// GTokComments - companion tweak for GTok (TikTok 45.8.0, com.zhiliaoapp.musically)
// Goal: when a video is saved for offline viewing, also fetch ~100 comments of that
// video and the author's profile avatar, storing them next to the video inside the
// app sandbox (Documents/GTokComments/<aweme_id>/).
//
// Pure Objective-C + objc runtime swizzling. No Theos / no Substrate dependency.
// Build: clang -arch arm64 ... -dynamiclib  (see .github/workflows/build.yml)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

#pragma mark - Logging

static NSString *GTokDocumentsDir(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

static NSString *GTokCommentsRoot(void) {
    NSString *root = [GTokDocumentsDir() stringByAppendingPathComponent:@"GTokComments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static void GTokLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[GTokComments] %@", msg);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSString *logPath = [GTokCommentsRoot() stringByAppendingPathComponent:@"gtokcomments.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - Swizzle helpers

static void GTokSwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        GTokLog(@"swizzle: %@ has no -%@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    GTokLog(@"swizzled -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static Class GTokCls(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) GTokLog(@"class not found: %@", name);
    return c;
}

#pragma mark - Safe KVC / property helpers

static id GTokGet(id obj, NSString *key) {
    @try {
        if ([obj respondsToSelector:NSSelectorFromString(key)]) {
            return [obj valueForKey:key];
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *GTokStr(id obj) {
    if (!obj || obj == [NSNull null]) return nil;
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if ([obj respondsToSelector:@selector(stringValue)]) return [obj stringValue];
    return [obj description];
}

static NSNumber *GTokNum(id obj) {
    if ([obj isKindOfClass:[NSNumber class]]) return obj;
    if ([obj isKindOfClass:[NSString class]]) return @([obj longLongValue]);
    return nil;
}

#pragma mark - User / avatar extraction

// A "user" model (AWEAwemeAuthor / TTKUserModel ...) exposes avatarLarger / avatarMedium /
// avatarThumb / avatar168 / avatar300 (see dumped strings). Grab the best URL available.
static NSString *GTokAvatarURLFromUser(id user) {
    if (!user) return nil;
    NSArray *keys = @[@"avatarLarger", @"avatar300", @"avatar168", @"avatarMedium", @"avatarThumb", @"avatarSmall", @"avatarURL", @"avatarUrl"];
    for (NSString *k in keys) {
        id v = GTokGet(user, k);
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
        if ([v isKindOfClass:[NSDictionary class]]) {
            id url = v[@"url_list"] ? [v[@"url_list"] firstObject] : (v[@"urlList"] ? [v[@"urlList"] firstObject] : nil);
            if ([url isKindOfClass:[NSString class]] && [url length]) return url;
            for (NSString *kk in @[@"url", @"uri"]) {
                if ([v[kk] isKindOfClass:[NSString class]] && [v[kk] length]) return v[kk];
            }
        }
    }
    return nil;
}

static NSDictionary *GTokSerializeUser(id user) {
    if (!user) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"uid", @"userID", @"userId", @"secUid", @"secUID", @"nickname", @"nickName", @"uniqueId", @"unique_id", @"signature"]) {
        id v = GTokStr(GTokGet(user, k));
        if (v) d[k] = v;
    }
    NSString *av = GTokAvatarURLFromUser(user);
    if (av) d[@"avatarURL"] = av;
    return d;
}

#pragma mark - Comment serialization

static NSDictionary *GTokSerializeComment(id c) {
    if (!c) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"commentID", @"cid", @"content", @"awemeID", @"createTime", @"diggCount", @"buryCount", @"replyCount", @"subCommentCount", @"replyID", @"replyUserId", @"replySubCommentID", @"userDigged", @"userBuried", @"status", @"commentLanguage"]) {
        id v = GTokGet(c, k);
        if (v && ![v isKindOfClass:[NSNull class]]) d[k] = v;
    }
    id author = GTokGet(c, @"author");
    NSDictionary *a = GTokSerializeUser(author);
    if (a) d[@"author"] = a;
    id replies = GTokGet(c, @"replyComments");
    if ([replies isKindOfClass:[NSArray class]] && [replies count]) {
        NSMutableArray *sub = [NSMutableArray array];
        for (id r in replies) { NSDictionary *rd = GTokSerializeComment(r); if (rd) [sub addObject:rd]; }
        d[@"replyComments"] = sub;
    }
    if (!d[@"content"] && !d[@"commentID"]) return nil;
    return d;
}

#pragma mark - Global state

static NSMutableDictionary<NSString *, NSMutableArray *> *gCommentsByAweme;
static NSMutableDictionary<NSString *, NSDictionary *> *gAuthorByAweme;

static void GTokStoreComments(NSString *awemeID, NSArray *comments, id awemeOrAuthor) {
    if (![awemeID isKindOfClass:[NSString class]] || ![awemeID length]) return;
    if (!gCommentsByAweme) gCommentsByAweme = [NSMutableDictionary dictionary];
    if (!gAuthorByAweme) gAuthorByAweme = [NSMutableDictionary dictionary];
    NSMutableArray *out = [NSMutableArray array];
    for (id c in comments) { NSDictionary *d = GTokSerializeComment(c); if (d) [out addObject:d]; }
    if ([out count]) gCommentsByAweme[awemeID] = out;
    id author = awemeOrAuthor ? GTokGet(awemeOrAuthor, @"author") : nil;
    if (!author) author = awemeOrAuthor;
    NSDictionary *a = GTokSerializeUser(author);
    if (a) gAuthorByAweme[awemeID] = a;
    GTokLog(@"stored %lu comments for aweme %@", (unsigned long)[out count], awemeID);
}

#pragma mark - Disk persistence

static void GTokDownloadURL(NSString *urlStr, NSString *destPath) {
    if (![urlStr length]) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && [data length]) {
            [data writeToFile:destPath atomically:YES];
            GTokLog(@"avatar saved: %@ (%lu bytes)", destPath, (unsigned long)[data length]);
        } else {
            GTokLog(@"avatar download failed: %@ err=%@", urlStr, err);
        }
    }];
    [t resume];
}

static void GTokFlushToDisk(NSString *awemeID) {
    if (![awemeID length]) return;
    NSString *dir = [GTokCommentsRoot() stringByAppendingPathComponent:awemeID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableDictionary *bundle = [NSMutableDictionary dictionary];
    bundle[@"awemeID"] = awemeID;
    bundle[@"savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    if (gAuthorByAweme[awemeID]) bundle[@"author"] = gAuthorByAweme[awemeID];
    if (gCommentsByAweme[awemeID]) bundle[@"comments"] = gCommentsByAweme[awemeID];
    bundle[@"commentCount"] = @([gCommentsByAweme[awemeID] count]);

    NSData *json = [NSJSONSerialization dataWithJSONObject:bundle options:NSJSONWritingPrettyPrinted error:nil];
    NSString *jsonPath = [dir stringByAppendingPathComponent:@"comments.json"];
    if (json) [json writeToFile:jsonPath atomically:YES];

    NSString *av = gAuthorByAweme[awemeID][@"avatarURL"];
    if ([av length]) {
        GTokDownloadURL(av, [dir stringByAppendingPathComponent:@"avatar.jpg"]);
    }
    GTokLog(@"flushed aweme %@ -> %@ (%lu comments)", awemeID, jsonPath, (unsigned long)[gCommentsByAweme[awemeID] count]);
}

#pragma mark - Comment forcing / loading

static NSString *GTokAwemeID(id m) {
    if (!m) return nil;
    for (NSString *k in @[@"awemeID", @"awemeId", @"aid", @"itemID", @"itemId", @"groupId"]) {
        NSString *s = GTokStr(GTokGet(m, k));
        if ([s length]) return s;
    }
    return nil;
}

// Try to actively load ~100 comments for the given aweme model.
static void GTokFetchComments(id awemeModel) {
    if (!awemeModel) return;
    NSString *aid = GTokAwemeID(awemeModel);
    GTokLog(@"GTokFetchComments aweme=%@", aid);

    Class dcCls = GTokCls(@"TTKCommentListDataController");
    if (!dcCls) return;

    id controller = nil;
    @try {
        controller = [[dcCls alloc] initWithAwemeModel:awemeModel];
    } @catch (NSException *e) {
        GTokLog(@"initWithAwemeModel failed: %@", e);
        return;
    }
    if (!controller) return;

    // Prefer the explicit request-config API so we can force count == 100.
    SEL cfgSel = NSSelectorFromString(@"createRefreshRequestModelWithBlock:");
    id reqModel = nil;
    if ([controller respondsToSelector:cfgSel]) {
        @try {
            id (^block)(id) = ^id(id model) {
                GTokLog(@"request model: %@", model);
                @try {
                    [model setValue:@100 forKey:@"count"];
                    [model setValue:@0 forKey:@"offset"];
                    [model setValue:aid ?: @"" forKey:@"itemID"];
                } @catch (__unused NSException *e) {}
                return model;
            };
            reqModel = ((id (*)(id, SEL, id))objc_msgSend)(controller, cfgSel, block);
        } @catch (NSException *e) {
            GTokLog(@"createRefreshRequestModelWithBlock failed: %@", e);
        }
    }

    void (^completion)(id, id) = ^(id changeArray, id error) {
        GTokLog(@"comment completion changeArray=%@ error=%@", changeArray, error);
        id list = GTokGet(controller, @"dataList");
        if ([list isKindOfClass:[NSArray class]] && [list count]) {
            GTokStoreComments(aid, list, awemeModel);
            GTokFlushToDisk(aid);
        }
    };

    BOOL called = NO;
    SEL sel4 = NSSelectorFromString(@"refreshCommentsWithInsertIDs:scene:requestConfig:completion:");
    if (reqModel && [controller respondsToSelector:sel4]) {
        @try {
            ((void (*)(id, SEL, id, long long, id, id))objc_msgSend)(controller, sel4, @[], (long long)0, reqModel, completion);
            called = YES;
        } @catch (NSException *e) { GTokLog(@"refresh(4) failed: %@", e); }
    }
    if (!called) {
        SEL sel3 = NSSelectorFromString(@"refreshCommentsWithInsertIDs:scene:completion:");
        if ([controller respondsToSelector:sel3]) {
            @try {
                ((void (*)(id, SEL, id, long long, id))objc_msgSend)(controller, sel3, @[], (long long)0, completion);
                called = YES;
            } @catch (NSException *e) { GTokLog(@"refresh(3) failed: %@", e); }
        }
    }
    GTokLog(@"GTokFetchComments called=%d", called);
}

#pragma mark - Hooks: comment data capture

static void (*orig_setDataList)(id, SEL, id);
static void GTok_setDataList(id self, SEL _cmd, id list) {
    @try {
        if ([list isKindOfClass:[NSArray class]] && [list count]) {
            id aweme = GTokGet(self, @"awemeModel");
            NSString *aid = GTokAwemeID(aweme) ?: GTokStr(GTokGet(self, @"awemeId"));
            GTokStoreComments(aid, list, aweme);
            // If the list already reached 100+, persist immediately.
            if (aid && [list count] >= 90) GTokFlushToDisk(aid);
        }
    } @catch (__unused NSException *e) {}
    if (orig_setDataList) orig_setDataList(self, _cmd, list);
}

static void (*orig_onRefresh)(id, SEL, id, id, long long);
static void GTok_onRefresh(id self, SEL _cmd, id response, id error, long long scene) {
    @try {
        id arr = GTokGet(response, @"commentArray");
        if ([arr isKindOfClass:[NSArray class]] && [arr count]) {
            id aweme = GTokGet(self, @"awemeModel");
            NSString *aid = GTokAwemeID(aweme) ?: GTokStr(GTokGet(self, @"awemeId"));
            GTokStoreComments(aid, arr, aweme);
            BOOL hasMore = [[GTokGet(response, @"hasMore") description] boolValue];
            GTokLog(@"onRefresh scene=%lld got=%lu hasMore=%d", scene, (unsigned long)[arr count], hasMore);
            // keep paging while we have < 100 and server says hasMore
            if (aid && hasMore && [gCommentsByAweme[aid] count] < 100) {
                SEL loadMore = NSSelectorFromString(@"loadMoreCommentsWithInsertIDs:lastViewedID:scene:completion:");
                if ([self respondsToSelector:loadMore]) {
                    @try {
                        ((void (*)(id, SEL, id, id, long long, id))objc_msgSend)(self, loadMore, @[], nil, scene, ^(id a, id e){});
                    } @catch (__unused NSException *ex) {}
                }
            } else if (aid) {
                GTokFlushToDisk(aid);
            }
        }
    } @catch (__unused NSException *e) {}
    if (orig_onRefresh) orig_onRefresh(self, _cmd, response, error, scene);
}

#pragma mark - Hooks: download / offline triggers

static void GTokHandleDownloadAweme(id aweme) {
    NSString *aid = GTokAwemeID(aweme);
    GTokLog(@"download trigger aweme=%@", aid);
    if (!aweme) return;
    // capture author avatar straight from the aweme
    @try { GTokStoreComments(aid, nil, aweme); } @catch (__unused NSException *e) {}
    GTokFetchComments(aweme);
}

static void (*orig_downloadAweme)(id, SEL, id);
static void GTok_downloadAweme(id self, SEL _cmd, id aweme) {
    @try { GTokHandleDownloadAweme(aweme); } @catch (__unused NSException *e) {}
    if (orig_downloadAweme) orig_downloadAweme(self, _cmd, aweme);
}

static void (*orig_saveTaskVideoWithAweme)(id, SEL, id);
static void GTok_saveTaskVideoWithAweme(id self, SEL _cmd, id aweme) {
    @try { GTokHandleDownloadAweme(aweme); } @catch (__unused NSException *e) {}
    if (orig_saveTaskVideoWithAweme) orig_saveTaskVideoWithAweme(self, _cmd, aweme);
}

static void (*orig_startOffline)(id, SEL, id);
static void GTok_startOffline(id self, SEL _cmd, id awemeOrCtx) {
    @try {
        NSString *aid = GTokAwemeID(awemeOrCtx);
        GTokLog(@"offline download trigger arg=%@ aid=%@", awemeOrCtx, aid);
        if (awemeOrCtx) GTokHandleDownloadAweme(awemeOrCtx);
    } @catch (__unused NSException *e) {}
    if (orig_startOffline) orig_startOffline(self, _cmd, awemeOrCtx);
}

// Generic: whenever a download-status component reports a finished offline video,
// try to grab its aweme.
static void (*orig_offlineStatus)(id, SEL, id);
static void GTok_offlineStatus(id self, SEL _cmd, id models) {
    @try {
        GTokLog(@"offline status models=%@", models);
        if ([models isKindOfClass:[NSArray class]]) {
            for (id m in models) {
                id aweme = GTokGet(m, @"awemeModel") ?: m;
                GTokHandleDownloadAweme(aweme);
            }
        }
    } @catch (__unused NSException *e) {}
    if (orig_offlineStatus) orig_offlineStatus(self, _cmd, models);
}

#pragma mark - Hooks: request model count forcing

static void (*orig_setCount)(id, SEL, long long);
static void GTok_setCount(id self, SEL _cmd, long long count) {
    if (count > 0 && count < 100) count = 100; // ask for 100 comments
    if (orig_setCount) orig_setCount(self, _cmd, count);
}

#pragma mark - Install

static void GTokInstall(void) {
    GTokLog(@"==== GTokComments installing ====");

    Class dc = GTokCls(@"TTKCommentListDataController");
    if (dc) {
        GTokSwizzleInstance(dc, NSSelectorFromString(@"setDataList:"), (IMP)GTok_setDataList, (IMP *)&orig_setDataList);
        GTokSwizzleInstance(dc, NSSelectorFromString(@"onRefreshRequestCompletedWithResponse:error:scene:"), (IMP)GTok_onRefresh, (IMP *)&orig_onRefresh);
    }

    Class req = GTokCls(@"TTKCommentListRequestModel");
    if (req) {
        GTokSwizzleInstance(req, NSSelectorFromString(@"setCount:"), (IMP)GTok_setCount, (IMP *)&orig_setCount);
    }

    Class dl = GTokCls(@"AWEMediaDownloader");
    if (dl) {
        GTokSwizzleInstance(dl, NSSelectorFromString(@"downloadAweme:"), (IMP)GTok_downloadAweme, (IMP *)&orig_downloadAweme);
        GTokSwizzleInstance(dl, NSSelectorFromString(@"saveTaskVideoWithAweme:"), (IMP)GTok_saveTaskVideoWithAweme, (IMP *)&orig_saveTaskVideoWithAweme);
    }

    Class off = GTokCls(@"TTKFeedOfflineVideoComponent");
    if (off) {
        GTokSwizzleInstance(off, NSSelectorFromString(@"p_startOfflineDownloadIfNeed:"), (IMP)GTok_startOffline, (IMP *)&orig_startOffline);
    }

    GTokLog(@"==== GTokComments installed ====");
}

__attribute__((constructor))
static void GTokCommentsInit(void) {
    @autoreleasepool {
        GTokLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        // Let TikTok finish bootstrap before we touch its classes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTokInstall();
        });
    }
}
