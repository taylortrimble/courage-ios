//
//  TNTPayloadWriter.m
//  Courage
//
//  Created by Taylor Trimble on 9/6/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

#import "TNTPayloadWriter.h"

@interface TNTPayloadWriter ()

@property (strong, nonatomic) NSMutableData *buffer;

@end

@implementation TNTPayloadWriter

#pragma mark - Initializers

- (id)init
{
    return [self initWithMutableData:[[NSMutableData alloc] init]];
}

- (instancetype)initWithMutableData:(NSMutableData *)data
{
    self = [super init];
    if (self) {
        _buffer = data;
    }
    
    return self;
}

#pragma mark - Write Methods

- (void)writeUint8:(UInt8)u
{
    [self.buffer appendBytes:&u length:sizeof(UInt8)];
}

- (void)writeUUID:(NSUUID *)uuid
{
    uuid_t uuidBuffer;
    [uuid getUUIDBytes:uuidBuffer];
    
    [self.buffer appendBytes:uuidBuffer length:sizeof(uuid_t)];
}

- (BOOL)writeString:(NSString *)string
{
    NSData *encodedString = [string dataUsingEncoding:NSUTF8StringEncoding];
    if ([encodedString length] > UINT8_MAX) {
        return NO;
    }
    
    UInt8 length = [encodedString length];
    [self.buffer appendBytes:&length length:sizeof(UInt8)];
    [self.buffer appendData:encodedString];
    
    return YES;
}

- (BOOL)writeBlob:(NSData *)blob
{
    if ([blob length] > UINT16_MAX) {
        return NO;
    }
    
    UInt16 length = CFSwapInt16HostToBig([blob length]);
    [self.buffer appendBytes:&length length:sizeof(UInt16)];
    [self.buffer appendData:blob];
    
    return YES;
}

@end
