# GTokComments

Companion tweak for **GTok** (modded TikTok `com.zhiliaoapp.musically`, v45.8.0).

When a video is saved for offline viewing it also fetches (up to) **100 comments** of
that video plus the **author's profile avatar**, and stores them in the app sandbox:

```
<app>/Documents/GTokComments/<aweme_id>/comments.json
<app>/Documents/GTokComments/<aweme_id>/avatar.jpg
<app>/Documents/GTokComments/gtokcomments.log
```

## How it works
- Pure Objective-C, **objc runtime swizzling** (no Theos, no Substrate/ElleKit).
- Hooks (defensive, only if the selector exists):
  - `TTKCommentListDataController` `-setDataList:`, `-onRefreshRequestCompletedWithResponse:error:scene:`
  - `TTKCommentListRequestModel` `-setCount:` (forces 100)
  - `AWEMediaDownloader` `-downloadAweme:`, `-saveTaskVideoWithAweme:`
  - `TTKFeedOfflineVideoComponent` `-p_startOfflineDownloadIfNeed:`
- On an offline-download trigger it builds a `TTKCommentListDataController`, requests 100
  comments, serializes them to JSON and downloads the avatar.

## Build
GitHub Actions (macOS runner + iphoneos SDK) builds `GTokComments.dylib`.

## Install
Inject `GTokComments.dylib` into `Payload/TikTok.app/Frameworks/` of the IPA and add an
`LC_LOAD_DYLIB` load command; Sideloadly re-signs on install.
