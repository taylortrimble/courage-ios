courage-ios
===========

iOS client for receiving realtime events from the Courage service.

Installation
------------

### Podfile

```ruby
platform :ios, '7.0'
pod 'Courage', '~> 0.1.0'
```

Getting Started
---------------

### Initializing Courage

```obj-c
TNTCourage *courage = [[TNTCourage alloc] initWithHost:host port:port tlsEnabled:@YES
                                            providerId:providerId subscribeOptions:TNTCourageSubscribeOptionReplay
                                              deviceId:[UIDevice currentDevice].identifierForVendor];
[courage setPublicKey:publicKey privateKey:privateKey];
```

- All configuration above is mandatory.
- The device id must be:
  - A UUID
  - Persistent between app launches
  - Globally unique to the device, __not__ a user account
- `[UIDevice currentDevice].identifierForVendor` is the recommended way of setting the device id on iOS.


### Subscribing to a Channel

```obj-c
NSError *error;
[courage subscribeToChannel:channelId error:&error block:^(NSData *event) {
    NSLog(@"%@", [[NSString alloc] initWithData:event encoding:NSUTF8StringEncoding]);
}];
```

- Use your own `channelId`.
- You may subscribe to multiple channels.
- Subscription will fail if `courage` is improperly configured, for example if the `publicKey` and `privateKey` haven't been set.

The example above assumes you are sending UTF-8 string data over the channels. The example simply logs that string.


### Starting the Connection

After initializing Courage and subscribing to a channel, connect to the server.

```objc
[courage connect];
```

You may also subscribe to additional channels after connecting.


License
-------

Copyright (c) 2014 The New Tricks, LLC.
MIT License.
