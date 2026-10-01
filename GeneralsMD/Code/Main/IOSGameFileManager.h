#pragma once

#import <Foundation/Foundation.h>

typedef void (^GXGameFileProgressBlock)(double progress, int64_t receivedBytes, int64_t totalBytes, double bytesPerSecond, NSTimeInterval remainingSeconds);
typedef void (^GXGameFileStatusBlock)(NSString *stage, NSString *detail);
typedef void (^GXGameFileCompletionBlock)(BOOL success, NSString *message);

@interface GXGameFileManager : NSObject

+ (instancetype)sharedManager;

- (void)downloadAndInstallGameFileWithProgress:(GXGameFileProgressBlock)progress
                                        status:(GXGameFileStatusBlock)status
                                    completion:(GXGameFileCompletionBlock)completion;

// Единственная проверка GameFile, используемая загрузкой, статусом и диагностикой.
- (BOOL)validateInstalledGameFile:(NSString **)message;

@end
