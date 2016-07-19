//
//  TNTCourage.h
//  Courage
//
//  Created by Taylor Trimble on 9/2/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

@import Foundation;

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

- (instancetype)initWithHost:(NSString *)host port:(UInt32)port tlsEnabled:(BOOL)tlsEnabled
                  providerId:(NSUUID *)providerId subscribeOptions:(TNTCourageSubscribeOptions)subscribeOptions
                    deviceId:(NSUUID *)deviceId;

@property (strong, readonly, nonatomic) NSString *host;
@property (assign, readonly, nonatomic) UInt32 port;
@property (assign, readonly, nonatomic) BOOL tlsEnabled;
@property (strong, readonly, nonatomic) NSUUID *providerId;
@property (strong, readonly, nonatomic) NSUUID *deviceId;
@property (assign, readonly, nonatomic) TNTCourageSubscribeOptions subscribeOptions;

@property (strong, nonatomic) NSString *publicKey;
@property (strong, nonatomic) NSString *privateKey;

- (void)setPublicKey:(NSString *)publicKey privateKey:(NSString *)privateKey;

// Ensure that the public key, private key, and device id are set before subscribing.
- (BOOL)subscribeToChannel:(NSUUID *)channelId
                     error:(NSError *__autoreleasing *)error
                     block:(void (^)(NSData *event))block;

- (void)connect;
- (void)disconnect;

- (void)replayAndDisconnect:(void (^)(TNTCourageReplayResult result))completion;

@end
