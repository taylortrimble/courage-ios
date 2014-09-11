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
[courage setDeviceId:[[UIDevice currentDevice] identifierForVendor]];
```

- All of the configuration above is mandatory.
  - Use your own `dsn`, `publicKey`, and `privateKey`.
- The DSN is in the format `host:port/provider-id` and will always be the same for a given provider.
- The device id must be:
  - A UUID
  - Persistent between app launches
  - Globally unique to the device, __not__ a user account
- `[[UIDevice currentDevice] identifierForVendor]` is the recommended way of setting the device id on iOS.

### Subscribing to a Channel

```obj-c
NSError *error;
[self.courage subscribeToChannel:channelId options:TNTCourageSubscribeOptionCatchUp error:&error block:^(NSData *event) {
    NSLog(@"%@", [[NSString alloc] initWithData:event encoding:NSUTF8StringEncoding]);
}];
```

- Use your own `channelId`.
- You may subscribe to multiple channels.
- Subscription will fail if the DSN, public or private keys, or device id aren't set.

The example above assumes you are sending UTF-8 string data over the channels. The example simply logs that string.

License
-------

Copyright (c) 2014 The New Tricks, LLC.
MIT License.
