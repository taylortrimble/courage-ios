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
const TNTCourageMessageHeader TNTCourageAckEventsMessageHeader = 0x15;

const NSTimeInterval TNTCourageInitialReconnectInterval = 0.1;  // 100ms.
const NSTimeInterval TNTCourageMaxReconnectInterval = 300;      // 5 min.
const NSTimeInterval TNTCourageTimeoutNever = -1.0;

#pragma mark - Private Members and Methods

@interface TNTCourage () <NSStreamDelegate>

// DSN information.
@property (strong, nonatomic) NSString *host;
@property (assign, nonatomic) UInt32 port;
@property (strong, nonatomic) NSUUID *providerId;

// Subscription info.
@property (strong, nonatomic) NSMutableDictionary *subscribers; // Key: UUID string. Value: block that takes NSData.

// State elements for processing input asynchronously. Frequently shared between
// different message types. Access to these variables is serialized on the delegateQueue.
@property (assign, nonatomic) BOOL replayAndDisconnectOnly;
@property (copy, nonatomic) void (^completionBlock)(TNTCourageReplayResult result);
@property (assign, nonatomic) UInt8 remainingChannels;
@property (strong, nonatomic) NSUUID *currentChannelId;
@property (assign, nonatomic) UInt8 remainingEvents;
@property (strong, nonatomic) NSUUID *currentEventId;
@property (strong, nonatomic) NSMutableArray *eventsToAcknowledge;  // Array of NSUUID *.

// Nitty Gritty
@property (strong, nonatomic) dispatch_queue_t delegateQueue;
@property (strong, nonatomic) GCDAsyncSocket *socket;               // Access to socket is serialized on the delegateQueue.
@property (assign, nonatomic) NSTimeInterval reconnectInterval;

// Socket delegate methods.
// Note: These aren't documented by a real protocol for some dumb reason. Use the official
//       project documentation instead.
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port;
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error;
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag;
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag;

// Socket delegate utility methods
- (void)processNextSubscribeSuccessElementOnSocket:(GCDAsyncSocket *)sock;
- (void)subscribeSuccessEventProcessed;
- (void)subscribeSuccessChannelProcessed;

// Utility methods.
- (void)commonConnect;
- (void)disconnectSocket:(GCDAsyncSocket *)sock;
- (void)sendSubscribeRequestForChannels:(NSArray *)channelIds;
- (void)acknowledgeEvents:(NSArray *)eventIds;
- (void)sendReplayResult:(TNTCourageReplayResult)result;
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
        
        NSInteger port = [parts[1] integerValue];
        if (port > UINT32_MAX) {
            return nil;
        }

        _host = parts[0];
        _port = (UInt32)port;
        _providerId = [[NSUUID alloc] initWithUUIDString:parts[2]];
        
        _subscribers = [[NSMutableDictionary alloc] init];
        
        _delegateQueue = dispatch_get_main_queue();
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
    
    dispatch_async(self.delegateQueue, ^{
        // Register the channel and callback.
        self.subscribers[[channelId UUIDString]] = block;
        
        // If we're connected, send the subscribe request instantly. Otherwise, we'll subscribe in the
        // socket:didConnectToHost: callback.
        if (self.socket.isConnected) {
            [self sendSubscribeRequestForChannels:@[ channelId ]];
        }
    });
    
    return YES;
}

#pragma mark - Socket Delegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(UInt16)port
{
    // If this isn't the current socket, we don't care. Don't let if affect internal state.
    if (sock != self.socket) {
        return;
    }
    
    // Derive a list of channel UUIDs from their string representation.
    NSMutableArray *channelIds = [[NSMutableArray alloc] initWithCapacity:[self.subscribers count]];
    for (NSString *channel in self.subscribers) {
        NSUUID *channelId = [[NSUUID alloc] initWithUUIDString:channel];
        [channelIds addObject:channelId];
    }
    
    // Send a SubscribeRequest for the channels.
    [self sendSubscribeRequestForChannels:channelIds];
    
    // Start reading incoming messages.
    [self.socket readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                              tag:TNTCourageReadTagMessageHeader];
    
    // Reset the reconnect interval.
    [self resetReconnectInterval];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
    // If this isn't the current socket, we don't care. Let it die.
    if (sock != self.socket) {
        return;
    }
    
    // If we're not subscribing with ReplayOnly, restart the connection with exponential backoff whenever we lose it.
    if (!self.replayAndDisconnectOnly) {
        dispatch_time_t nextReconnectTime = dispatch_time(DISPATCH_TIME_NOW, [self nextReconnectInterval] * NSEC_PER_SEC);
        dispatch_after(nextReconnectTime, self.delegateQueue, ^{
            [self.socket connectToHost:self.host onPort:self.port error:nil];
        });
    } else {
        // If we haven't returned a result already, report that the replay failed.
        [self sendReplayResult:TNTCourageReplayResultFailed];
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
// and find what [sock readDataToLength:withTimeout:tag:] tag it leads to. Use this to draw a state machine.
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    // If this isn't the current socket, we don't care. Don't let if affect internal state.
    if (sock != self.socket) {
        return;
    }
    
    switch (tag) {
        // If it's a message header, kick off a read for the next data we want.
        case TNTCourageReadTagMessageHeader: {
            TNTCourageMessageHeader header;
            [data getBytes:&header length:sizeof(TNTCourageMessageHeader)];
            
            switch (header) {
                case TNTCourageSubscribeSuccessMessageHeader: {
                    [sock readDataToLength:sizeof(UInt8) withTimeout:TNTCourageTimeoutNever
                                       tag:TNTCourageReadTagSubscribeSuccessChannelCount];
                } break;
                    
                case TNTCourageSubscribeDataMessageHeader: {
                    [sock readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                                       tag:TNTCourageReadTagSubscribeDataChannelId];
                } break;
                    
                default:
                    break;
            }
        } break;
            
        // If it's a channel count, cache it and start reading channel payloads. Also
        // reset processing variables.
        case TNTCourageReadTagSubscribeSuccessChannelCount: {
            UInt8 remainingChannels;
            [data getBytes:&remainingChannels length:sizeof(UInt8)];
            self.remainingChannels = remainingChannels;
            self.remainingEvents = 0;
            self.eventsToAcknowledge = [[NSMutableArray alloc] init];
            
            [self processNextSubscribeSuccessElementOnSocket:sock];
        } break;
            
        // If it's a channel id, cache it and start reading events.
        case TNTCourageReadTagSubscribeSuccessChannelId: {
            uuid_t channelIdBuffer;
            [data getBytes:&channelIdBuffer length:sizeof(uuid_t)];
            self.currentChannelId = [[NSUUID alloc] initWithUUIDBytes:channelIdBuffer];
            
            [sock readDataToLength:sizeof(UInt8) withTimeout:TNTCourageTimeoutNever
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
            
            [self processNextSubscribeSuccessElementOnSocket:sock];
        } break;
            
        // If it's an event id, cache it and read the next event payload.
        case TNTCourageReadTagSubscribeSuccessEventId: {
            uuid_t eventIdBuffer;
            [data getBytes:&eventIdBuffer length:sizeof(uuid_t)];
            self.currentEventId = [[NSUUID alloc] initWithUUIDBytes:eventIdBuffer];
            
            [sock readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagSubscribeSuccessEventPayloadLength];
        } break;
            
        // If it's an event payload length, queue a read for the payload.
        case TNTCourageReadTagSubscribeSuccessEventPayloadLength: {
            UInt16 length;
            [data getBytes:&length length:sizeof(UInt16)];
            length = CFSwapInt16BigToHost(length);
            
            if (length <= 0) {
                [self subscribeSuccessEventProcessed];
                [self processNextSubscribeSuccessElementOnSocket:sock];
                break;
            }

            [sock readDataToLength:length withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagSubscribeSuccessEventPayload];
        } break;
            
        // If it's the event payload data, dispatch the event.
        case TNTCourageReadTagSubscribeSuccessEventPayload: {
            void (^block)(NSData *) = self.subscribers[[self.currentChannelId UUIDString]];
            if (block != nil) {
                block(data);
            }
            
            [self.eventsToAcknowledge addObject:self.currentEventId];
            
            // Mark the event as complete. If it was the last event, mark the channel complete.
            [self subscribeSuccessEventProcessed];
            [self processNextSubscribeSuccessElementOnSocket:sock];
        } break;
            
        // If it's a channel id, cache it and queue a read for the event id.
        case TNTCourageReadTagSubscribeDataChannelId: {
            uuid_t channelIdBuffer;
            [data getBytes:&channelIdBuffer length:sizeof(uuid_t)];
            self.currentChannelId = [[NSUUID alloc] initWithUUIDBytes:channelIdBuffer];
            
            [sock readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagSubscribeDataEventId];
        } break;
            
        // If it's an event id, cache it and queue a read for the event payload's length.
        case TNTCourageReadTagSubscribeDataEventId: {
            uuid_t eventIdBuffer;
            [data getBytes:&eventIdBuffer length:sizeof(uuid_t)];
            self.currentEventId = [[NSUUID alloc] initWithUUIDBytes:eventIdBuffer];
            
            [sock readDataToLength:sizeof(UInt16) withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagSubscribeDataEventPayloadLength];
        } break;
            
        // If it's the event payload's length, queue a read for the event payload.
        case TNTCourageReadTagSubscribeDataEventPayloadLength: {
            UInt16 length;
            [data getBytes:&length length:sizeof(UInt16)];
            length = CFSwapInt16BigToHost(length);
            
            // If payload length is <= 0, just read the next message.
            if (length > 0) {
                [sock readDataToLength:length withTimeout:TNTCourageTimeoutNever
                                   tag:TNTCourageReadTagSubscribeDataEventPayload];
            } else {
                [sock readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                                   tag:TNTCourageReadTagMessageHeader];
            }
        } break;
            
        // If it's the event payload data, dispatch the event.
        case TNTCourageReadTagSubscribeDataEventPayload: {
            void (^block)(NSData *) = self.subscribers[[self.currentChannelId UUIDString]];
            if (block != nil) {
                block(data);
            }
            
            [self acknowledgeEvents:@[ self.currentEventId ]];
            [sock readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagMessageHeader];
        } break;
            
        default:
            break;
    }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    // If this isn't the current socket, we don't care. Don't let if affect internal state.
    if (sock != self.socket) {
        return;
    }
    
    // If anyone is interested in replay results, let them know we got new events when AckEvents
    // is written out.
    if (tag == TNTCourageWriteTagAckEvents) {
        [self sendReplayResult:TNTCourageReplayResultNewEvents];
        
        // If this is a replay-only connection, we should also disconnect at this time.
        if (self.replayAndDisconnectOnly) {
            [self disconnectSocket:self.socket];
        }
    }
}

#pragma mark Socket Delegate Utilities

- (void)processNextSubscribeSuccessElementOnSocket:(GCDAsyncSocket *)sock
{
    // If there is an event to process, process that.
    if (self.remainingEvents > 0) {
        [sock readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                           tag:TNTCourageReadTagSubscribeSuccessEventId];
    } else {
        // If there are remaining channels, process that.
        if (self.remainingChannels > 0) {
            [sock readDataToLength:sizeof(uuid_t) withTimeout:TNTCourageTimeoutNever
                               tag:TNTCourageReadTagSubscribeSuccessChannelId];
        } else {
            // Once all channels are processed, acknowledge events. If we have a party interested
            // in replay results, report that there were no events.
            if ([self.eventsToAcknowledge count] > 0) {
                [self acknowledgeEvents:self.eventsToAcknowledge];
            } else {
                [self sendReplayResult:TNTCourageReplayResultNoEvents];
            }
            
            // If we're not just doing a replay and disconnect, queue up the next read.
            // If we are doing a replay and disconnect, the acknowledgeEvents: method above
            // will result in a write callback, and will call the completion handler with
            // the appropriate replay result.
            if (!self.replayAndDisconnectOnly) {
                [sock readDataToLength:sizeof(TNTCourageMessageHeader) withTimeout:TNTCourageTimeoutNever
                                   tag:TNTCourageReadTagMessageHeader];
            }
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
    dispatch_async(self.delegateQueue, ^{
        self.replayAndDisconnectOnly = NO;
        [self commonConnect];
    });
}

- (void)disconnect
{
    dispatch_async(self.delegateQueue, ^{
        [self disconnectSocket:self.socket];
    });
}

- (void)replayAndDisconnect:(void (^)(TNTCourageReplayResult result))completion
{
    dispatch_async(self.delegateQueue, ^{
        self.replayAndDisconnectOnly = YES;
        self.completionBlock = completion;
        [self commonConnect];
    });
}

#pragma mark - Utility

// commonConnect performs connection duties common to both the connect
// and replayAndDisconnect methods.
// TODO: Do something if there's a failure.
- (void)commonConnect
{
    // Ask the current socket to disconnect.
    [self disconnectSocket:self.socket];
    
    // Set up and start a new socket.
    self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self.delegateQueue];
    [self.socket connectToHost:self.host onPort:self.port error:nil];
}

- (void)disconnectSocket:(GCDAsyncSocket *)sock
{
    // If this socket is the current socket, set the current socket to nil to
    // prevent the disconnection delegate method from attempting to reconnect on it.
    if (sock == self.socket) {
        self.socket = nil;
    }
    
    // Ask the socket to disconnect.
    [sock setDelegate:nil delegateQueue:nil];
    [sock disconnect];
}

- (void)sendSubscribeRequestForChannels:(NSArray *)channelIds
{
    // Check that no more than the max number of channels are written.
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

- (void)acknowledgeEvents:(NSArray *)eventIds
{
    // Check that no more than the max number of event ids are written.
    if ([eventIds count] > UINT8_MAX) {
        // TODO: Better solution to report error to lib user.
        return;
    }
    
    // Init request with request header.
    NSMutableData *request = [[NSMutableData alloc] initWithCapacity:sizeof(TNTCourageMessageHeader)];
    [request appendBytes:&TNTCourageAckEventsMessageHeader length:sizeof(TNTCourageMessageHeader)];
    
    // Write payload.
    TNTPayloadWriter *payloadWriter = [[TNTPayloadWriter alloc] initWithMutableData:request];
    [payloadWriter writeUint8:(UInt8)[eventIds count]];
    for (NSUUID *eventId in eventIds) {
        [payloadWriter writeUUID:eventId];
    }
    
    // Send to server.
    [self.socket writeData:request withTimeout:TNTCourageTimeoutNever tag:TNTCourageWriteTagAckEvents];
}

- (void)sendReplayResult:(TNTCourageReplayResult)result
{
    if (self.completionBlock) {
        self.completionBlock(result);
        self.completionBlock = nil;
    }
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
