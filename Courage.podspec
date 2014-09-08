#
#  Courage.podspec
#  courage-ios
#
#  Created by Taylor Trimble on 9/2/14.
#  Copyright 2014 The New Tricks, LLC.
#

Pod::Spec.new do |s|

  s.name     = 'Courage'
  s.version  = '0.0.1'
  s.summary  = 'An iOS client for the Courage realtime event service.'
  s.homepage = 'http://github.com/thenewtricks/courage-ios'
  
  s.description = <<-DESC
                  The Courage iOS client is designed to received realtime events from
                  a Courage service endpoint.

                  The Courage service was invented to fulfill a specific niche in realtime
                  delivery. Whereas other systems promise only best-effort delivery for
                  actively connected clients, Courage:

                  - Guarantees eventual delivery of all messages
                  - Supports server-to-many-device event channels
                  - Is a generalized interface to Android, iOS and Web clients
                  - Has a fallback for actively connected devices to use the APNS
                    silent sync feature
                  - Will attempt to reconnect if the active connection is lost

                  Limitations:

                  - In-order delivery is impossible, and cannot be guaranteed
                  - Message size limit of 1kB

                  This client library must be used with the Courage service.
                  DESC

  s.authors = { 'Taylor Trimble' => 'taylor@taylortrimble.com' }
  s.license = { :type => 'Apache', :file => 'LICENSE' }

  s.ios.deployment_target = '7.0'
  s.osx.deployment_target = '10.8'
  s.requires_arc          = true

  s.source              = { :git => 'https://github.com/thenewtricks/courage-ios.git', :tag => s.version.to_s }
  s.source_files        = 'Courage/*.{h,m}', 'Courage/Internal/*.{h,m}'
  s.public_header_files = 'Courage/*.h'

  s.dependency 'CocoaAsyncSocket', '~> 7.3'

end
