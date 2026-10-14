// GTokComments - companion tweak for GTok (TikTok 45.8.0, com.zhiliaoapp.musically)
// When a video is saved for offline viewing, also fetch ~100 comments of that video
// plus the author's profile avatar into Documents/GTokComments/<aweme_id>/.
//
// Pure Objective-C + objc runtime swizzling (no Theos / no Substrate).
// Build: clang -arch arm64 -isysroot <iphoneos sdk> -dynamiclib  (see build.yml)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Paths / logging

static NSString *GTokCommentsRoot(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *root = [docs stringByAppendingPathComponent:@"GTokComments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    return root;
}

static void GTokLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
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

#pragma mark - Swizzle helpers (type-checked to avoid ABI crashes)

static Class GTokCls(NSString *name) { Class c = NSClassFromString(name); return c; }

// Return a single-character type for instance-arg `argIdx` (0-based, args only, self/_cmd excluded).
static char GTokArgType(Class cls, SEL sel, int argIdx) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return 0;
    const char *e = method_getTypeEncoding(m);
    if (!e) return 0;
    int i = 0;
    i++;                       // skip single-char return type
    int arg = -2;              // arg -2 = self, -1 = _cmd
    while (e[i]) {
        while (e[i] >= '0' && e[i] <= '9') i++;
        char t = e[i];
        if (!t) break;
        if (arg == argIdx) return t;
        i++; arg++;
        // skip obvious pointer types (won't happen for our targets)
        if (t == '{') { while (e[i] && e[i] != '}') i++; if (e[i]) i++; }
    }
    return 0;
}

// Swizzle an instance method whose arg `argIdx` must be an object ('@').
static void GTokSwizzleObject(Class cls, SEL sel, IMP imp, IMP *orig, int argIdx) {
    if (!cls) return;
    char t = GTokArgType(cls, sel, argIdx);
    if (t != '@') { GTokLog(@"skip -[%@ %@] (arg%d type '%c')", NSStringFromClass(cls), NSStringFromSelector(sel), argIdx, t ? t : '?'); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    GTokLog(@"swizzled -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

#pragma mark - Value helpers

static id GTokGet(id o, NSString *k) {
    @try { if (o && [o respondsToSelector:NSSelectorFromString(k)]) return [o valueForKey:k]; } @catch (__unused NSException *e) {}
    return nil;
}
static NSString *GTokStr(id o) {
    if (!o || o == (id)[NSNull null]) return nil;
    if ([o isKindOfClass:[NSString class]]) return o;
    if ([o respondsToSelector:@selector(stringValue)]) return [o stringValue];
    @try { return [o description]; } @catch (__unused NSException *e) { return nil; }
}
static NSString *GTokAwemeID(id m) {
    if (!m) return nil;
    for (NSString *k in @[@"awemeID", @"awemeId", @"aid", @"itemID", @"itemId", @"groupId"]) {
        NSString *s = GTokStr(GTokGet(m, k));
        if ([s length]) return s;
    }
    return nil;
}

#pragma mark - User / comment serialization

static NSString *GTokAvatarURLFromUser(id u) {
    if (!u) return nil;
    for (NSString *k in @[@"avatarLarger", @"avatar300", @"avatar168", @"avatarMedium", @"avatarThumb", @"avatarSmall", @"avatarURL", @"avatarUrl"]) {
        id v = GTokGet(u, k);
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        if ([v isKindOfClass:[NSDictionary class]]) {
            id list = v[@"url_list"] ?: v[@"urlList"];
            if ([list isKindOfClass:[NSArray class]] && [list count]) {
                id url = list[0];
                if ([url isKindOfClass:[NSString class]] && [url length]) return url;
            }
            for (NSString *kk in @[@"url", @"uri"]) if ([v[kk] isKindOfClass:[NSString class]] && [v[kk] length]) return v[kk];
        }
    }
    return nil;
}

static NSDictionary *GTokSerializeUser(id u) {
    if (!u) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"uid", @"userID", @"userId", @"secUid", @"secUID", @"nickname", @"nickName", @"uniqueId", @"unique_id", @"signature"]) {
        NSString *v = GTokStr(GTokGet(u, k));
        if (v) d[k] = v;
    }
    NSString *av = GTokAvatarURLFromUser(u);
    if (av) d[@"avatarURL"] = av;
    return d;
}

static NSDictionary *GTokSerializeComment(id c) {
    if (!c) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"commentID", @"cid", @"content", @"awemeID", @"createTime", @"diggCount", @"buryCount", @"replyCount", @"subCommentCount", @"replyID", @"replyUserId", @"replySubCommentID", @"userDigged", @"userBuried", @"status", @"commentLanguage"]) {
        id v = GTokGet(c, k);
        if (v && v != (id)[NSNull null]) d[k] = v;
    }
    NSDictionary *a = GTokSerializeUser(GTokGet(c, @"author"));
    if (a) d[@"author"] = a;
    id replies = GTokGet(c, @"replyComments");
    if ([replies isKindOfClass:[NSArray class]] && [replies count]) {
        NSMutableArray *sub = [NSMutableArray array];
        for (id r in replies) { NSDictionary *rd = GTokSerializeComment(r); if (rd) [sub addObject:rd]; }
        d[@"replyComments"] = sub;
    }
    if (!d[@"commentID"] && !d[@"content"]) return nil;
    return d;
}

#pragma mark - State

static NSMutableDictionary<NSString *, NSMutableArray *> *gComments;
static NSMutableDictionary<NSString *, NSDictionary *> *gAuthors;

static void GTokStore(NSString *aid, NSArray *comments, id awemeOrAuthor) {
    if (![aid isKindOfClass:[NSString class]] || ![aid length]) return;
    if (!gComments) gComments = [NSMutableDictionary dictionary];
    if (!gAuthors)  gAuthors  = [NSMutableDictionary dictionary];
    if ([comments isKindOfClass:[NSArray class]] && [comments count]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id c in comments) { NSDictionary *d = GTokSerializeComment(c); if (d) [out addObject:d]; }
        if ([out count]) {
            NSMutableArray *merged = gComments[aid] ?: [NSMutableArray array];
            for (NSDictionary *d in out) if (![merged containsObject:d]) [merged addObject:d];
            gComments[aid] = merged;
            GTokLog(@"captured %lu comments (total %lu) aweme=%@", (unsigned long)[out count], (unsigned long)[merged count], aid);
        }
    }
    id author = GTokGet(awemeOrAuthor, @"author") ?: awemeOrAuthor;
    NSDictionary *a = GTokSerializeUser(author);
    if (a && a[@"uid"]) gAuthors[aid] = a;
}

#pragma mark - Disk

static void GTokDownload(NSString *urlStr, NSString *dest) {
    if (![urlStr length]) return;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data.length) { [data writeToFile:dest atomically:YES]; GTokLog(@"avatar saved %@ (%lu b)", dest, (unsigned long)data.length); }
        else GTokLog(@"avatar download failed %@ (%@)", urlStr, err.localizedDescription);
    }] resume];
}

static void GTokFlush(NSString *aid) {
    if (![aid length]) return;
    NSString *dir = [GTokCommentsRoot() stringByAppendingPathComponent:aid];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *b = [NSMutableDictionary dictionary];
    b[@"awemeID"] = aid;
    b[@"savedAt"] = @([[NSDate date] timeIntervalSince1970]);
    if (gAuthors[aid])  b[@"author"] = gAuthors[aid];
    if (gComments[aid]) b[@"comments"] = gComments[aid];
    b[@"commentCount"] = @([gComments[aid] count]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:b options:NSJSONWritingPrettyPrinted error:nil];
    NSString *jp = [dir stringByAppendingPathComponent:@"comments.json"];
    if (json) [json writeToFile:jp atomically:YES];
    NSString *av = gAuthors[aid][@"avatarURL"];
    if ([av length]) GTokDownload(av, [dir stringByAppendingPathComponent:@"avatar.jpg"]);
    GTokLog(@"flushed aweme %@ -> %@ (%lu comments)", aid, jp, (unsigned long)[gComments[aid] count]);
}

#pragma mark - Active comment fetch

static void GTokFetchComments(id awemeModel) {
    if (!awemeModel) return;
    NSString *aid = GTokAwemeID(awemeModel);
    GTokLog(@"fetchComments aweme=%@", aid);
    Class dcCls = GTokCls(@"TTKCommentListDataController");
    if (!dcCls) return;

    id dc = nil;
    @try { dc = ((id (*)(id, SEL, id))objc_msgSend)([dcCls alloc], NSSelectorFromString(@"initWithAwemeModel:"), awemeModel); }
    @catch (NSException *e) { GTokLog(@"initWithAwemeModel failed: %@", e.reason); return; }
    if (!dc) return;

    id reqModel = nil;
    SEL cfg = NSSelectorFromString(@"createRefreshRequestModelWithBlock:");
    if ([dc respondsToSelector:cfg]) {
        @try {
            reqModel = ((id (*)(id, SEL, id))objc_msgSend)(dc, cfg, ^id(id model) {
                @try { [model setValue:@100 forKey:@"count"]; [model setValue:@0 forKey:@"offset"]; if (aid) [model setValue:aid forKey:@"itemID"]; } @catch (__unused NSException *e) {}
                return model;
            });
        } @catch (NSException *e) { GTokLog(@"createRefreshRequestModel failed: %@", e.reason); }
    }

    id completion = ^(id changeArray, id error) {
        id list = GTokGet(dc, @"dataList");
        if ([list isKindOfClass:[NSArray class]] && [list count]) { GTokStore(aid, list, awemeModel); GTokFlush(aid); }
        else GTokLog(@"fetchComments completion empty (change=%@ err=%@)", changeArray, error);
    };

    SEL s4 = NSSelectorFromString(@"refreshCommentsWithInsertIDs:scene:requestConfig:completion:");
    SEL s3 = NSSelectorFromString(@"refreshCommentsWithInsertIDs:scene:completion:");
    @try {
        if (reqModel && [dc respondsToSelector:s4]) {
            ((void (*)(id, SEL, id, long long, id, id))objc_msgSend)(dc, s4, @[], (long long)0, reqModel, completion);
        } else if ([dc respondsToSelector:s3]) {
            ((void (*)(id, SEL, id, long long, id))objc_msgSend)(dc, s3, @[], (long long)0, completion);
        } else {
            GTokLog(@"no usable refresh selector");
        }
    } @catch (NSException *e) { GTokLog(@"refresh call failed: %@", e.reason); }
}

#pragma mark - Hooks

static void (*o_setDataList)(id, SEL, id);
static void h_setDataList(id self, SEL _cmd, id list) {
    @try {
        if ([list isKindOfClass:[NSArray class]] && [list count]) {
            id aweme = GTokGet(self, @"awemeModel");
            NSString *aid = GTokAwemeID(aweme) ?: GTokStr(GTokGet(self, @"awemeId"));
            GTokStore(aid, list, aweme);
            if (aid && [gComments[aid] count] >= 90) GTokFlush(aid);
        }
    } @catch (__unused NSException *e) {}
    if (o_setDataList) o_setDataList(self, _cmd, list);
}

static void (*o_onRefreshLL)(id, SEL, id, id, long long);
static void h_onRefreshLL(id self, SEL _cmd, id resp, id err, long long scene) {
    @try {
        id arr = GTokGet(resp, @"commentArray");
        if ([arr isKindOfClass:[NSArray class]] && [arr count]) {
            id aweme = GTokGet(self, @"awemeModel");
            NSString *aid = GTokAwemeID(aweme) ?: GTokStr(GTokGet(self, @"awemeId"));
            GTokStore(aid, arr, aweme);
            BOOL more = [[GTokStr(GTokGet(resp, @"hasMore")) description] boolValue];
            GTokLog(@"onRefresh scene=%lld got=%lu more=%d", scene, (unsigned long)[arr count], more);
            if (aid && more && [gComments[aid] count] < 100) {
                SEL lm = NSSelectorFromString(@"loadMoreCommentsWithInsertIDs:lastViewedID:scene:completion:");
                if ([self respondsToSelector:lm])
                    @try { ((void (*)(id, SEL, id, id, long long, id))objc_msgSend)(self, lm, @[], nil, scene, ^(id a, id e){}); } @catch (__unused NSException *e) {}
            } else if (aid) GTokFlush(aid);
        }
    } @catch (__unused NSException *e) {}
    if (o_onRefreshLL) o_onRefreshLL(self, _cmd, resp, err, scene);
}

static void (*o_onRefreshI)(id, SEL, id, id, int);
static void h_onRefreshI(id self, SEL _cmd, id resp, id err, int scene) {
    h_onRefreshLL(self, _cmd, resp, err, (long long)scene);
    if (o_onRefreshI) o_onRefreshI(self, _cmd, resp, err, scene);
}

static void (*o_setCountLL)(id, SEL, long long);
static void h_setCountLL(id self, SEL _cmd, long long count) {
    if (count > 0 && count < 100) count = 100;
    if (o_setCountLL) o_setCountLL(self, _cmd, count);
}
static void (*o_setCountI)(id, SEL, int);
static void h_setCountI(id self, SEL _cmd, int count) {
    if (count > 0 && count < 100) count = 100;
    if (o_setCountI) o_setCountI(self, _cmd, count);
}

static void GTokTrigger(id aweme) {
    NSString *aid = GTokAwemeID(aweme);
    GTokLog(@"download trigger aweme=%@", aid);
    if (!aid) return;
    GTokStore(aid, nil, aweme);
    GTokFetchComments(aweme);
}

static void (*o_dl1)(id, SEL, id);
static void h_dl1(id self, SEL _cmd, id aweme) { @try { GTokTrigger(aweme); } @catch (__unused NSException *e) {} if (o_dl1) o_dl1(self, _cmd, aweme); }
static void (*o_dl2)(id, SEL, id);
static void h_dl2(id self, SEL _cmd, id aweme) { @try { GTokTrigger(aweme); } @catch (__unused NSException *e) {} if (o_dl2) o_dl2(self, _cmd, aweme); }
static void (*o_off)(id, SEL, id);
static void h_off(id self, SEL _cmd, id arg) {
    @try {
        GTokLog(@"offline trigger arg=%@", arg);
        if (arg) {
            id aweme = GTokGet(arg, @"awemeModel") ?: arg;
            if ([aweme isKindOfClass:[NSArray class]]) { for (id x in aweme) GTokTrigger(GTokGet(x, @"awemeModel") ?: x); }
            else GTokTrigger(aweme);
        }
    } @catch (__unused NSException *e) {}
    if (o_off) o_off(self, _cmd, arg);
}

#pragma mark - Install

static void GTokInstall(void) {
    GTokLog(@"==== install start ====");

    Class dc = GTokCls(@"TTKCommentListDataController");
    if (dc) {
        GTokSwizzleObject(dc, NSSelectorFromString(@"setDataList:"), (IMP)h_setDataList, (IMP *)&o_setDataList, 0);
        SEL r = NSSelectorFromString(@"onRefreshRequestCompletedWithResponse:error:scene:");
        char t = GTokArgType(dc, r, 2);
        if (t == 'q' || t == 'Q' || t == 'l' || t == 'L') GTokSwizzleObject(dc, r, (IMP)h_onRefreshLL, (IMP *)&o_onRefreshLL, 0), GTokLog(@"onRefresh -> long long");
        else if (t == 'i' || t == 'I') GTokSwizzleObject(dc, r, (IMP)h_onRefreshI, (IMP *)&o_onRefreshI, 0), GTokLog(@"onRefresh -> int");
        else GTokLog(@"onRefresh not swizzled (scene type '%c')", t ? t : '?');
    } else GTokLog(@"TTKCommentListDataController missing");

    Class req = GTokCls(@"TTKCommentListRequestModel");
    if (req) {
        SEL sc = NSSelectorFromString(@"setCount:");
        char t = GTokArgType(req, sc, 0);
        if (t == 'q' || t == 'Q' || t == 'l' || t == 'L') GTokSwizzleObject(req, sc, (IMP)h_setCountLL, (IMP *)&o_setCountLL, 0);
        else if (t == 'i' || t == 'I') GTokSwizzleObject(req, sc, (IMP)h_setCountI, (IMP *)&o_setCountI, 0);
        else GTokLog(@"setCount not swizzled (type '%c')", t ? t : '?');
    } else GTokLog(@"TTKCommentListRequestModel missing");

    Class dl = GTokCls(@"AWEMediaDownloader");
    if (dl) {
        GTokSwizzleObject(dl, NSSelectorFromString(@"downloadAweme:"), (IMP)h_dl1, (IMP *)&o_dl1, 0);
        GTokSwizzleObject(dl, NSSelectorFromString(@"saveTaskVideoWithAweme:"), (IMP)h_dl2, (IMP *)&o_dl2, 0);
    } else GTokLog(@"AWEMediaDownloader missing");

    Class off = GTokCls(@"TTKFeedOfflineVideoComponent");
    if (off) GTokSwizzleObject(off, NSSelectorFromString(@"p_startOfflineDownloadIfNeed:"), (IMP)h_off, (IMP *)&o_off, 0);
    else GTokLog(@"TTKFeedOfflineVideoComponent missing");

    GTokLog(@"==== install done ====");
    GTokLog(@"GTokComments ready. Sandbox: %@", GTokCommentsRoot());
}

__attribute__((constructor))
static void GTokCommentsInit(void) {
    @autoreleasepool {
        GTokLog(@"loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GTokInstall();
        });
    }
}
