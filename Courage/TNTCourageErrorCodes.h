//
//  TNTCourageErrorCodes.h
//  Courage
//
//  Created by Taylor Trimble on 9/7/14.
//  Copyright (c) 2014 The New Tricks. All rights reserved.
//

extern NSString *const TNTCourageErrorDomain;

typedef NS_ENUM(NSUInteger, TNTCourageErrorCode) {
    TNTCourageErrorCodeMissingCredentials,
    TNTCourageErrorCodeMissingDeviceId
};
