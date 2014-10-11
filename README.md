courage-ios
===========

iOS client for receiving realtime events from the Courage service.

Installation
------------

### Podfile

```ruby
platform :ios, '7.0'
pod 'Courage', '~> 0.0.1'
```

Getting Started
---------------

### Initializing Courage

```obj-c
TNTCourage *courage = [[TNTCourage alloc] initWithDSN:dsn];
[courage setPublicKey:publicKey privateKey:privateKey];
courage.deviceId = [UIDevice currentDevice].identifierForVendor;
courage.subscribeOptions = TNTCourageSubscribeOptionReplay;
```

- DSN, public key, and private key configuration are mandatory.
  - Use your own `dsn`, `publicKey`, and `privateKey`.
- The DSN is in the format `host:port/provider-id` and will always be the same for a given provider.
- The device id must be:
  - A UUID
  - Persistent between app launches
  - Globally unique to the device, __not__ a user account
- `[UIDevice currentDevice].identifierForVendor` is the recommended way of setting the device id on iOS.
- Global subscribe options may be specified here.

### Subscribing to a Channel

```obj-c
NSError *error;
[courage subscribeToChannel:channelId error:&error block:^(NSData *event) {
    NSLog(@"%@", [[NSString alloc] initWithData:event encoding:NSUTF8StringEncoding]);
}];
```

- Use your own `channelId`.
- You may subscribe to multiple channels.
- Subscription will fail if the DSN, public or private keys, or device id aren't set.

The example above assumes you are sending UTF-8 string data over the channels. The example simply logs that string.


### Starting the Connection

After initializing Courage and subscribscribing to a channel, connect to the server.

```objc
[courage connect];
```

You can subscribe to additional channels after connecting.

License
-------

Copyright (c) 2014 The New Tricks, LLC.
MIT License.
