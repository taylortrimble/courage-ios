//
//  TNTPayloadWriter.h
//  Courage
//
//  Created by Taylor Trimble on 9/6/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface TNTPayloadWriter : NSObject

- (instancetype)initWithMutableData:(NSMutableData *)data;

- (void)writeUint8:(UInt8)u;
- (void)writeUUID:(NSUUID *)uuid;
- (BOOL)writeString:(NSString *)string;
- (BOOL)writeBlob:(NSData *)blob;

@end
