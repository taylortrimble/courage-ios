//
//  TNTCourage.h
//  Courage
//
//  Created by Taylor Trimble on 9/2/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_OPTIONS(UInt8, TNTCourageSubscribeOptions) {
    TNTCourageSubscribeOptionDefault = 0,
    TNTCourageSubscribeOptionReplay = 1 << 0,
    TNTCourageSubscribeOptionReplayOnly = 1 << 1,
};

typedef NS_ENUM(NSInteger, TNTCourageReplayResult) {
    TNTCourageReplayResultNewEvents,
    TNTCourageReplayResultNoEvents,
    TNTCourageReplayResultFailed,
};

@interface TNTCourage : NSObject

- (instancetype)initWithDSN:(NSString *)dsn;

@property (strong, nonatomic) NSString *publicKey;
@property (strong, nonatomic) NSString *privateKey;
@property (strong, nonatomic) NSUUID *deviceId;
@property (assign, nonatomic) TNTCourageSubscribeOptions subscribeOptions;

- (void)setPublicKey:(NSString *)publicKey privateKey:(NSString *)privateKey;

// Ensure that the public key, private key, and device id are set before subscribing.
- (BOOL)subscribeToChannel:(NSUUID *)channelId
                     error:(NSError *__autoreleasing *)error
                     block:(void (^)(NSData *event))block;

- (void)connect;
- (void)disconnect;

- (void)replayAndDisconnect:(void (^)(TNTCourageReplayResult result))completion;

@end
