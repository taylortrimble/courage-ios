//
//  TNTCourage.m
//  Courage
//
//  Created by Taylor Trimble on 9/2/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

#import "TNTCourage.h"

#import "TNTCourageErrorCodes.h"
#import "TNTPayloadWriter.h"

#import <CocoaAsyncSocket/GCDAsyncSocket.h>
#import <UIKit/UIKit.h>

#pragma mark - Types

typedef UInt8 TNTCourageMessageHeader;

#pragma mark - Enums and Constants

typedef NS_ENUM(long, TNTCourageSocketReadTag) {
    TNTCourageSocketReadTagMessageHeader,
    TNTCourageSocketReadTagOKChannel,
    TNTCourageSocketReadTagStreamingChannel,
    TNTCourageSocketReadTagStreamingEventCount,
    TNTCourageSocketReadTagStreamingEventLength,
    TNTCourageSocketReadTagStreamingEventData
};

typedef NS_ENUM(long, TNTCourageSocketWriteTag) {
    TNTCourageSocketWriteTagSubscribeMessageRequest
};

const TNTCourageMessageHeader TNTCourageSubscribeRequestMessageHeader = 0x10;
const TNTCourageMessageHeader TNTCourageSubscribeOKResponseMessageHeader = 0x11;
const TNTCourageMessageHeader TNTCourageSubscribeStreamingResponseMessageHeader = 0x13;

const NSTimeInterval TNTCourageInitialReconnectInterval = 0.1;  // 100ms.
const NSTimeInterval TNTCourageMaxReconnectInterval = 300;      // 5 min.
const NSTimeInterval TNTCourageTimeoutNever = -1.0;

#pragma mark - Private Members and Methods

@interface TNTCourage () <NSStreamDelegate>

// DSN information.
@property (strong, nonatomic) NSString *host;
@property (assign, nonatomic) UInt32 port;
@property (strong, nonatomic) NSUUID *providerId;

@property (strong, nonatomic) GCDAsyncSocket *socket;

// The subscribers. Key: UUID string. Value: block that takes NSData.
@property (strong, nonatomic) NSMutableDictionary *subscribers;

// State elements for processing input asynchronously.
@property (strong, nonatomic) NSUUID *currentChannelId;
@property (assign, nonatomic) UInt8 remainingEvents;

@property (assign, nonatomic) NSTimeInterval reconnectInterval;

// Socket delegate methods.
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port;
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error;
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;

// Utility methods.
- (void)connect;
- (void)sendSubscribeRequestForChannel:(NSUUID *)channelId options:(TNTCourageSubscribeOptions)options;
- (NSTimeInterval)nextReconnectInterval;
- (void)resetReconnectInterval;

@end

@implementation TNTCourage

#pragma mark - Initializers

- (instancetype)initWithDSN:(NSString *)dsn
{
    self = [super init];
    if (self) {
        // Format: `host:port/provider-id`
        NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@":/"];
        NSArray *parts = [dsn componentsSeparatedByCharactersInSet:separators];
        if ([parts count] != 3) {
            return nil;
        }
        
        _host = parts[0];
        
        NSInteger port = [parts[1] integerValue];
        if (port > UINT32_MAX) {
            return nil;
        }

        _port = (UInt32)port;
        _providerId = [[NSUUID alloc] initWithUUIDString:parts[2]];
        
        _socket = nil;
        
        _subscribers = [[NSMutableDictionary alloc] init];
        
        _currentChannelId = nil;
        _remainingEvents = 0;
        
        _reconnectInterval = TNTCourageInitialReconnectInterval;
    }
    
    return self;
}

#pragma mark - Configuration

- (void)setPublicKey:(NSString *)publicKey privateKey:(NSString *)privateKey
{
    self.publicKey = publicKey;
    self.privateKey = privateKey;
}

#pragma mark - Subscribe

- (BOOL)subscribeToChannel:(NSUUID *)channelId
                   options:(TNTCourageSubscribeOptions)options
                     error:(NSError *__autoreleasing *)error
                     block:(void (^)(NSData *))block
{
    // Error out if credentials aren't set.
    if (!self.publicKey || !self.privateKey) {
        if (error != nil) {
            *error = [NSError errorWithDomain:TNTCourageErrorDomain code:TNTCourageErrorCodeMissingCredentials userInfo:nil];
            return NO;
        }
    }

    // Error out if no device id is set.
    if (!self.deviceId) {
        if (error != nil) {
            *error = [NSError errorWithDomain:TNTCourageErrorDomain code:TNTCourageErrorCodeMissingDeviceId userInfo:nil];
            return NO;
        }
    }
    
    // Register the channel and callback.
    self.subscribers[[channelId UUIDString]] = block;
    
    // If we're connected, send the subscribe request instantly. Otherwise, kick off the connection
    // and we'll subscribe in the socket:didConnectToHost: callback.
    if (self.socket.isConnected) {
        [self sendSubscribeRequestForChannel:channelId options:options];
    } else {
        // Only kick off the connection if we haven't already kicked it off. Even if we weren't connected above,
        // if we have a socket object then we are retrying the connection.
        if (!self.socket) {
            self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
            [self connect];
        }
    }
    
    return YES;
}

#pragma mark - Socket Delegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    // On connection, send a subscribe request for each subscriber.
    for (NSString *channel in self.subscribers) {
        NSUUID *channelId = [[NSUUID alloc] initWithUUIDString:channel];
        [self sendSubscribeRequestForChannel:channelId options:TNTCourageSubscribeOptionDefault];   // TODO: use original options.
    }
    
    // Start reading incoming messages.
    [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagMessageHeader];
    
    // Reset the reconnect interval.
    [self resetReconnectInterval];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
    // If we ever lose the connection, try to restart it.
    [NSTimer scheduledTimerWithTimeInterval:[self nextReconnectInterval] target:self selector:@selector(connect) userInfo:nil repeats:NO];
}

// socket:didReadData: is a funky method. We want to read continuously from the stream, but we can't do blocking reads.
//
// Instead, we have to get data from our reads in this callback. That means that we can't keep information about where
// we are in the stream on the stack: like the channel id we're getting a response for, the number of event payloads, or
// even the size of an event payload. We need to keep track of that information in the instance instead. :(
//
// We do this in a couple ways: we either store the information directly (like the channelId or the number of expected events),
// use it directly (we can kick of the read of an event payload's data directly from the event data length). We also know
// what kind of data we are receiving, since GCDAsyncSocket lets us **tag** our reads with the read type.
//
// So basically, our tags work like advancing a state machine, and the non-state data is stored as properties on the instance.
//
// Note: since we're continuously reading, each case must kick off a read for the next data we expect.
//
// If you're still having trouble understanding this method, start from a `case` that starts with `TNTCourageSocketReadTag`
// and find what [self.socket readDataToLength:withTimeout:tag:] tag it leads to. Use this to draw a state machine.
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    switch (tag) {
        // If it's a message header, kick off a read for the next data we want.
        case TNTCourageSocketReadTagMessageHeader: {
            TNTCourageMessageHeader header;
            [data getBytes:&header length:sizeof(TNTCourageMessageHeader)];
            
            switch (header) {
                case TNTCourageSubscribeOKResponseMessageHeader: {
                    [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagOKChannel];
                } break;
                    
                case TNTCourageSubscribeStreamingResponseMessageHeader: {
                    [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagStreamingChannel];
                } break;
                    
                default:
                    break;
            }
        } break;
            
        // If it's an OK response payload, we don't want the information. We just prepare to read the next message's header.
        case TNTCourageSocketReadTagOKChannel: {
            [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagMessageHeader];
        } break;
            
        // If it's a streaming channel, we cache it for later and queue a read for how many events we expect to read.
        case TNTCourageSocketReadTagStreamingChannel: {
            uuid_t channelIdBuffer;
            [data getBytes:&channelIdBuffer length:sizeof(uuid_t)];
            self.currentChannelId = [[NSUUID alloc] initWithUUIDBytes:channelIdBuffer];
            
            [self.socket readDataToLength:sizeof(UInt8) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagStreamingEventCount];
        } break;
            
        // If it's an event count, cache it and start reading event payloads.
        case TNTCourageSocketReadTagStreamingEventCount: {
            UInt8 remainingEvents;
            [data getBytes:&remainingEvents length:sizeof(UInt8)];
            self.remainingEvents = remainingEvents;
            
            // We're asuming the number of events is at least 1.
            [self.socket readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagStreamingEventLength];
        } break;
            
        // If it's an event payload length, queue a read for the payload.
        case TNTCourageSocketReadTagStreamingEventLength: {
            UInt16 length;
            [data getBytes:&length length:sizeof(UInt16)];
            length = CFSwapInt16BigToHost(length);
            
            [self.socket readDataToLength:length withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagStreamingEventData];
        } break;
            
        // If it's the event payload data, dispatch the event. If it's the last event, queue a read for the next message's header.
        case TNTCourageSocketReadTagStreamingEventData: {
            void (^block)(NSData *) = self.subscribers[[self.currentChannelId UUIDString]];
            if (block != nil) {
                block(data);
            }
            
            self.remainingEvents--;
            
            if (self.remainingEvents > 0) {
                [self.socket readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagStreamingEventLength];
            } else {
                [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketReadTagMessageHeader];
            }
        } break;
            
        default:
            break;
    }
}

#pragma mark - Utility

- (void)connect
{
    // TODO: Do something if there's a failure.
    [self.socket connectToHost:self.host onPort:self.port error:nil];
}

- (void)sendSubscribeRequestForChannel:(NSUUID *)channelId options:(TNTCourageSubscribeOptions)options
{
    // Init request with request header.
    NSMutableData *request = [[NSMutableData alloc] initWithCapacity:sizeof(TNTCourageMessageHeader)];
    [request appendBytes:&TNTCourageSubscribeRequestMessageHeader length:sizeof(TNTCourageMessageHeader)];
    
    // Write payload.
    TNTPayloadWriter *payloadWriter = [[TNTPayloadWriter alloc] initWithMutableData:request];
    [payloadWriter writeString:self.publicKey];
    [payloadWriter writeString:self.privateKey];
    [payloadWriter writeUUID:self.providerId];
    [payloadWriter writeUUID:channelId];
    [payloadWriter writeUUID:self.deviceId];
    [payloadWriter writeUint8:options];
    
    // Send to server.
    [self.socket writeData:request withTimeout:TNTCourageTimeoutNever tag:TNTCourageSocketWriteTagSubscribeMessageRequest];
}

- (NSTimeInterval)nextReconnectInterval
{
    NSTimeInterval nextReconnectInterval = self.reconnectInterval;
    self.reconnectInterval = MIN(self.reconnectInterval * 2, TNTCourageMaxReconnectInterval);
    
    return nextReconnectInterval;
}

- (void)resetReconnectInterval
{
    self.reconnectInterval = TNTCourageInitialReconnectInterval;
}

@end
