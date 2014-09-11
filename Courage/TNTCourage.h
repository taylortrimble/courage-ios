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
    TNTCourageSubscribeOptionCatchUp = 1 << 0
};

@interface TNTCourage : NSObject

- (instancetype)initWithDSN:(NSString *)dsn;

@property (strong, nonatomic) NSString *publicKey;
@property (strong, nonatomic) NSString *privateKey;

@property (strong, nonatomic) NSUUID *deviceId;

- (void)setPublicKey:(NSString *)publicKey privateKey:(NSString *)privateKey;

// Ensure that the public key, private key, and device id are set before subscribing.
- (BOOL)subscribeToChannel:(NSUUID *)channelId
                   options:(TNTCourageSubscribeOptions)options
                     error:(NSError *__autoreleasing *)error
                     block:(void (^)(NSData *event))block;

@end
