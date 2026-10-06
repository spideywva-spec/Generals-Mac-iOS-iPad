#pragma once

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *GXHubModsRootPath(void);
FOUNDATION_EXPORT NSString *GXHubInstalledProfilePath(NSString *profileId);
FOUNDATION_EXPORT BOOL GXHubProfileInstalled(NSString *profileId);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXHubProfileIntegrity(NSString *profileId);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable GXHubInstalledManifest(NSString *profileId);
FOUNDATION_EXPORT NSString *GXHubCatalogChannel(void);
FOUNDATION_EXPORT void GXHubSetCatalogChannel(NSString *channel);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXHubCatalogDocument(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *GXHubCatalogEntries(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *GXHubInstalledModEntries(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable GXHubHubReleaseForCurrentChannel(void);
FOUNDATION_EXPORT NSString * _Nullable GXHubRemoteCatalogURL(void);
FOUNDATION_EXPORT BOOL GXHubRemoveMod(NSString *profileId, NSError **error);

FOUNDATION_EXPORT BOOL GXHubInstallPackageAtURL(
    NSURL *packageURL,
    NSString * _Nullable expectedSHA256,
    NSDictionary<NSString *, id> * _Nullable * _Nullable installedManifest,
    NSError **error);

typedef void (^GXHubInstallCompletion)(
    NSDictionary<NSString *, id> * _Nullable installedManifest,
    NSError * _Nullable error);

typedef void (^GXHubDownloadProgress)(
    long long bytesReceived,
    long long totalBytes,
    double fractionCompleted);

typedef void (^GXHubCatalogCompletion)(
    BOOL updated,
    NSError * _Nullable error);

FOUNDATION_EXPORT void GXHubRefreshRemoteCatalog(GXHubCatalogCompletion completion);

FOUNDATION_EXPORT BOOL GXHubDownloadBusy(void);
FOUNDATION_EXPORT NSString * _Nullable GXHubActiveDownloadProfile(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXHubDownloadStatus(void);
FOUNDATION_EXPORT BOOL GXHubPauseDownload(NSString *profileId, NSError **error);
FOUNDATION_EXPORT BOOL GXHubResumeDownload(NSString *profileId, NSError **error);
FOUNDATION_EXPORT BOOL GXHubCancelDownload(NSString *profileId, NSError **error);

FOUNDATION_EXPORT void GXHubDownloadAndInstall(
    NSDictionary<NSString *, id> *catalogEntry,
    GXHubInstallCompletion completion);

FOUNDATION_EXPORT void GXHubDownloadAndInstallWithProgress(
    NSDictionary<NSString *, id> *catalogEntry,
    GXHubDownloadProgress _Nullable progress,
    GXHubInstallCompletion completion);

NS_ASSUME_NONNULL_END

#endif
