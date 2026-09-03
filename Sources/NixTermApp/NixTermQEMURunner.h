// Adapted from UTMProcess and UTMQemuSystem.
// Copyright 2019-2026 osy and UTM contributors.
// Licensed under the Apache License, Version 2.0.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NixTermQEMURunner : NSObject

- (void)startWithArguments:(NSArray<NSString *> *)arguments
                completion:(void (^)(NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
