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

typedef NS_ENUM(long, TNTCourageReadTag) {
    TNTCourageReadTagMessageHeader,
    TNTCourageReadTagSubscribeSuccessChannelCount,
    TNTCourageReadTagSubscribeSuccessChannelId,
    TNTCourageReadTagSubscribeSuccessEventCount,
    TNTCourageReadTagSubscribeSuccessEventId,
    TNTCourageReadTagSubscribeSuccessEventPayloadLength,
    TNTCourageReadTagSubscribeSuccessEventPayload,
    TNTCourageReadTagSubscribeDataChannelId,
    TNTCourageReadTagSubscribeDataEventId,
    TNTCourageReadTagSubscribeDataEventPayloadLength,
    TNTCourageReadTagSubscribeDataEventPayload,
};

typedef NS_ENUM(long, TNTCourageWriteTag) {
    TNTCourageWriteTagSubscribeRequest,
    TNTCourageWriteTagAckEvents,
};

const TNTCourageMessageHeader TNTCourageSubscribeRequestMessageHeader = 0x11;
const TNTCourageMessageHeader TNTCourageSubscribeSuccessMessageHeader = 0x12;
const TNTCourageMessageHeader TNTCourageSubscribeDataMessageHeader = 0x14;

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

// Subscription info.
@property (strong, nonatomic) NSMutableDictionary *subscribers; // Key: UUID string. Value: block that takes NSData.

// State elements for processing input asynchronously. Frequently shared between
// different message types.
@property (assign, nonatomic) UInt8 remainingChannels;
@property (strong, nonatomic) NSUUID *currentChannelId;
@property (assign, nonatomic) UInt8 remainingEvents;
@property (strong, nonatomic) NSUUID *currentEventId;

@property (assign, nonatomic) BOOL replayAndDisconnectOnly;
@property (assign, nonatomic) NSTimeInterval reconnectInterval;

// Socket delegate methods.
// Note: These aren't documented by a real protocol for some dumb reason. Use the official
//       project documentation instead.
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port;
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error;
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;

// Socket delegate utility methods
- (void)processNextSubscribeSuccessElement;
- (void)subscribeSuccessEventProcessed;
- (void)subscribeSuccessChannelProcessed;

// Utility methods.
- (void)connectSocket;
- (void)sendSubscribeRequestForChannels:(NSArray *)channelIds;
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
        
        _remainingChannels = 0;
        _currentChannelId = nil;
        _remainingEvents = 0;
        _currentEventId = nil;
        
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
    
    // If we're connected, send the subscribe request instantly. Otherwise, we'll subscribe in the
    // socket:didConnectToHost: callback.
    if (self.socket.isConnected) {
        [self sendSubscribeRequestForChannels:@[ channelId ]];
    }
    
    return YES;
}

#pragma mark - Socket Delegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    // Derive a list of channel UUIDs from their string representation.
    NSMutableArray *channelIds = [[NSMutableArray alloc] initWithCapacity:[self.subscribers count]];
    for (NSString *channel in self.subscribers) {
        NSUUID *channelId = [[NSUUID alloc] initWithUUIDString:channel];
        [channelIds addObject:channelId];
    }
    
    // Send a SubscribeRequest for the channels.
    [self sendSubscribeRequestForChannels:channelIds];
    
    // Start reading incoming messages.
    [self.socket readDataToLength:sizeof(TNTCourageMessageHeader)
                      withTimeout:TNTCourageTimeoutNever
                              tag:TNTCourageReadTagMessageHeader];
    
    // Reset the reconnect interval.
    [self resetReconnectInterval];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
    // As long as we're not subscribing with ReplayOnly, restart the connection with exponential backoff
    // if we ever lose it.
    if (!self.replayAndDisconnectOnly) {
        [NSTimer scheduledTimerWithTimeInterval:[self nextReconnectInterval]
                                         target:self selector:@selector(connect) userInfo:nil
                                        repeats:NO];
    }
}

// socket:didReadData: is a funky method. We want to read continuously from the stream, but we can't do blocking reads.
//
// Instead, we have to get data from our reads in this callback. That means that we can't keep information about where
// we are in the stream on the stack: like the channel id we're getting a response for, the number of event payloads, or
// even the size of a single event payload. We need to keep track of that information in the instance instead. :(
//
// We do this in a couple ways: we either store the information directly (like the channel id or the number of expected events)
// or use it directly (we can kick of the read of an event payload's data directly from the event data length). We also know
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
        case TNTCourageReadTagMessageHeader: {
            TNTCourageMessageHeader header;
            [data getBytes:&header length:sizeof(TNTCourageMessageHeader)];
            
            switch (header) {
                case TNTCourageSubscribeSuccessMessageHeader: {
                    [self.socket readDataToLength:sizeof(UInt8) withTimeout:TNTCourageTimeoutNever
                                              tag:TNTCourageReadTagSubscribeSuccessChannelCount];
                } break;
                    
                case TNTCourageSubscribeDataMessageHeader: {
                    [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                                              tag:TNTCourageReadTagSubscribeDataChannelId];
                } break;
                    
                default:
                    break;
            }
        } break;
            
        // If it's a channel count, cache it and start reading channel payloads.
        case TNTCourageReadTagSubscribeSuccessChannelCount: {
            UInt8 remainingChannels;
            [data getBytes:&remainingChannels length:sizeof(UInt8)];
            self.remainingChannels = remainingChannels;
            self.remainingEvents = 0;
            
            [self processNextSubscribeSuccessElement];
        } break;
            
        // If it's a channel id, cache it and start reading events.
        case TNTCourageReadTagSubscribeSuccessChannelId: {
            uuid_t channelIdBuffer;
            [data getBytes:&channelIdBuffer length:sizeof(uuid_t)];
            self.currentChannelId = [[NSUUID alloc] initWithUUIDBytes:channelIdBuffer];
            
            [self.socket readDataToLength:sizeof(UInt8) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeSuccessEventCount];
        } break;
            
        // If it's an event count, cache it and start reading event data.
        case TNTCourageReadTagSubscribeSuccessEventCount: {
            UInt8 remainingEvents;
            [data getBytes:&remainingEvents length:sizeof(UInt8)];
            self.remainingEvents = remainingEvents;
            
            if (remainingEvents <= 0) {
                [self subscribeSuccessChannelProcessed];
            }
            
            [self processNextSubscribeSuccessElement];
        } break;
            
        // If it's an event id, cache it and read the next event payload.
        case TNTCourageReadTagSubscribeSuccessEventId: {
            uuid_t eventIdBuffer;
            [data getBytes:&eventIdBuffer length:sizeof(uuid_t)];
            self.currentEventId = [[NSUUID alloc] initWithUUIDBytes:eventIdBuffer];
            
            [self.socket readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeSuccessEventPayloadLength];
        } break;
            
        // If it's an event payload length, queue a read for the payload.
        case TNTCourageReadTagSubscribeSuccessEventPayloadLength: {
            UInt16 length;
            [data getBytes:&length length:sizeof(UInt16)];
            length = CFSwapInt16BigToHost(length);
            
            if (length <= 0) {
                [self subscribeSuccessEventProcessed];
                [self processNextSubscribeSuccessElement];
                break;
            }

            [self.socket readDataToLength:length withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeSuccessEventPayload];
        } break;
            
        // If it's the event payload data, dispatch the event.
        case TNTCourageReadTagSubscribeSuccessEventPayload: {
            void (^block)(NSData *) = self.subscribers[[self.currentChannelId UUIDString]];
            if (block != nil) {
                block(data);
            }
            
            // Mark the event as complete. If it was the last event, mark the channel complete.
            [self subscribeSuccessEventProcessed];
            [self processNextSubscribeSuccessElement];
        } break;
            
        // If it's a channel id, cache it and queue a read for the event id.
        case TNTCourageReadTagSubscribeDataChannelId: {
            uuid_t channelIdBuffer;
            [data getBytes:&channelIdBuffer length:sizeof(uuid_t)];
            self.currentChannelId = [[NSUUID alloc] initWithUUIDBytes:channelIdBuffer];
            
            [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeDataEventId];
        } break;
            
        // If it's an event id, cache it and queue a read for the event payload's length.
        case TNTCourageReadTagSubscribeDataEventId: {
            uuid_t eventIdBuffer;
            [data getBytes:&eventIdBuffer length:sizeof(uuid_t)];
            self.currentEventId = [[NSUUID alloc] initWithUUIDBytes:eventIdBuffer];
            
            [self.socket readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeDataEventPayloadLength];
        } break;
            
        // If it's the event payload's length, queue a read for the event payload.
        case TNTCourageReadTagSubscribeDataEventPayloadLength: {
            UInt16 length;
            [data getBytes:&length length:sizeof(UInt16)];
            length = CFSwapInt16BigToHost(length);
            
            // If payload length is <= 0, just read the next message.
            if (length > 0) {
                [self.socket readDataToLength:length withTimeout:TNTCourageTimeoutNever
                                          tag:TNTCourageReadTagSubscribeDataEventPayload];
            } else {
                [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                                          tag:TNTCourageReadTagMessageHeader];
            }
        } break;
            
        // If it's the event payload data, dispatch the event.
        case TNTCourageReadTagSubscribeDataEventPayload: {
            void (^block)(NSData *) = self.subscribers[[self.currentChannelId UUIDString]];
            if (block != nil) {
                block(data);
            }
            
            [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagMessageHeader];
        } break;
            
        default:
            break;
    }
}

#pragma mark Socket Delegate Utilities

- (void)processNextSubscribeSuccessElement
{
    // If there is an event to process, process that.
    if (self.remainingEvents > 0) {
        [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                                  tag:TNTCourageReadTagSubscribeSuccessEventId];
    } else {
        // If there are remaining channels, process that. Otherwise, continue to the next message.
        if (self.remainingChannels > 0) {
            [self.socket readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagSubscribeSuccessChannelId];
        } else if (!self.replayAndDisconnectOnly) {
            [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                                      tag:TNTCourageReadTagMessageHeader];
        } else {
            [self disconnect];
        }
    }
}

- (void)subscribeSuccessEventProcessed
{
    self.remainingEvents--;
    
    if (self.remainingEvents == 0) {
        [self subscribeSuccessChannelProcessed];
    }
}

- (void)subscribeSuccessChannelProcessed
{
    self.remainingChannels--;
}

#pragma mark - Connection Management

- (void)connect
{
    self.replayAndDisconnectOnly = NO;
    [self connectSocket];
}

- (void)disconnect
{
    [self.socket disconnect];
}

- (void)replayAndDisconnect
{
    self.replayAndDisconnectOnly = YES;
    [self connectSocket];
}

#pragma mark - Utility

- (void)connectSocket
{
    // Create the socket if we haven't created one yet.
    if (!self.socket) {
        self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    }
    
    // TODO: Do something if there's a failure.
    [self.socket connectToHost:self.host onPort:self.port error:nil];
}

- (void)sendSubscribeRequestForChannels:(NSArray *)channelIds
{
    // Check that no more than the max number of channels is written.
    if ([channelIds count] > UINT8_MAX) {
        // TODO: Better solution to report error to lib user.
        return;
    }
    
    // Calculate subscribe options.
    TNTCourageSubscribeOptions subscribeOptions = self.subscribeOptions;
    if (self.replayAndDisconnectOnly) {
        subscribeOptions |= TNTCourageSubscribeOptionReplay;
        subscribeOptions |= TNTCourageSubscribeOptionReplayOnly;
    } else {
        subscribeOptions &= ~TNTCourageSubscribeOptionReplayOnly;
    }
    
    // Init request with request header.
    NSMutableData *request = [[NSMutableData alloc] initWithCapacity:sizeof(TNTCourageMessageHeader)];
    [request appendBytes:&TNTCourageSubscribeRequestMessageHeader length:sizeof(TNTCourageMessageHeader)];
    
    // Write payload.
    TNTPayloadWriter *payloadWriter = [[TNTPayloadWriter alloc] initWithMutableData:request];
    [payloadWriter writeUUID:self.providerId];
    [payloadWriter writeString:self.publicKey];
    [payloadWriter writeString:self.privateKey];
    [payloadWriter writeUUID:self.deviceId];
    [payloadWriter writeUint8:(UInt8)[channelIds count]];
    
    for (NSUUID *channelId in channelIds) {
        [payloadWriter writeUUID:channelId];
    }
    
    [payloadWriter writeUint8:subscribeOptions];
    
    // Send to server.
    [self.socket writeData:request withTimeout:TNTCourageTimeoutNever tag:TNTCourageWriteTagSubscribeRequest];
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
